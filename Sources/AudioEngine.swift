import AppKit
import AudioToolbox
import CoreAudio
import Foundation

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct OutputDevice: Equatable {
    var uid: String
    var name: String
}

/// Eine App (samt Hilfsprozessen), die bei Core Audio angemeldet ist.
struct AudioApp: Equatable {
    var id: String
    var name: String
    var pid: pid_t
    var objects: [AudioObjectID]
    var playing: Bool
}

private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
/// Ordnet Hilfsprozesse (z. B. von Safari oder Chrome) ihrer App zu.
private let responsiblePID: ResponsibleFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsibleFunction.self)
}()

/// Greift den Systemton über Core-Audio-Process-Taps ab, schickt ihn durch den
/// Processor und gibt ihn auf dem Ausgabegerät wieder aus. Solange ein Tap
/// gelesen wird, schaltet macOS das Originalsignal stumm.
final class AudioEngine {
    let processor = Processor()
    var onDevicesChanged: (() -> Void)?

    private(set) var isRunning = false
    private(set) var signature = ""
    private(set) var output = OutputDevice(uid: "", name: "")
    private(set) var sampleRate = 48000.0

    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    init() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(Self.system, &address, DispatchQueue.main) { [weak self] _, _ in
                self?.onDevicesChanged?()
            }
        }
    }

    static func signature(output: String, appTaps: [[AudioObjectID]]) -> String {
        output + "#" + appTaps.map { $0.map(String.init).joined(separator: ",") }.joined(separator: ";")
    }

    // MARK: Geräte und Apps

    func defaultOutput() -> OutputDevice? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return describe(device)
    }

    func outputDevices() -> [OutputDevice] {
        Self.objects(Self.system, kAudioHardwarePropertyDevices).compactMap { device in
            guard Self.channelCount(device, scope: kAudioObjectPropertyScopeOutput) > 0,
                  let described = describe(device), !described.uid.hasPrefix("de.leon.klangeq") else { return nil }
            return described
        }
    }

    private func describe(_ device: AudioObjectID) -> OutputDevice? {
        guard let uid = Self.string(device, kAudioDevicePropertyDeviceUID) else { return nil }
        return OutputDevice(uid: uid, name: Self.string(device, kAudioObjectPropertyName) ?? uid)
    }

    func audioApps() -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        let own = getpid()
        for object in Self.objects(Self.system, kAudioHardwarePropertyProcessObjectList) {
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            var address = Self.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0, pid != own else { continue }
            var running: UInt32 = 0
            size = 4
            address = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running)

            guard let owner = Self.owner(of: pid, object: object) else { continue }
            var app = apps[owner.id] ?? AudioApp(id: owner.id, name: owner.name, pid: owner.pid, objects: [], playing: false)
            app.objects.append(object)
            app.playing = app.playing || running != 0
            apps[owner.id] = app
        }
        return apps.values.map { app in
            var app = app
            app.objects.sort()
            return app
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func owner(of pid: pid_t, object: AudioObjectID) -> (id: String, name: String, pid: pid_t)? {
        var candidates: [pid_t] = [pid]
        if let responsiblePID {
            let responsible = responsiblePID(pid)
            if responsible > 1 { candidates.append(responsible) }
        }
        var parent = pid
        for _ in 0..<6 {
            parent = parentPID(parent)
            if parent <= 1 { break }
            candidates.append(parent)
        }
        let running = candidates.compactMap { NSRunningApplication(processIdentifier: $0) }
        if let app = running.first(where: { $0.activationPolicy == .regular && $0.bundleIdentifier != nil })
            ?? running.first(where: { $0.bundleIdentifier != nil }) {
            return (app.bundleIdentifier!, app.localizedName ?? app.bundleIdentifier!, app.processIdentifier)
        }
        guard let bundle = string(object, kAudioProcessPropertyBundleID), !bundle.isEmpty else { return nil }
        return (bundle, bundle.split(separator: ".").last.map(String.init) ?? bundle, pid)
    }

    private static func parentPID(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    // MARK: Start / Stopp

    /// `appTaps`: je einzeln geregelter App deren Prozessobjekte. Alle übrigen
    /// Prozesse landen im ersten, globalen Tap.
    func start(output: OutputDevice, appTaps: [[AudioObjectID]]) throws {
        stop()
        // Ohne diesen Ausschluss würde der Tap unsere eigene Ausgabe erneut
        // aufnehmen – eine Rückkopplung. Deshalb hier lieber abbrechen.
        let ownProcess = try ownProcessObject()
        let appTaps = Array(appTaps.prefix(Processor.maxTaps - 1))

        var descriptions = [CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess] + appTaps.flatMap { $0 })]
        descriptions += appTaps.map { CATapDescription(stereoMixdownOfProcesses: $0) }

        do {
            for description in descriptions {
                description.name = "KlangEQ"
                description.isPrivate = true
                description.muteBehavior = .mutedWhenTapped
                var tap = AudioObjectID(kAudioObjectUnknown)
                try check(AudioHardwareCreateProcessTap(description, &tap), "Systemton konnte nicht abgegriffen werden")
                tapIDs.append(tap)
            }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "KlangEQ",
                kAudioAggregateDeviceUIDKey: "de.leon.klangeq.aggregate." + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceTapListKey: descriptions.map {
                    [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: $0.uuid.uuidString] as [String: Any]
                },
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Audiogerät konnte nicht angelegt werden")

            // Die Taps liegen in Listenreihenfolge hintereinander im Eingang.
            var layout: [(offset: Int, channels: Int)] = []
            var offset = 0
            for tap in tapIDs {
                var format = AudioStreamBasicDescription()
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                var address = Self.address(kAudioTapPropertyFormat)
                try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Tap-Format nicht lesbar")
                guard format.mFormatID == kAudioFormatLinearPCM,
                      format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0 else {
                    throw EngineError(message: "Nicht unterstütztes Audioformat des Systemtons.")
                }
                layout.append((offset, Int(format.mChannelsPerFrame)))
                offset += Int(format.mChannelsPerFrame)
                sampleRate = format.mSampleRate
            }

            var rate = Float64(0)
            var size = UInt32(MemoryLayout<Float64>.size)
            var rateAddress = Self.address(kAudioDevicePropertyNominalSampleRate)
            if AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &size, &rate) == noErr, rate > 0 {
                sampleRate = rate
            }
            if sampleRate <= 0 { sampleRate = 48000 }

            let inputChannels = Self.channelCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
            let outputChannels = Self.channelCount(aggregateID, scope: kAudioObjectPropertyScopeOutput)
            Log.write("Start: Ausgabe „\(output.name)“, \(Int(sampleRate)) Hz, \(tapIDs.count) Tap(s) mit \(offset) Kanälen, Gerät meldet \(inputChannels) Eingangs- und \(outputChannels) Ausgangskanäle")
            if inputChannels != offset {
                Log.write("Warnung: Kanalzahl der Taps passt nicht zum Eingang des Geräts")
            }

            processor.configure(taps: layout)
            processor.peaks[0] = 0
            processor.peaks[1] = 0

            let processor = self.processor
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
                processor.render(input: input, output: output)
            }, "Audioverarbeitung konnte nicht eingerichtet werden")
            try check(AudioDeviceStart(aggregateID, procID), "Audioverarbeitung konnte nicht gestartet werden")
        } catch {
            teardown()
            Log.write("Start fehlgeschlagen: \(error.localizedDescription)")
            throw error
        }

        self.output = output
        signature = Self.signature(output: output.uid, appTaps: appTaps)
        isRunning = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isRunning else { return }
            Log.write(String(format: "Pegel nach 5 s: Eingang %.4f, Ausgang %.4f", self.processor.peaks[0], self.processor.peaks[1]))
        }
    }

    func stop() {
        guard isRunning || aggregateID != kAudioObjectUnknown || !tapIDs.isEmpty else { return }
        teardown()
        isRunning = false
        signature = ""
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapIDs = []
    }

    private func ownProcessObject() throws -> AudioObjectID {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(Self.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else {
            throw EngineError(message: "Eigener Audioprozess nicht gefunden (Fehler \(status)).")
        }
        return object
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw EngineError(message: "\(what) (Fehler \(status)).") }
    }

    // MARK: Core-Audio-Helfer

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
