import AudioToolbox
import Foundation

struct EffectParam: Codable {
    var id: String
    var name: String
    var min: Double
    var max: Double
    var def: Double
    var unit: String
    var step: Double
}

struct EffectInfo: Codable {
    var key: String
    var name: String
    var params: [EffectParam]
}

private struct RenderContext {
    var l: UnsafeMutablePointer<Float>?
    var r: UnsafeMutablePointer<Float>?
}

/// Liefert einer Audio Unit ihr Eingangssignal aus dem aktuellen Puffer.
private let effectInput: AURenderCallback = { refCon, _, _, _, frames, ioData in
    let context = refCon.assumingMemoryBound(to: RenderContext.self)
    guard let ioData else { return noErr }
    let list = UnsafeMutableAudioBufferListPointer(ioData)
    let bytes = Int(frames) * 4
    for (index, source) in [context.pointee.l, context.pointee.r].enumerated() where index < list.count {
        guard let source else { continue }
        if let target = list[index].mData {
            memcpy(target, source, min(bytes, Int(list[index].mDataByteSize)))
        } else {
            list[index].mData = UnsafeMutableRawPointer(source)
        }
    }
    return noErr
}

/// Kette aus Apple-Audioeffekten (Audio Units), je mit Dry/Wet-Anteil.
final class EffectChain {
    static let maxUnits = 8
    /// Netzwerk-Senden gehört nicht in einen Equalizer.
    private static let excluded: Set<String> = ["nsnd"]

    let key: String
    private let count: Int
    private let units: UnsafeMutablePointer<AudioUnit?>
    private let mixes: UnsafeMutablePointer<Float>
    private let enabled: UnsafeMutablePointer<Bool>
    private let context: UnsafeMutablePointer<RenderContext>
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private let outList: UnsafeMutableAudioBufferListPointer
    private let sampleTime: UnsafeMutablePointer<Float64>

    static func key(for states: [EffectState], sampleRate: Double) -> String {
        states.prefix(maxUnits).map { $0.id + "/" + $0.component }.joined(separator: "|") + "@\(sampleRate)"
    }

    init(states: [EffectState], sampleRate: Double) {
        let states = Array(states.prefix(Self.maxUnits))
        key = Self.key(for: states, sampleRate: sampleRate)
        count = states.count
        units = .allocate(capacity: Self.maxUnits)
        units.initialize(repeating: nil, count: Self.maxUnits)
        mixes = .allocate(capacity: Self.maxUnits)
        mixes.initialize(repeating: 1, count: Self.maxUnits)
        enabled = .allocate(capacity: Self.maxUnits)
        enabled.initialize(repeating: false, count: Self.maxUnits)
        context = .allocate(capacity: 1)
        context.initialize(to: RenderContext())
        outL = .allocate(capacity: Processor.capacity)
        outR = .allocate(capacity: Processor.capacity)
        outList = AudioBufferList.allocate(maximumBuffers: 2)
        sampleTime = .allocate(capacity: 1)
        sampleTime.initialize(to: 0)

        for (index, state) in states.enumerated() {
            units[index] = Self.makeUnit(state.component, sampleRate: sampleRate, context: context)
        }
        apply(states)
    }

    deinit {
        for index in 0..<Self.maxUnits {
            if let unit = units[index] {
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
        }
        units.deallocate()
        mixes.deallocate()
        enabled.deallocate()
        context.deallocate()
        outL.deallocate()
        outR.deallocate()
        free(outList.unsafeMutablePointer)
        sampleTime.deallocate()
    }

    /// Übernimmt Parameter, Ein/Aus und Mischanteil (Haupt-Thread).
    func apply(_ states: [EffectState]) {
        for (index, state) in states.prefix(count).enumerated() {
            mixes[index] = Float(min(max(state.mix, 0), 1))
            enabled[index] = state.on
            guard let unit = units[index] else { continue }
            for (id, value) in state.params {
                if let parameter = AudioUnitParameterID(id) {
                    AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, AudioUnitParameterValue(value), 0)
                }
            }
        }
    }

    /// Audio-Thread.
    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ frames: Int) {
        for index in 0..<count {
            guard enabled[index], let unit = units[index] else { continue }
            context.pointee.l = l
            context.pointee.r = r
            outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outL)
            outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outR)
            var flags = AudioUnitRenderActionFlags()
            var time = AudioTimeStamp()
            time.mSampleTime = sampleTime.pointee
            time.mFlags = .sampleTimeValid
            guard AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), outList.unsafeMutablePointer) == noErr,
                  let wetL = outList[0].mData?.assumingMemoryBound(to: Float.self),
                  let wetR = outList[1].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let wet = mixes[index], dry = 1 - wet
            for i in 0..<frames {
                l[i] = l[i] * dry + wetL[i] * wet
                r[i] = r[i] * dry + wetR[i] * wet
            }
        }
        sampleTime.pointee += Float64(frames)
    }

    // MARK: Audio Units

    private static func fourCC(_ text: String) -> OSType? {
        let bytes = Array(text.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | OSType($1) }
    }

    private static func text(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xff) }, encoding: .ascii) ?? "????"
    }

    private static func component(_ key: String) -> AudioComponent? {
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count == 3, let type = fourCC(parts[0]), let subtype = fourCC(parts[1]), let maker = fourCC(parts[2]) else { return nil }
        var description = AudioComponentDescription(componentType: type, componentSubType: subtype,
                                                    componentManufacturer: maker, componentFlags: 0, componentFlagsMask: 0)
        return AudioComponentFindNext(nil, &description)
    }

    private static func makeUnit(_ key: String, sampleRate: Double, context: UnsafeMutablePointer<RenderContext>) -> AudioUnit? {
        guard let component = component(key) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var maxFrames = UInt32(Processor.capacity)
        var callback = AURenderCallbackStruct(inputProc: effectInput, inputProcRefCon: context)

        let ok = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4) == noErr
            && AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
            && AudioUnitInitialize(unit) == noErr
        if !ok {
            AudioComponentInstanceDispose(unit)
            Log.write("Effekt \(key) ließ sich nicht einrichten")
            return nil
        }
        return unit
    }

    /// Alle Apple-Effekte samt ihrer regelbaren Parameter.
    static func catalog() -> [EffectInfo] {
        var result: [EffectInfo] = []
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        var current: AudioComponent? = nil
        while let component = AudioComponentFindNext(current, &description) {
            current = component
            var found = AudioComponentDescription()
            guard AudioComponentGetDescription(component, &found) == noErr,
                  !excluded.contains(text(found.componentSubType)) else { continue }
            var cfName: Unmanaged<CFString>?
            AudioComponentCopyName(component, &cfName)
            var name = (cfName?.takeRetainedValue() as String?) ?? text(found.componentSubType)
            if name.hasPrefix("Apple: ") { name.removeFirst(7) }
            if name.hasPrefix("AU") { name.removeFirst(2) }

            var instance: AudioUnit?
            guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { continue }
            defer { AudioComponentInstanceDispose(unit) }
            let key = [found.componentType, found.componentSubType, found.componentManufacturer].map(text).joined(separator: ":")
            result.append(EffectInfo(key: key, name: name, params: parameters(of: unit)))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func parameters(of unit: AudioUnit) -> [EffectParam] {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nil) == noErr, size > 0 else { return [] }
        var ids = [AudioUnitParameterID](repeating: 0, count: Int(size) / MemoryLayout<AudioUnitParameterID>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &size) == noErr else { return [] }

        var result: [EffectParam] = []
        for id in ids where result.count < 16 {
            var info = AudioUnitParameterInfo()
            var infoSize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &infoSize) == noErr,
                  info.flags.contains(.flag_IsWritable), info.maxValue > info.minValue else { continue }
            var name = ""
            if info.flags.contains(.flag_HasCFNameString), let cf = info.cfNameString {
                name = cf.takeUnretainedValue() as String
                if info.flags.contains(.flag_CFNameRelease) { cf.release() }
            } else {
                name = withUnsafeBytes(of: info.name) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            let unit: String
            var step = 0.0
            switch info.unit {
            case .decibels: unit = "dB"
            case .hertz: unit = "Hz"
            case .percent: unit = "%"
            case .seconds: unit = "s"
            case .milliseconds: unit = "ms"
            case .cents: unit = "ct"
            case .boolean, .indexed:
                unit = ""
                step = 1
            default: unit = ""
            }
            result.append(EffectParam(id: String(id), name: name.isEmpty ? "Parameter \(id)" : name,
                                      min: Double(info.minValue), max: Double(info.maxValue),
                                      def: Double(info.defaultValue), unit: unit, step: step))
        }
        return result
    }
}
