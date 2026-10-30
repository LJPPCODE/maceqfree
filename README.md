# MacEQfree

**English** · [Deutsch](README.de.md) · [Italiano](README.it.md) · [Español](README.es.md) · [Français](README.fr.md)

A free system-wide equalizer for macOS that lives in the menu bar. MacEQfree captures all system audio through Core Audio process taps, runs it through its own signal chain and plays it back on the output device you choose. No driver, no kernel extension, no virtual audio device to install.

## Features

- **Equalizer with three modes**
  - *Simple*: bass, mid, treble
  - *Advanced*: 10 bands
  - *Expert*: parametric with freely configurable bands (peak, low/high shelf, low-/high-/band-pass, notch) and preamp
- **Headphone presets**: search the [AutoEq](https://github.com/jaakkopasanen/AutoEq) database and load the matching parametric EQ
- **App mixer**: volume and mute per app (up to 15 apps individually)
- **Volume boost** up to 200 %, balance, mono
- **Spatial sound**: stereo width and crossfeed
- **Limiter** against clipping
- **Effects**: all of Apple's Audio Unit effects (reverb, delay, compressor …) as an effect chain
- **Profiles and rules**: save sound profiles and switch automatically depending on output device or app
- **Spectrum display**, selectable output device, launch at login
- **Languages**: German, English, Italian, Spanish, French (follows the system language or can be set in Settings)

## Requirements

- macOS 14.2 or later (process taps were introduced in 14.2)
- Command Line Tools (`xcode-select --install`), Xcode is not required

## Build and run

```sh
./build.sh
open build/MacEQfree.app
```

On first launch macOS asks for permission to record system audio. Nothing works without it. The app is ad-hoc signed and meant for your own Mac.

## Testing the signal chain

```sh
build/MacEQfree.app/Contents/MacOS/MacEQfree --dsptest
```

Sends a 1 kHz sine through the processor and effects and checks levels, EQ modes, app mixer, boost, balance, spatial sound, limiter and every Apple effect it finds. Needs neither an audio device nor recording permission.

## Structure

| File | Contents |
|---|---|
| `Sources/main.swift` | Entry point, `--dsptest` |
| `Sources/AppDelegate.swift` | Menu bar icon, window (WKWebView), bridge to the UI, AutoEq search |
| `Sources/AudioEngine.swift` | Process taps, private aggregate device, device and app detection |
| `Sources/Processor.swift` | Real-time signal chain: biquad EQ, mixer, spatial sound, limiter |
| `Sources/Effects.swift` | Apple Audio Unit effects as a chain |
| `Sources/Model.swift` | Settings, profiles, rules (stored in UserDefaults) |
| `Sources/L10n.swift` | Translations for menu and error messages |
| `Resources/ui/index.html` | The entire user interface, including its translations |
| `Resources/*.lproj` | Localized permission prompt |

Log: `~/Library/Logs/MacEQfree.log`

## License

MIT, see [LICENSE](LICENSE).
