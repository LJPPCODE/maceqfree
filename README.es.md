# MacEQfree

[English](README.md) · [Deutsch](README.de.md) · [Italiano](README.it.md) · **Español** · [Français](README.fr.md)

Ecualizador gratuito para todo el sistema en macOS, en la barra de menús. MacEQfree captura todo el audio del sistema mediante los process taps de Core Audio, lo pasa por su propia cadena de señal y lo reproduce en el dispositivo de salida que elijas. Sin driver, sin extensión del kernel, sin dispositivo de audio virtual que instalar.

## Funciones

- **Ecualizador con tres modos**
  - *Simple*: graves, medios, agudos
  - *Avanzado*: 10 bandas
  - *Experto*: paramétrico con bandas configurables libremente (campana, shelf de graves/agudos, paso bajo/alto/banda, notch) y preamplificación
- **Presets de auriculares**: búsqueda en la base de datos de [AutoEq](https://github.com/jaakkopasanen/AutoEq) y carga del EQ paramétrico correspondiente
- **Mezclador por app**: volumen y silencio por app (hasta 15 apps por separado)
- **Aumento de volumen** hasta el 200 %, balance, mono
- **Sonido espacial**: amplitud estéreo y crossfeed
- **Limitador** contra la saturación
- **Efectos**: todos los efectos Audio Unit de Apple (reverberación, delay, compresor …) como cadena de efectos
- **Perfiles y reglas**: guarda perfiles de sonido y cámbialos automáticamente según el dispositivo de salida o la app
- **Analizador de espectro**, dispositivo de salida seleccionable, inicio al arrancar sesión
- **Idiomas**: alemán, inglés, italiano, español, francés (sigue el idioma del sistema o se elige en Ajustes)

## Requisitos

- macOS 14.2 o posterior (los process taps existen desde macOS 14.2)
- Command Line Tools (`xcode-select --install`), no hace falta Xcode

## Compilar y ejecutar

```sh
./build.sh
open build/MacEQfree.app
```

En el primer inicio, macOS pide permiso para grabar el audio del sistema. Sin él no funciona nada. La app tiene una firma ad hoc y está pensada para tu propio Mac.

## Prueba de la cadena de señal

```sh
build/MacEQfree.app/Contents/MacOS/MacEQfree --dsptest
```

Envía una senoide de 1 kHz a través del procesador y los efectos y comprueba niveles, modos de EQ, mezclador por app, aumento de volumen, balance, sonido espacial, limitador y cada efecto de Apple encontrado. No necesita dispositivo de audio ni permiso de grabación.

## Estructura

| Archivo | Contenido |
|---|---|
| `Sources/main.swift` | Punto de entrada, `--dsptest` |
| `Sources/AppDelegate.swift` | Icono en la barra de menús, ventana (WKWebView), puente con la interfaz, búsqueda en AutoEq |
| `Sources/AudioEngine.swift` | Process taps, aggregate device privado, detección de dispositivos y apps |
| `Sources/Processor.swift` | Cadena de señal en tiempo real: EQ biquad, mezclador, sonido espacial, limitador |
| `Sources/Effects.swift` | Efectos Audio Unit de Apple como cadena |
| `Sources/Model.swift` | Ajustes, perfiles, reglas (guardados en UserDefaults) |
| `Sources/L10n.swift` | Traducciones del menú y de los mensajes de error |
| `Resources/ui/index.html` | Toda la interfaz, incluidas sus traducciones |
| `Resources/*.lproj` | Solicitud de permiso traducida |

Log: `~/Library/Logs/MacEQfree.log`

## Licencia

MIT, ver [LICENSE](LICENSE).
