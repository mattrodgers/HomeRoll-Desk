import AppKit

/// Teilen wie in Fotos: das Mac-Teilen-Menü (AirDrop, Nachrichten, Mail, Notizen …) für die Auswahl oder das
/// geöffnete Foto (HomeRoll-Desk #13; Idee aus dem Fork von @mattrodgers). Die Dateien (mit Änderungen) werden
/// dafür kurz in einen Zwischenordner geladen; was älter als einen Tag ist, wird beim nächsten Teilen gelöscht.
@MainActor
enum Sharing {
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HomeRoll-Teilen", isDirectory: true)
    }
    /// Das Teilen-Menü muss leben, solange es offen ist
    private static var picker: NSSharingServicePicker?

    static func share(_ items: [Asset]) {
        guard !items.isEmpty else { return }
        // Ort merken, an dem geklickt wurde (Knopf in der Symbolleiste oder Rechtsklick) – dort öffnet das Menü
        guard let win = NSApp.keyWindow, let view = win.contentView else { return }
        let p = view.convert(win.mouseLocationOutsideOfEventStream, from: nil)
        let anchor = NSRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)
        let lib = Library.shared
        Task {
            let urls = await prepare(items)
            lib.status = nil
            guard !urls.isEmpty else { lib.error = "Couldn't load the items to share"; return }
            let pk = NSSharingServicePicker(items: urls)
            picker = pk
            pk.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        }
    }

    /// Dateien zum Teilen bereitlegen (auch für den Selbsttest)
    static func prepare(_ items: [Asset]) async -> [URL] {
        prune()
        var urls: [URL] = []
        for (n, a) in items.enumerated() {
            if items.count > 1 || a.isVideo { Library.shared.status = "Preparing \(n + 1) of \(items.count)…" }
            if let u = await file(for: a) { urls.append(u) }
        }
        return urls
    }

    /// Datei mit Änderungen, je Objekt nur einmal geladen
    private static func file(for a: Asset) async -> URL? {
        let dir = folder.appendingPathComponent(a.id, isDirectory: true)
        let name = await Library.shared.fileName(a)
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? await Transfer.download(a.id, edited: true, to: dest)) != nil ? dest : nil
    }

    private static func prune() {
        let fm = FileManager.default
        let dayAgo = Date().addingTimeInterval(-86400)
        for d in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if m < dayAgo { try? fm.removeItem(at: d) }
        }
    }
}
