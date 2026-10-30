# MacEQfree

[English](README.md) · [Deutsch](README.de.md) · [Italiano](README.it.md) · [Español](README.es.md) · **Français**

Égaliseur gratuit pour tout le système sur macOS, dans la barre des menus. MacEQfree capte tout le son du système via les process taps de Core Audio, le fait passer par sa propre chaîne de traitement et le restitue sur le périphérique de sortie de votre choix. Pas de pilote, pas d’extension du noyau, pas de périphérique audio virtuel à installer.

## Fonctionnalités

- **Égaliseur en trois modes**
  - *Simple* : graves, médiums, aigus
  - *Avancé* : 10 bandes
  - *Expert* : paramétrique avec des bandes librement configurables (cloche, shelf graves/aigus, passe-bas/-haut/-bande, coupe-bande) et préampli
- **Préréglages casque** : recherche dans la base [AutoEq](https://github.com/jaakkopasanen/AutoEq) et chargement de l’EQ paramétrique correspondant
- **Mixeur par app** : volume et sourdine par app (jusqu’à 15 apps individuellement)
- **Amplification du volume** jusqu’à 200 %, balance, mono
- **Son spatial** : largeur stéréo et crossfeed
- **Limiteur** contre la saturation
- **Effets** : tous les effets Audio Unit d’Apple (réverbération, delay, compresseur …) sous forme de chaîne d’effets
- **Profils et règles** : enregistrez des profils sonores et changez-les automatiquement selon le périphérique de sortie ou l’app
- **Analyseur de spectre**, périphérique de sortie au choix, ouverture à la connexion
- **Langues** : allemand, anglais, italien, espagnol, français (suit la langue du système ou se règle dans les Réglages)

## Prérequis

- macOS 14.2 ou ultérieur (les process taps existent depuis macOS 14.2)
- Command Line Tools (`xcode-select --install`), Xcode n’est pas nécessaire

## Compiler et lancer

```sh
./build.sh
open build/MacEQfree.app
```

Au premier lancement, macOS demande l’autorisation d’enregistrer le son du système. Sans elle, rien ne fonctionne. L’app est signée ad hoc et prévue pour votre propre Mac.

## Test de la chaîne audio

```sh
build/MacEQfree.app/Contents/MacOS/MacEQfree --dsptest
```

Envoie une sinusoïde de 1 kHz à travers le processeur et les effets et vérifie les niveaux, les modes d’EQ, le mixeur par app, l’amplification, la balance, le son spatial, le limiteur et chaque effet Apple trouvé. Ne nécessite ni périphérique audio ni autorisation d’enregistrement.

## Structure

| Fichier | Contenu |
|---|---|
| `Sources/main.swift` | Point d’entrée, `--dsptest` |
| `Sources/AppDelegate.swift` | Icône de la barre des menus, fenêtre (WKWebView), pont vers l’interface, recherche AutoEq |
| `Sources/AudioEngine.swift` | Process taps, aggregate device privé, détection des périphériques et des apps |
| `Sources/Processor.swift` | Chaîne de traitement en temps réel : EQ biquad, mixeur, son spatial, limiteur |
| `Sources/Effects.swift` | Effets Audio Unit d’Apple en chaîne |
| `Sources/Model.swift` | Réglages, profils, règles (enregistrés dans UserDefaults) |
| `Sources/L10n.swift` | Traductions du menu et des messages d’erreur |
| `Resources/ui/index.html` | Toute l’interface, traductions comprises |
| `Resources/*.lproj` | Demande d’autorisation traduite |

Log : `~/Library/Logs/MacEQfree.log`

## Licence

MIT, voir [LICENSE](LICENSE).
