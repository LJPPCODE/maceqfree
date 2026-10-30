import Foundation

struct Band: Codable, Equatable {
    var type = "peak"
    var freq = 1000.0
    var gain = 0.0
    var q = 1.0
    var on = true
}

struct EffectState: Codable, Equatable {
    var id: String
    /// "typ:subtyp:hersteller" als FourCCs, z. B. "aufx:rvb2:appl".
    var component: String
    var on = true
    var mix = 1.0
    var params: [String: Double] = [:]
}

/// Alles, was den Klang bestimmt – wird auch als Profil gespeichert.
struct Sound: Codable, Equatable {
    var eqOn = true
    var eqMode = "advanced"
    var basic: [Double] = [0, 0, 0]
    var advanced = [Double](repeating: 0, count: 10)
    var expert: [Band] = [
        Band(type: "lowshelf", freq: 100, gain: 0, q: 0.7),
        Band(freq: 400, q: 1),
        Band(freq: 1500, q: 1),
        Band(freq: 5000, q: 1),
        Band(type: "highshelf", freq: 10000, gain: 0, q: 0.7),
    ]
    var expertPreamp = 0.0
    var volume = 1.0
    var muted = false
    var balance = 0.0
    var mono = false
    var spatialOn = false
    var width = 1.0
    var crossfeed = 0.0
    var limiter = true
    var effects: [EffectState] = []
}

struct AppVolume: Codable, Equatable {
    var name = ""
    var volume = 1.0
    var muted = false
    var isCustom: Bool { muted || abs(volume - 1) > 0.001 }
}

struct Profile: Codable, Equatable {
    var name: String
    var sound: Sound
}

struct Rule: Codable, Equatable {
    /// "device" oder "app"
    var kind: String
    var value: String
    var label: String
    var profile: String
}

struct Settings: Codable {
    var enabled = false
    var sound = Sound()
    var appVolumes: [String: AppVolume] = [:]
    /// Geräte-UID, leer = Systemstandard.
    var outputDevice = ""
    var profiles: [Profile] = []
    var rules: [Rule] = []
    var autoSwitch = false
    /// Zustand, den nur die Oberfläche versteht (Presets, Design, Tab) als JSON.
    var ui = "{}"

    private static let key = "settings2"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

enum Log {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/KlangEQ.log")

    static func write(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
