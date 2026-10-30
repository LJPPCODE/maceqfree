import Foundation

/// Texte, die aus Swift heraus sichtbar werden (Menü, Fehlermeldungen).
/// Die Oberfläche übersetzt sich selbst, bekommt aber die Sprache von hier.
enum L10n {
    static let supported = ["de", "en", "it", "es", "fr"]
    private(set) static var language = resolve(nil)

    /// `preferred`: Sprache aus den Einstellungen, nil/leer = Systemsprache.
    static func resolve(_ preferred: String?) -> String {
        if let preferred, supported.contains(preferred) { return preferred }
        for identifier in Locale.preferredLanguages {
            let code = String(identifier.prefix(2))
            if supported.contains(code) { return code }
        }
        return "en"
    }

    static func use(_ preferred: String?) {
        language = resolve(preferred)
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        guard let row = table[key] else { return key }
        let text = row[supported.firstIndex(of: language) ?? 1]
        return args.isEmpty ? text : String(format: text, arguments: args)
    }

    // Reihenfolge je Zeile: de, en, it, es, fr
    private static let table: [String: [String]] = [
        "closeWindow": ["Fenster schließen", "Close Window", "Chiudi finestra", "Cerrar ventana", "Fermer la fenêtre"],
        "quit": ["MacEQfree beenden", "Quit MacEQfree", "Esci da MacEQfree", "Salir de MacEQfree", "Quitter MacEQfree"],
        "edit": ["Bearbeiten", "Edit", "Modifica", "Edición", "Édition"],
        "undo": ["Widerrufen", "Undo", "Annulla", "Deshacer", "Annuler"],
        "redo": ["Wiederholen", "Redo", "Ripeti", "Rehacer", "Rétablir"],
        "cut": ["Ausschneiden", "Cut", "Taglia", "Cortar", "Couper"],
        "copy": ["Kopieren", "Copy", "Copia", "Copiar", "Copier"],
        "paste": ["Einsetzen", "Paste", "Incolla", "Pegar", "Coller"],
        "selectAll": ["Alles auswählen", "Select All", "Seleziona tutto", "Seleccionar todo", "Tout sélectionner"],
        "noOutput": ["Kein Ausgabegerät gefunden.", "No output device found.", "Nessun dispositivo di uscita trovato.",
                     "No se encontró ningún dispositivo de salida.", "Aucun périphérique de sortie trouvé."],
        "tapFailed": ["Systemton konnte nicht abgegriffen werden", "Could not capture system audio", "Impossibile catturare l’audio di sistema",
                      "No se pudo capturar el audio del sistema", "Impossible de capturer le son du système"],
        "aggregateFailed": ["Audiogerät konnte nicht angelegt werden", "Could not create audio device", "Impossibile creare il dispositivo audio",
                            "No se pudo crear el dispositivo de audio", "Impossible de créer le périphérique audio"],
        "tapFormat": ["Tap-Format nicht lesbar", "Could not read tap format", "Impossibile leggere il formato del tap",
                      "No se pudo leer el formato del tap", "Impossible de lire le format du tap"],
        "unsupportedFormat": ["Nicht unterstütztes Audioformat des Systemtons.", "Unsupported system audio format.",
                              "Formato audio di sistema non supportato.", "Formato de audio del sistema no compatible.",
                              "Format audio du système non pris en charge."],
        "ioSetupFailed": ["Audioverarbeitung konnte nicht eingerichtet werden", "Could not set up audio processing",
                          "Impossibile configurare l’elaborazione audio", "No se pudo configurar el procesamiento de audio",
                          "Impossible de configurer le traitement audio"],
        "ioStartFailed": ["Audioverarbeitung konnte nicht gestartet werden", "Could not start audio processing",
                          "Impossibile avviare l’elaborazione audio", "No se pudo iniciar el procesamiento de audio",
                          "Impossible de démarrer le traitement audio"],
        "ownProcess": ["Eigener Audioprozess nicht gefunden", "Own audio process not found", "Processo audio dell’app non trovato",
                       "No se encontró el proceso de audio propio", "Processus audio de l’app introuvable"],
        "errorCode": ["%@ (Fehler %d).", "%@ (error %d).", "%@ (errore %d).", "%@ (error %d).", "%@ (erreur %d)."],
        "loginFailed": ["Start bei Anmeldung ließ sich nicht ändern: %@", "Could not change launch at login: %@",
                        "Impossibile modificare l’avvio al login: %@", "No se pudo cambiar el inicio al arrancar: %@",
                        "Impossible de modifier l’ouverture à la connexion : %@"],
        "headphoneList": ["Kopfhörer-Liste nicht erreichbar: %@", "Headphone list unavailable: %@", "Elenco cuffie non raggiungibile: %@",
                          "Lista de auriculares no disponible: %@", "Liste des casques indisponible : %@"],
        "presetLoad": ["Preset nicht ladbar: %@", "Could not load preset: %@", "Impossibile caricare il preset: %@",
                       "No se pudo cargar el preset: %@", "Impossible de charger le préréglage : %@"],
        "serverError": ["Serverfehler", "server error", "errore del server", "error del servidor", "erreur du serveur"],
        "notFound": ["nicht gefunden", "not found", "non trovato", "no encontrado", "introuvable"],
    ]
}
