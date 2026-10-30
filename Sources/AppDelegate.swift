import AppKit
import ServiceManagement
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var webView: WKWebView!
    private let engine = AudioEngine()
    private var settings = Settings.load()
    private var lastError: String?
    private var positioned = false

    private var apps: [AudioApp] = []
    private var icons: [String: String] = [:]
    private lazy var catalog = EffectChain.catalog()
    private var chain: EffectChain?
    private var lastAutoKey = ""
    private var headphoneIndex: [(name: String, path: String, source: String, search: String)]?

    private static let autoEqBase = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildStatusItem()
        buildWindow()

        engine.onDevicesChanged = { [weak self] in
            guard let self else { return }
            self.reconfigure()
            self.autoSwitch()
            self.pushState()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.autoSwitch()
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshApps() }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.pushSpectrum() }

        apps = engine.audioApps()
        applySound()
        reconfigure()
        // Das Menüleisten-Symbol hat erst nach dem Start seine Position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: Aufbau

    /// Die App hat keine Menüleiste (LSUIElement), das Hauptmenü existiert
    /// trotzdem: Seine Tastenkürzel schicken cut:/copy:/paste: ohne festes
    /// Ziel los, sodass sie beim fokussierten Element im WebView ankommen.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Fenster schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "KlangEQ beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Bearbeiten")
        editMenu.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "KlangEQ")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(toggleWindow)
        }
    }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "bridge")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 840), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "KlangEQ"
        window.backgroundColor = NSColor(srgbRed: 0.169, green: 0.173, blue: 0.192, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = webView

        if let directory = Bundle.main.resourceURL?.appendingPathComponent("ui") {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
    }

    // MARK: Fenster

    @objc private func toggleWindow() {
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    private func showWindow() {
        if !positioned, let anchor = statusItem.button?.window?.frame, let screen = statusItem.button?.window?.screen ?? NSScreen.main {
            let size = window.frame.size
            let visible = screen.visibleFrame
            let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
            window.setFrameOrigin(NSPoint(x: x, y: visible.maxY - size.height - 6))
            positioned = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Audio

    /// Überträgt Klangeinstellungen und Effektkette in den Processor.
    private func applySound() {
        engine.processor.update(sound: settings.sound, sampleRate: engine.sampleRate)

        let effects = settings.sound.effects
        if effects.isEmpty {
            if chain != nil {
                chain = nil
                engine.processor.setChain(nil)
            }
        } else if let chain, chain.key == EffectChain.key(for: effects, sampleRate: engine.sampleRate) {
            chain.apply(effects)
        } else {
            let new = EffectChain(states: effects, sampleRate: engine.sampleRate)
            chain = new
            engine.processor.setChain(new)
        }
    }

    private func resolvedOutput() -> OutputDevice? {
        engine.outputDevices().first { $0.uid == settings.outputDevice } ?? engine.defaultOutput()
    }

    /// Startet, stoppt oder baut die Audiokette um, wenn sich Ausgabegerät
    /// oder die Menge der einzeln geregelten Apps geändert hat.
    private func reconfigure() {
        guard settings.enabled else {
            engine.stop()
            return
        }
        guard let output = resolvedOutput() else {
            fail("Kein Ausgabegerät gefunden.")
            return
        }
        let custom = apps.filter { settings.appVolumes[$0.id]?.isCustom == true }.prefix(Processor.maxTaps - 1)
        let taps = custom.map { $0.objects }
        let gains = [1.0] + custom.map { app -> Double in
            let volume = settings.appVolumes[app.id]!
            return volume.muted ? 0 : max(0, volume.volume)
        }

        if !engine.isRunning || engine.signature != AudioEngine.signature(output: output.uid, appTaps: taps) {
            do {
                try engine.start(output: output, appTaps: taps)
            } catch {
                fail(error.localizedDescription)
                return
            }
            applySound()
        }
        engine.processor.setTapGains(gains)
    }

    private func fail(_ message: String) {
        engine.stop()
        lastError = message
        settings.enabled = false
        settings.save()
    }

    private func refreshApps() {
        let current = engine.audioApps()
        guard current != apps else { return }
        apps = current
        reconfigure()
        pushState()
    }

    /// Lädt ein Profil, wenn eine Regel zur vorderen App oder zum Ausgabegerät passt.
    private func autoSwitch() {
        guard settings.autoSwitch else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if front == Bundle.main.bundleIdentifier { return }
        let device = resolvedOutput()?.uid ?? ""
        let rule = settings.rules.first { $0.kind == "app" && $0.value == front }
            ?? settings.rules.first { $0.kind == "device" && $0.value == device }
        guard let rule, let profile = settings.profiles.first(where: { $0.name == rule.profile }) else {
            lastAutoKey = ""
            return
        }
        let key = rule.kind + "|" + rule.value + "|" + rule.profile
        guard key != lastAutoKey else { return }
        lastAutoKey = key
        settings.sound = profile.sound
        applySound()
        settings.save()
        pushState(force: true)
    }

    // MARK: Brücke zum WebView

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            pushState(includeCatalog: true)
        case "set":
            guard let key = body["key"] as? String, let value = body["value"] else { return }
            set(key, value)
        case "setLaunchAtLogin":
            do {
                if (body["value"] as? Bool) ?? false {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                lastError = nil
            } catch {
                lastError = "Start bei Anmeldung ließ sich nicht ändern: \(error.localizedDescription)"
            }
            pushState()
        case "headphoneSearch":
            headphoneSearch((body["query"] as? String) ?? "")
        case "headphoneLoad":
            if let path = body["path"] as? String, let name = body["name"] as? String { headphoneLoad(path: path, name: name) }
        case "resetAll":
            let enabled = settings.enabled
            settings = Settings()
            settings.enabled = enabled
            lastAutoKey = ""
            applySound()
            reconfigure()
            settings.save()
            pushState(force: true)
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func set(_ key: String, _ value: Any) {
        switch key {
        case "enabled":
            settings.enabled = (value as? Bool) ?? false
            lastError = nil
            apps = engine.audioApps()
            reconfigure()
            settings.save()
            pushState()
            return
        case "sound":
            guard let sound = decode(Sound.self, value) else { return }
            settings.sound = sound
            applySound()
        case "appVolumes":
            guard let volumes = decode([String: AppVolume].self, value) else { return }
            settings.appVolumes = volumes
            reconfigure()
            if lastError != nil { pushState() }
        case "outputDevice":
            settings.outputDevice = (value as? String) ?? ""
            reconfigure()
            settings.save()
            pushState()
            return
        case "profiles":
            guard let profiles = decode([Profile].self, value) else { return }
            settings.profiles = profiles
        case "rules":
            guard let rules = decode([Rule].self, value) else { return }
            settings.rules = rules
            lastAutoKey = ""
        case "autoSwitch":
            settings.autoSwitch = (value as? Bool) ?? false
            lastAutoKey = ""
        case "ui":
            settings.ui = (value as? String) ?? "{}"
        default:
            return
        }
        settings.save()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func call(_ function: String, _ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.klang && window.klang.\(function)(\(json))", completionHandler: nil)
    }

    private func pushState(force: Bool = false, includeCatalog: Bool = false) {
        guard let settingsData = try? JSONEncoder().encode(settings),
              let settingsObject = try? JSONSerialization.jsonObject(with: settingsData) else { return }
        let regular = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { ["id": $0.bundleIdentifier!, "name": $0.localizedName ?? $0.bundleIdentifier!] }
            .sorted { $0["name"]!.localizedCaseInsensitiveCompare($1["name"]!) == .orderedAscending }
        var state: [String: Any] = [
            "settings": settingsObject,
            "running": engine.isRunning,
            "error": lastError ?? "",
            "device": (engine.isRunning ? engine.output.name : resolvedOutput()?.name) ?? "",
            "defaultDevice": engine.defaultOutput()?.name ?? "",
            "devices": engine.outputDevices().map { ["uid": $0.uid, "name": $0.name] },
            "apps": apps.map { ["id": $0.id, "name": $0.name, "playing": $0.playing, "icon": icon(for: $0)] as [String: Any] },
            "runningApps": regular,
            "launchAtLogin": SMAppService.mainApp.status == .enabled,
            "sampleRate": engine.sampleRate,
            "force": force,
        ]
        if includeCatalog,
           let data = try? JSONEncoder().encode(catalog),
           let object = try? JSONSerialization.jsonObject(with: data) {
            state["catalog"] = object
        }
        call("update", state)
    }

    private func pushSpectrum() {
        guard window.isVisible, engine.isRunning else { return }
        let values = engine.processor.spectrum(bands: 48, sampleRate: engine.sampleRate)
        let peaks = engine.processor.peaks
        let levels = (Double(peaks[2]), Double(peaks[3]))
        peaks[2] = 0
        peaks[3] = 0
        call("spectrum", ["bands": values.map { (Double($0) * 100).rounded() / 100 }, "in": levels.0, "out": levels.1])
    }

    private func icon(for app: AudioApp) -> String {
        if let cached = icons[app.id] { return cached }
        var result = ""
        if let image = NSRunningApplication(processIdentifier: app.pid)?.icon,
           let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            bitmap.size = NSSize(width: 32, height: 32)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]) {
                result = "data:image/png;base64," + png.base64EncodedString()
            }
        }
        icons[app.id] = result
        return result
    }

    // MARK: Kopfhörer-Presets (AutoEq)

    private func loadHeadphoneIndex(_ completion: @escaping (String?) -> Void) {
        if headphoneIndex != nil {
            completion(nil)
            return
        }
        let url = URL(string: Self.autoEqBase + "INDEX.md")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else {
                    completion("Kopfhörer-Liste nicht erreichbar: \(error?.localizedDescription ?? "Serverfehler")")
                    return
                }
                let pattern = try! NSRegularExpression(pattern: #"^- \[(.+)\]\(\./(.+)\) by (.+)$"#, options: .anchorsMatchLines)
                let whole = NSRange(text.startIndex..., in: text)
                self.headphoneIndex = pattern.matches(in: text, range: whole).compactMap { match in
                    guard let name = Range(match.range(at: 1), in: text),
                          let path = Range(match.range(at: 2), in: text),
                          let source = Range(match.range(at: 3), in: text) else { return nil }
                    return (String(text[name]), String(text[path]), String(text[source]), text[name].lowercased())
                }
                completion(nil)
            }
        }.resume()
    }

    private func headphoneSearch(_ query: String) {
        loadHeadphoneIndex { error in
            if let error {
                self.call("headphones", ["error": error, "results": []])
                return
            }
            let words = query.lowercased().split(separator: " ")
            let hits = (self.headphoneIndex ?? []).filter { entry in
                !words.isEmpty && words.allSatisfy { entry.search.contains($0) }
            }.prefix(60)
            self.call("headphones", ["error": "", "results": hits.map { ["name": $0.name, "path": $0.path, "source": $0.source] }])
        }
    }

    private func headphoneLoad(path: String, name: String) {
        // Nur Pfade aus der geladenen Liste abrufen.
        guard headphoneIndex?.contains(where: { $0.path == path }) == true,
              let file = path.split(separator: "/").last,
              let url = URL(string: Self.autoEqBase + path + "/" + file + "%20ParametricEQ.txt") else { return }
        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else {
                    self.call("headphoneLoaded", ["error": "Preset nicht ladbar: \(error?.localizedDescription ?? "nicht gefunden")"])
                    return
                }
                self.call("headphoneLoaded", ["error": "", "name": name, "text": text])
            }
        }.resume()
    }
}
