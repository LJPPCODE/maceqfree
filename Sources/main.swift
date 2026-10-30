import AppKit
import CoreAudio

/// `KlangEQ --dsptest` prüft die Signalkette ohne Audiogerät und ohne
/// Aufnahme-Erlaubnis: ein Sinus läuft durch Processor und Effekte.
func runDSPTest() -> Never {
    let sampleRate = 48000.0
    let frames = 512
    let input = AudioBufferList.allocate(maximumBuffers: 1)
    let output = AudioBufferList.allocate(maximumBuffers: 1)
    let inData = UnsafeMutablePointer<Float>.allocate(capacity: frames * 4)
    let outData = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    input[0] = AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(frames * 16), mData: inData)
    output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: outData)

    /// Speist einen 1-kHz-Sinus (Amplitude 0,1) in einen der beiden Taps und
    /// liefert den Pegelunterschied am Ausgang in dB sowie die Ausgangsspitze.
    func measure(_ processor: Processor, tap: Int) -> (db: Double, peak: Float, finite: Bool) {
        var phase = 0.0
        var sum = 0.0
        var count = 0
        var peak: Float = 0
        var finite = true
        for block in 0..<60 {
            for i in 0..<frames {
                let sample = Float(0.1 * sin(phase))
                phase += 2 * Double.pi * 1000 / sampleRate
                for channel in 0..<4 { inData[i * 4 + channel] = channel / 2 == tap ? sample : 0 }
            }
            processor.render(input: input.unsafePointer, output: output.unsafeMutablePointer)
            guard block >= 30 else { continue }
            for i in 0..<frames * 2 {
                let value = outData[i]
                if !value.isFinite { finite = false }
                sum += Double(value * value)
                peak = max(peak, abs(value))
                count += 1
            }
        }
        let rms = (sum / Double(count)).squareRoot()
        return (20 * log10(max(rms, 1e-9) / (0.1 / 2.0.squareRoot())), peak, finite)
    }

    func makeProcessor(_ sound: Sound, gains: [Double] = [1, 1]) -> Processor {
        let processor = Processor()
        processor.configure(taps: [(0, 2), (2, 2)])
        processor.setTapGains(gains)
        processor.update(sound: sound, sampleRate: sampleRate)
        return processor
    }

    var failures = 0
    func expect(_ name: String, _ value: Double, _ target: Double, tolerance: Double = 0.3) {
        let ok = abs(value - target) <= tolerance
        if !ok { failures += 1 }
        print(String(format: "%@ %@: %.2f dB (erwartet %.2f)", ok ? "OK  " : "FAIL", name, value, target))
    }

    var sound = Sound()
    sound.limiter = false
    expect("Durchleitung ohne EQ", measure(makeProcessor(sound), tap: 0).db, 0)

    sound.advanced[5] = 6
    expect("Erweitert +6 dB bei 1 kHz", measure(makeProcessor(sound), tap: 0).db, 6)

    sound = Sound()
    sound.limiter = false
    sound.eqMode = "basic"
    sound.basic = [0, -6, 0]
    expect("Einfach −6 dB Mitten", measure(makeProcessor(sound), tap: 0).db, -6)

    sound = Sound()
    sound.limiter = false
    sound.eqMode = "expert"
    sound.expertPreamp = -3
    sound.expert = [Band(type: "peak", freq: 1000, gain: 4, q: 2), Band(type: "notch", freq: 5000, gain: 0, q: 4)]
    expect("Experte +4 dB, Vorverstärkung −3 dB", measure(makeProcessor(sound), tap: 0).db, 1)

    sound.expert = [Band(type: "highpass", freq: 8000, gain: 0, q: 0.707)]
    sound.expertPreamp = 0
    let highpass = measure(makeProcessor(sound), tap: 0).db
    let highpassOK = highpass < -30
    if !highpassOK { failures += 1 }
    print(String(format: "%@ Hochpass 8 kHz dämpft 1 kHz: %.1f dB", highpassOK ? "OK  " : "FAIL", highpass))

    sound = Sound()
    sound.limiter = false
    expect("App-Mixer: zweiter Tap auf 50 %", measure(makeProcessor(sound, gains: [1, 0.5]), tap: 1).db, -6.02)
    expect("App-Mixer: stummgeschaltet", measure(makeProcessor(sound, gains: [1, 0]), tap: 1).db, -139, tolerance: 60)

    sound.volume = 2
    expect("Boost 200 %", measure(makeProcessor(sound), tap: 0).db, 6.02)
    sound.volume = 1
    sound.balance = -1
    expect("Balance ganz links", measure(makeProcessor(sound), tap: 0).db, -3.01)
    sound.balance = 0
    sound.spatialOn = true
    sound.width = 1.5
    sound.crossfeed = 0.4
    let spatial = measure(makeProcessor(sound), tap: 0)
    print(String(format: "%@ Raumklang: %.2f dB, endlich: %@", spatial.finite ? "OK  " : "FAIL", spatial.db, spatial.finite ? "ja" : "nein"))
    if !spatial.finite { failures += 1 }

    sound = Sound()
    sound.volume = 2
    sound.advanced = [Double](repeating: 12, count: 10)
    let limited = measure(makeProcessor(sound), tap: 0)
    let limiterOK = limited.peak <= 1.0 && limited.peak > 0.5
    if !limiterOK { failures += 1 }
    print(String(format: "%@ Limiter hält Spitze unter 1,0: %.3f", limiterOK ? "OK  " : "FAIL", limited.peak))

    let catalog = EffectChain.catalog()
    print("Effekte gefunden: \(catalog.count)")
    for info in catalog {
        var state = EffectState(id: "test", component: info.key)
        for parameter in info.params { state.params[parameter.id] = parameter.def }
        var sound = Sound()
        sound.effects = [state]
        let processor = makeProcessor(sound)
        let chain = EffectChain(states: sound.effects, sampleRate: sampleRate)
        processor.setChain(chain)
        let result = measure(processor, tap: 0)
        if !result.finite { failures += 1 }
        print(String(format: "%@ Effekt %@ (%d Parameter): %.1f dB", result.finite ? "OK  " : "FAIL",
                     info.name, info.params.count, result.db))
        processor.setChain(nil)
    }

    print(failures == 0 ? "ALLE TESTS BESTANDEN" : "\(failures) TEST(S) FEHLGESCHLAGEN")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--dsptest") {
    runDSPTest()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
