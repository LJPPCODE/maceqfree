import Accelerate
import CoreAudio
import Foundation

/// Signalkette im Audio-Thread: Taps mischen → EQ → Raumklang → Effekte →
/// Lautstärke/Balance → Limiter. `render` darf weder allozieren noch blockieren.
final class Processor {
    static let maxTaps = 16
    static let maxBiquads = 40
    static let capacity = 4096

    // Layout des Parameterblocks.
    private static let iTapCount = 0
    private static let iTapGain = 1
    private static let iTapOffset = iTapGain + maxTaps
    private static let iTapChannels = iTapOffset + maxTaps
    private static let iBiquadCount = iTapChannels + maxTaps
    private static let iCoeff = iBiquadCount + 1
    private static let iGainL = iCoeff + maxBiquads * 5
    private static let iGainR = iGainL + 1
    private static let iMono = iGainL + 2
    private static let iSpatial = iGainL + 3
    private static let iWidth = iGainL + 4
    private static let iCross = iGainL + 5
    private static let iCrossLP = iGainL + 6
    private static let iCrossDelay = iGainL + 7
    private static let iLimiter = iGainL + 8
    private static let iRelease = iGainL + 9
    private static let paramCount = iGainL + 10

    private static let spectrumSize = 4096
    private static let fftSize = 2048

    private let pending: UnsafeMutablePointer<Double>
    private let active: UnsafeMutablePointer<Double>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let dirty: UnsafeMutablePointer<Bool>

    // Zustand, der nur dem Audio-Thread gehört.
    private let biquadState: UnsafeMutablePointer<Double>
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private let crossL: UnsafeMutablePointer<Float>
    private let crossR: UnsafeMutablePointer<Float>
    /// 0/1: Tiefpass der Übersprech-Kanäle, 2: Limiter-Pegel
    private let floatState: UnsafeMutablePointer<Float>
    /// 0: Position im Übersprech-Puffer, 1: Position im Spektrum-Puffer
    private let intState: UnsafeMutablePointer<Int>
    private let spectrumBuffer: UnsafeMutablePointer<Float>
    /// 0/1: Eingangs-/Ausgangsspitze seit dem Start (Diagnose), 2/3: dasselbe für die Pegelanzeige
    let peaks: UnsafeMutablePointer<Float>

    private let chainBox: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private var chain: EffectChain?

    private let fft = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
    private let window: [Float]

    init() {
        pending = .allocate(capacity: Self.paramCount)
        active = .allocate(capacity: Self.paramCount)
        pending.initialize(repeating: 0, count: Self.paramCount)
        active.initialize(repeating: 0, count: Self.paramCount)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        dirty = .allocate(capacity: 1)
        dirty.initialize(to: false)
        biquadState = .allocate(capacity: Self.maxBiquads * 4)
        biquadState.initialize(repeating: 0, count: Self.maxBiquads * 4)
        bufL = .allocate(capacity: Self.capacity)
        bufR = .allocate(capacity: Self.capacity)
        crossL = .allocate(capacity: 64)
        crossR = .allocate(capacity: 64)
        crossL.initialize(repeating: 0, count: 64)
        crossR.initialize(repeating: 0, count: 64)
        floatState = .allocate(capacity: 3)
        floatState.initialize(repeating: 0, count: 3)
        floatState[2] = 1
        intState = .allocate(capacity: 2)
        intState.initialize(repeating: 0, count: 2)
        spectrumBuffer = .allocate(capacity: Self.spectrumSize)
        spectrumBuffer.initialize(repeating: 0, count: Self.spectrumSize)
        peaks = .allocate(capacity: 4)
        peaks.initialize(repeating: 0, count: 4)
        chainBox = .allocate(capacity: 1)
        chainBox.initialize(to: nil)

        var hann = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        window = hann

        for buffer in [pending, active] {
            buffer[Self.iTapCount] = 1
            buffer[Self.iTapGain] = 1
            buffer[Self.iTapChannels] = 2
            buffer[Self.iGainL] = 1
            buffer[Self.iGainR] = 1
            buffer[Self.iWidth] = 1
        }
    }

    // MARK: Parameter (Haupt-Thread)

    private func withPending(_ body: (UnsafeMutablePointer<Double>) -> Void) {
        os_unfair_lock_lock(lock)
        body(pending)
        dirty.pointee = true
        os_unfair_lock_unlock(lock)
    }

    /// Legt fest, an welchen Eingangskanälen die einzelnen Taps liegen.
    func configure(taps: [(offset: Int, channels: Int)]) {
        withPending { p in
            let count = min(taps.count, Self.maxTaps)
            p[Self.iTapCount] = Double(count)
            for i in 0..<count {
                p[Self.iTapOffset + i] = Double(taps[i].offset)
                p[Self.iTapChannels + i] = Double(taps[i].channels)
                p[Self.iTapGain + i] = 1
            }
        }
    }

    func setTapGains(_ gains: [Double]) {
        withPending { p in
            for i in 0..<min(gains.count, Self.maxTaps) { p[Self.iTapGain + i] = gains[i] }
        }
    }

    func update(sound: Sound, sampleRate: Double) {
        var coefficients: [Double] = []
        var count = 0
        func add(_ type: String, _ freq: Double, _ gain: Double, _ q: Double) {
            let usesGain = type == "peak" || type == "lowshelf" || type == "highshelf"
            guard count < Self.maxBiquads, freq > 0, freq < sampleRate * 0.49, q > 0 else { return }
            if usesGain && gain == 0 { return }
            coefficients += Self.biquad(type: type, freq: freq, gain: gain, q: q, sampleRate: sampleRate)
            count += 1
        }

        var preamp = 0.0
        if sound.eqOn {
            switch sound.eqMode {
            case "basic":
                let g = sound.basic + [0, 0, 0]
                add("lowshelf", 100, g[0], 0.7)
                add("peak", 1000, g[1], 0.7)
                add("highshelf", 8000, g[2], 0.7)
            case "expert":
                preamp = sound.expertPreamp
                for band in sound.expert where band.on { add(band.type, band.freq, band.gain, band.q) }
            default:
                for (i, freq) in Self.graphicFrequencies.enumerated() where i < sound.advanced.count {
                    add("peak", freq, sound.advanced[i], 1.41)
                }
            }
        }

        let level = sound.muted ? 0 : max(0, sound.volume) * pow(10, preamp / 20)
        let balance = min(max(sound.balance, -1), 1)
        withPending { p in
            p[Self.iBiquadCount] = Double(count)
            for i in 0..<coefficients.count { p[Self.iCoeff + i] = coefficients[i] }
            p[Self.iGainL] = level * (balance > 0 ? 1 - balance : 1)
            p[Self.iGainR] = level * (balance < 0 ? 1 + balance : 1)
            p[Self.iMono] = sound.mono ? 1 : 0
            p[Self.iSpatial] = sound.spatialOn ? 1 : 0
            p[Self.iWidth] = min(max(sound.width, 0), 2)
            p[Self.iCross] = min(max(sound.crossfeed, 0), 1)
            p[Self.iCrossLP] = 1 - exp(-2 * Double.pi * 700 / sampleRate)
            p[Self.iCrossDelay] = min(60, max(1, (sampleRate * 0.0003).rounded()))
            p[Self.iLimiter] = sound.limiter ? 1 : 0
            p[Self.iRelease] = 1 - exp(-1 / (0.15 * sampleRate))
        }
    }

    /// Tauscht die Effektkette aus. Die alte bleibt noch kurz am Leben, falls
    /// der Audio-Thread sie gerade benutzt.
    func setChain(_ new: EffectChain?) {
        let old = chain
        chain = new
        chainBox.pointee = new.map { Unmanaged.passUnretained($0).toOpaque() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = old }
    }

    static let graphicFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// RBJ-Biquad, normalisiert auf a0 = 1: [b0, b1, b2, a1, a2]
    static func biquad(type: String, freq: Double, gain: Double, q: Double, sampleRate: Double) -> [Double] {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * freq / sampleRate
        let cs = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let s = 2 * a.squareRoot() * alpha
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch type {
        case "lowshelf":
            b0 = a * ((a + 1) - (a - 1) * cs + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cs)
            b2 = a * ((a + 1) - (a - 1) * cs - s)
            a0 = (a + 1) + (a - 1) * cs + s
            a1 = -2 * ((a - 1) + (a + 1) * cs)
            a2 = (a + 1) + (a - 1) * cs - s
        case "highshelf":
            b0 = a * ((a + 1) + (a - 1) * cs + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cs)
            b2 = a * ((a + 1) + (a - 1) * cs - s)
            a0 = (a + 1) - (a - 1) * cs + s
            a1 = 2 * ((a - 1) - (a + 1) * cs)
            a2 = (a + 1) - (a - 1) * cs - s
        case "lowpass":
            b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        case "highpass":
            b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        case "bandpass":
            b0 = alpha; b1 = 0; b2 = -alpha
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        case "notch":
            b0 = 1; b1 = -2 * cs; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        default:
            b0 = 1 + alpha * a; b1 = -2 * cs; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cs; a2 = 1 - alpha / a
        }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    // MARK: Spektrum (Haupt-Thread)

    /// Pegel je Frequenzband (20 Hz – 20 kHz, logarithmisch), 0…1 für −80…0 dB.
    func spectrum(bands: Int, sampleRate: Double) -> [Float] {
        guard let fft else { return [] }
        let n = Self.fftSize
        let position = intState[1]
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = spectrumBuffer[(position - n + i) & (Self.spectrumSize - 1)] * window[i]
        }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fft, &split, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        let reference = Float(n * n) / 4
        let binWidth = sampleRate / Double(n)
        var result = [Float](repeating: 0, count: bands)
        for band in 0..<bands {
            let low = 20 * pow(1000, Double(band) / Double(bands))
            let high = 20 * pow(1000, Double(band + 1) / Double(bands))
            let first = min(n / 2 - 1, max(1, Int(low / binWidth)))
            let last = min(n / 2 - 1, max(first, Int(high / binWidth)))
            var peak: Float = 0
            for bin in first...last { peak = max(peak, magnitudes[bin]) }
            let db = 10 * log10(max(peak / reference, 1e-12))
            result[band] = min(1, max(0, (db + 80) / 80))
        }
        return result
    }

    // MARK: Audio-Thread

    private struct Channel {
        let base: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    @inline(__always)
    private func locate(_ list: UnsafeMutableAudioBufferListPointer, _ channel: Int) -> Channel? {
        var remaining = channel
        for buffer in list {
            let count = Int(buffer.mNumberChannels)
            if count == 0 { continue }
            if remaining < count {
                guard let data = buffer.mData else { return nil }
                return Channel(base: data.assumingMemoryBound(to: Float.self) + remaining,
                               stride: count,
                               frames: Int(buffer.mDataByteSize) / (4 * count))
            }
            remaining -= count
        }
        return nil
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let out = UnsafeMutableAudioBufferListPointer(output)
        for buffer in out {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let inp = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        if os_unfair_lock_trylock(lock) {
            if dirty.pointee {
                active.update(from: pending, count: Self.paramCount)
                dirty.pointee = false
            }
            os_unfair_lock_unlock(lock)
        }

        guard let outL = locate(out, 0) else { return }
        let outR = locate(out, 1)
        let frames = min(min(outL.frames, outR?.frames ?? Int.max), Self.capacity)
        if frames <= 0 { return }
        let p = active
        let l = bufL, r = bufR
        memset(l, 0, frames * 4)
        memset(r, 0, frames * 4)

        // 1. Taps mischen (Systemton + einzeln geregelte Apps).
        var inputPeak: Float = 0
        let taps = Int(p[Self.iTapCount])
        for tap in 0..<taps {
            let gain = Float(p[Self.iTapGain + tap])
            let offset = Int(p[Self.iTapOffset + tap])
            guard let a = locate(inp, offset) else { continue }
            let b = p[Self.iTapChannels + tap] > 1 ? (locate(inp, offset + 1) ?? a) : a
            let count = min(frames, min(a.frames, b.frames))
            for i in 0..<count {
                let x = a.base[i * a.stride]
                l[i] += gain * x
                r[i] += gain * b.base[i * b.stride]
                inputPeak = max(inputPeak, abs(x))
            }
        }
        peaks[0] = max(peaks[0], inputPeak)
        peaks[2] = max(peaks[2], inputPeak)

        // 2. Equalizer.
        let biquads = Int(p[Self.iBiquadCount])
        if biquads > 0 {
            for i in 0..<frames {
                var x = Double(l[i])
                var y = Double(r[i])
                for k in 0..<biquads {
                    let c = p + Self.iCoeff + k * 5
                    let s = biquadState + k * 4
                    let ox = c[0] * x + s[0]
                    s[0] = c[1] * x - c[3] * ox + s[1]
                    s[1] = c[2] * x - c[4] * ox
                    x = ox
                    let oy = c[0] * y + s[2]
                    s[2] = c[1] * y - c[3] * oy + s[3]
                    s[3] = c[2] * y - c[4] * oy
                    y = oy
                }
                l[i] = Float(x)
                r[i] = Float(y)
            }
            // Denormale Werte kosten bei Stille unnötig CPU.
            for i in 0..<biquads * 4 where abs(biquadState[i]) < 1e-20 { biquadState[i] = 0 }
        }

        // 3. Raumklang: Stereobreite und Übersprechen (Crossfeed).
        if p[Self.iSpatial] != 0 {
            let width = Float(p[Self.iWidth])
            let cross = Float(p[Self.iCross])
            let lowpass = Float(p[Self.iCrossLP])
            let delay = Int(p[Self.iCrossDelay])
            let norm = 1 / (1 + cross)
            var position = intState[0]
            var lpL = floatState[0], lpR = floatState[1]
            for i in 0..<frames {
                let mid = (l[i] + r[i]) * 0.5
                let side = (l[i] - r[i]) * 0.5 * width
                let x = mid + side, y = mid - side
                let read = (position - delay) & 63
                lpL += lowpass * (crossL[read] - lpL)
                lpR += lowpass * (crossR[read] - lpR)
                crossL[position] = x
                crossR[position] = y
                position = (position + 1) & 63
                l[i] = (x + cross * lpR) * norm
                r[i] = (y + cross * lpL) * norm
            }
            intState[0] = position
            floatState[0] = lpL
            floatState[1] = lpR
        }

        // 4. Effekte (Audio Units).
        if let raw = chainBox.pointee {
            Unmanaged<EffectChain>.fromOpaque(raw).takeUnretainedValue().process(l, r, frames)
        }

        // 5. Lautstärke, Balance, Mono, Limiter und Ausgabe.
        let gainL = Float(p[Self.iGainL]), gainR = Float(p[Self.iGainR])
        let mono = p[Self.iMono] != 0
        let limiter = p[Self.iLimiter] != 0
        let release = Float(p[Self.iRelease])
        var reduction = floatState[2]
        var spectrumPosition = intState[1]
        var outputPeak: Float = 0
        for i in 0..<frames {
            var x = l[i], y = r[i]
            if mono {
                x = (x + y) * 0.5
                y = x
            }
            x *= gainL
            y *= gainR
            if !x.isFinite { x = 0 }
            if !y.isFinite { y = 0 }
            if limiter {
                let peak = max(abs(x), abs(y))
                let target: Float = peak > 0.98 ? 0.98 / peak : 1
                if target < reduction { reduction = target } else { reduction += (target - reduction) * release }
                x *= reduction
                y *= reduction
            }
            x = max(-1, min(1, x))
            y = max(-1, min(1, y))
            if let outR {
                outL.base[i * outL.stride] = x
                outR.base[i * outR.stride] = y
            } else {
                outL.base[i * outL.stride] = (x + y) * 0.5
            }
            spectrumBuffer[spectrumPosition] = (x + y) * 0.5
            spectrumPosition = (spectrumPosition + 1) & (Self.spectrumSize - 1)
            outputPeak = max(outputPeak, max(abs(x), abs(y)))
        }
        floatState[2] = reduction
        intState[1] = spectrumPosition
        peaks[1] = max(peaks[1], outputPeak)
        peaks[3] = max(peaks[3], outputPeak)
    }
}
