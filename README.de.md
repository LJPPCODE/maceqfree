# MacEQfree

[English](README.md) · **Deutsch** · [Italiano](README.it.md) · [Español](README.es.md) · [Français](README.fr.md)

Kostenloser systemweiter Equalizer für macOS in der Menüleiste. MacEQfree greift den gesamten Systemton über Core-Audio-Process-Taps ab, schickt ihn durch eine eigene Signalkette und gibt ihn auf dem gewählten Ausgabegerät wieder aus. Kein Treiber, keine Kernel-Extension, kein virtuelles Audiogerät zum Installieren.

## Funktionen

- **Equalizer in drei Modi**
  - *Einfach*: Bass, Mitten, Höhen
  - *Erweitert*: 10 Bänder
  - *Experte*: parametrisch mit frei wählbaren Bändern (Glocke, Tiefen-/Höhen-Shelf, Tief-/Hoch-/Bandpass, Kerbfilter) und Vorverstärkung
- **Kopfhörer-Presets**: Suche in der [AutoEq](https://github.com/jaakkopasanen/AutoEq)-Datenbank und Laden des passenden parametrischen EQ
- **App-Mixer**: Lautstärke und Stummschaltung pro App (bis zu 15 Apps einzeln)
- **Lautstärke-Boost** bis 200 %, Balance, Mono
- **Raumklang**: Stereobreite und Übersprechen (Crossfeed)
- **Limiter** gegen Übersteuerung
- **Effekte**: alle Audio-Unit-Effekte von Apple (Hall, Delay, Kompressor …) als Effektkette
- **Profile und Regeln**: Klangprofile speichern und automatisch je nach Ausgabegerät oder App wechseln
- **Spektrumanzeige**, Ausgabegerät wählbar, Start bei der Anmeldung
- **Sprachen**: Deutsch, Englisch, Italienisch, Spanisch, Französisch (folgt der Systemsprache oder lässt sich in den Einstellungen festlegen)

## Voraussetzungen

- macOS 14.2 oder neuer (Process-Taps gibt es erst ab 14.2)
- Command Line Tools (`xcode-select --install`), Xcode ist nicht nötig

## Bauen und starten

```sh
./build.sh
open build/MacEQfree.app
```

Beim ersten Start fragt macOS nach der Erlaubnis, Systemton aufzunehmen. Ohne die läuft nichts. Die App ist ad-hoc signiert und für den eigenen Mac gedacht.

## Test der Signalkette

```sh
build/MacEQfree.app/Contents/MacOS/MacEQfree --dsptest
```

Schickt einen 1-kHz-Sinus durch Processor und Effekte und prüft Pegel, EQ-Modi, App-Mixer, Boost, Balance, Raumklang, Limiter und jeden gefundenen Apple-Effekt. Braucht weder Audiogerät noch Aufnahme-Erlaubnis.

## Aufbau

| Datei | Inhalt |
|---|---|
| `Sources/main.swift` | Einstieg, `--dsptest` |
| `Sources/AppDelegate.swift` | Menüleisten-Icon, Fenster (WKWebView), Brücke zur Oberfläche, AutoEq-Suche |
| `Sources/AudioEngine.swift` | Process-Taps, privates Aggregate-Device, Geräte- und App-Erkennung |
| `Sources/Processor.swift` | Echtzeit-Signalkette: Biquad-EQ, Mixer, Raumklang, Limiter |
| `Sources/Effects.swift` | Apple-Audio-Unit-Effekte als Kette |
| `Sources/Model.swift` | Einstellungen, Profile, Regeln (in UserDefaults gespeichert) |
| `Sources/L10n.swift` | Übersetzungen für Menü und Fehlermeldungen |
| `Resources/ui/index.html` | Komplette Oberfläche samt Übersetzungen |
| `Resources/*.lproj` | Übersetzte Berechtigungsabfrage |

Log: `~/Library/Logs/MacEQfree.log`

## Lizenz

MIT, siehe [LICENSE](LICENSE).
