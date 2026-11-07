import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Import vom Mac (Dateien/Ordner, auch per Ziehen aus dem Finder) und Export/Ziehen in den Finder.
@MainActor
enum Transfer {
    // MARK: Import

    /// Nur ins Konto mit „Importe vom Mac“ (je Konto einstellbar).
    static func importFiles(_ urls: [URL]) async {
        let lib = Library.shared
        guard AccountStore.shared.canImport else {
            lib.error = "Importing only works into an account set to “Use for imports from this Mac” (Settings → Accounts)."
            return
        }
        let files = await Task.detached { collect(urls) }.value
        guard !files.isEmpty else { lib.status = "No photos or videos found"; return }
        var new = 0, known = 0, failed = 0
        for (n, f) in files.enumerated() {
            lib.status = "Importing \(n + 1) of \(files.count)…"
            do {
                if try await upload(f) { new += 1 } else { known += 1 }
            } catch { failed += 1 }
        }
        lib.status = "Import complete: \(new) new" + (known > 0 ? ", \(known) already in library" : "") + (failed > 0 ? ", \(failed) failed" : "")
        await lib.load()
    }

    /// Ordner rekursiv aufklappen, nur Bilder und Videos (versteckte Dateien weg).
    nonisolated static func collect(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        func ok(_ u: URL) -> Bool {
            guard let t = UTType(filenameExtension: u.pathExtension) else { return false }
            return t.conforms(to: .image) || t.conforms(to: .movie)
        }
        for u in urls {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue {
                let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL { if ok(f) { out.append(f) } }
            } else if ok(u) { out.append(u) }
        }
        return out
    }

    /// true = neu hochgeladen, false = Server kannte die Datei schon (gleiche SHA1).
    static func upload(_ file: URL) async throws -> Bool {
        let api = ImmichClient.shared
        let sha1 = try await Task.detached { try sha1Hex(file) }.value
        let deviceAssetId = "mac-" + sha1
        if try await api.bulkUploadCheck(id: deviceAssetId, checksum: sha1) != nil { return false }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let created = (attrs[.creationDate] as? Date) ?? Date()
        let modified = (attrs[.modificationDate] as? Date) ?? created
        let iso = ISO8601DateFormatter()
        let uti = UTType(filenameExtension: file.pathExtension)?.identifier ?? "public.data"
        let r = try await api.uploadAsset(file: file, filename: file.lastPathComponent, uti: uti,
                                          fields: ["fileCreatedAt": iso.string(from: min(created, modified)),
                                                   "fileModifiedAt": iso.string(from: modified),
                                                   "filename": file.lastPathComponent,
                                                   "deviceAssetId": deviceAssetId, "deviceId": "HomeRoll-Desktop"],
                                          checksum: sha1, expensive: true)
        return r.status != "duplicate"
    }

    nonisolated static func sha1Hex(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = Insecure.SHA1()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func chooseAndImport() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image, .movie, .folder]
        p.prompt = "Import"
        p.message = "Choose photos, videos, or folders for “\(AccountStore.shared.current?.name ?? "")”"
        guard p.runModal() == .OK else { return }
        Task { await importFiles(p.urls) }
    }

    // MARK: Export

    /// Lädt die Datei direkt auf die Platte (auch große Videos ohne viel Arbeitsspeicher).
    nonisolated static func download(_ id: String, edited: Bool, to dest: URL) async throws {
        let api = ImmichClient.shared
        guard let url = api.originalURL(id, edited: edited) else { throw APIError.notLoggedIn }
        let (tmp, resp) = try await URLSession.shared.download(for: try api.authorized(url))
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "Download")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// „Fotos exportieren“ (mit Änderungen) bzw. „Unbearbeitetes Original exportieren“ in einen Ordner.
    static func export(original: Bool) {
        let lib = Library.shared
        let items = lib.targets
        guard !items.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Export"
        p.message = "Export \(itemsText(items.count))\(original ? " as unmodified originals" : "") to…"
        guard p.runModal() == .OK, let dir = p.url else { return }
        Task {
            var ok = 0
            for (n, a) in items.enumerated() {
                lib.status = "Exporting \(n + 1) of \(items.count)…"
                let name = await lib.fileName(a)
                let dest = unique(dir.appendingPathComponent(name))
                if (try? await download(a.id, edited: !original, to: dest)) != nil { ok += 1 }
            }
            lib.status = "Exported \(ok) of \(items.count)"
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    nonisolated static func unique(_ u: URL) -> URL {
        var url = u, n = 2
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = u.deletingLastPathComponent().appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1
        }
        return url
    }
}

/// Ziehen aus dem Raster in den Finder: Datei wird erst beim Ablegen geladen (Original mit Änderungen).
final class AssetPromise: NSObject, NSFilePromiseProviderDelegate {
    let asset: Asset
    let name: String
    init(_ a: Asset, name: String) { asset = a; self.name = name }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let id = asset.id
        let done = Done(completionHandler)   // AppKit erwartet genau einen Aufruf, von beliebigem Thread
        Task.detached {
            do { try await Transfer.download(id, edited: true, to: url); done.call(nil) }
            catch { done.call(error) }
        }
    }

    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { OperationQueue() }

    private final class Done: @unchecked Sendable {
        let call: (Error?) -> Void
        init(_ f: @escaping (Error?) -> Void) { call = f }
    }
}
