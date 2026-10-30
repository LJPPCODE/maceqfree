# MacEQfree

[English](README.md) · [Deutsch](README.de.md) · **Italiano** · [Español](README.es.md) · [Français](README.fr.md)

Equalizzatore gratuito per tutto il sistema su macOS, nella barra dei menu. MacEQfree cattura tutto l’audio di sistema tramite i process tap di Core Audio, lo fa passare per una propria catena di elaborazione e lo riproduce sul dispositivo di uscita scelto. Nessun driver, nessuna estensione del kernel, nessun dispositivo audio virtuale da installare.

## Funzioni

- **Equalizzatore in tre modalità**
  - *Semplice*: bassi, medi, alti
  - *Avanzato*: 10 bande
  - *Esperto*: parametrico con bande liberamente configurabili (campana, shelf bassi/alti, passa-basso/-alto/-banda, notch) e preamplificazione
- **Preset per cuffie**: ricerca nel database [AutoEq](https://github.com/jaakkopasanen/AutoEq) e caricamento dell’EQ parametrico corrispondente
- **Mixer per app**: volume e muto per ogni app (fino a 15 app singolarmente)
- **Boost del volume** fino al 200 %, bilanciamento, mono
- **Suono spaziale**: ampiezza stereo e crossfeed
- **Limiter** contro la saturazione
- **Effetti**: tutti gli effetti Audio Unit di Apple (riverbero, delay, compressore …) come catena di effetti
- **Profili e regole**: salva profili sonori e cambia automaticamente in base al dispositivo di uscita o all’app
- **Analizzatore di spettro**, dispositivo di uscita selezionabile, avvio al login
- **Lingue**: tedesco, inglese, italiano, spagnolo, francese (segue la lingua di sistema o si imposta nelle Impostazioni)

## Requisiti

- macOS 14.2 o successivo (i process tap esistono da macOS 14.2)
- Command Line Tools (`xcode-select --install`), Xcode non è necessario

## Compilare e avviare

```sh
./build.sh
open build/MacEQfree.app
```

Al primo avvio macOS chiede il permesso di registrare l’audio di sistema. Senza questo permesso non funziona nulla. L’app ha una firma ad hoc ed è pensata per il proprio Mac.

## Test della catena audio

```sh
build/MacEQfree.app/Contents/MacOS/MacEQfree --dsptest
```

Invia una sinusoide a 1 kHz attraverso il processore e gli effetti e verifica livelli, modalità EQ, mixer per app, boost, bilanciamento, suono spaziale, limiter e ogni effetto Apple trovato. Non servono né un dispositivo audio né il permesso di registrazione.

## Struttura

| File | Contenuto |
|---|---|
| `Sources/main.swift` | Punto di ingresso, `--dsptest` |
| `Sources/AppDelegate.swift` | Icona nella barra dei menu, finestra (WKWebView), ponte verso l’interfaccia, ricerca AutoEq |
| `Sources/AudioEngine.swift` | Process tap, aggregate device privato, rilevamento di dispositivi e app |
| `Sources/Processor.swift` | Catena audio in tempo reale: EQ biquad, mixer, suono spaziale, limiter |
| `Sources/Effects.swift` | Effetti Audio Unit di Apple come catena |
| `Sources/Model.swift` | Impostazioni, profili, regole (salvati in UserDefaults) |
| `Sources/L10n.swift` | Traduzioni per menu e messaggi di errore |
| `Resources/ui/index.html` | L’intera interfaccia, traduzioni comprese |
| `Resources/*.lproj` | Richiesta di autorizzazione tradotta |

Log: `~/Library/Logs/MacEQfree.log`

## Licenza

MIT, vedi [LICENSE](LICENSE).
