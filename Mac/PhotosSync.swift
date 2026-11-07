import Foundation
import Photos
import UniformTypeIdentifiers

/// Übernimmt neue Fotos aus Apples Fotos-App des Macs ins Mac-Konto (nie ins iPhone-Konto).
/// Gleiche Kennung wie der erste Import (tools/mac-import): deviceAssetId „mac-fotos-<UUID>“, Duplikate erkennt der
/// Server per SHA1. Erledigte Objekte merkt sich die App je Konto, damit spätere Abgleiche nur Neues anfassen.
/// Erst nach „Erlauben“ durch den Nutzer (Fotos-Zugriff); läuft danach bei jedem Start und wenn sich die Mediathek ändert.
@MainActor @Observable
final class PhotosSync: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotosSync()
    private(set) var running = false
    var auto: Bool = UserDefaults.standard.bool(forKey: "mac.photosSync.auto") {
        didSet { UserDefaults.standard.set(auto, forKey: "mac.photosSync.auto"); if auto { Task { await run() } } }
    }
    private var observing = false
    private var pending: Task<Void, Never>?

    private var doneKey: String { "mac.photosSync.done.\(AccountStore.shared.currentID ?? "-")" }
    private var done: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: doneKey) }
    }

    /// Beim Start: nur wenn eingeschaltet und Zugriff schon erlaubt (keine Abfrage ohne Klick des Nutzers).
    func startIfEnabled() {
        guard auto, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        Task { await run() }
    }

    func run() async {
        let lib = Library.shared
        guard !running else { return }
        guard AccountStore.shared.canImport else {
            lib.status = "Syncing with Photos only works in an account set to “Use for imports from this Mac”"; return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            lib.error = "No access to the Photos library. Please allow “HomeRoll Desktop” in System Settings → Privacy & Security → Photos."
            return
        }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        running = true
        defer { running = false }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: opts)
        var todo: [PHAsset] = []
        let known = done
        result.enumerateObjects { a, _, _ in if !known.contains(Self.uuid(a)) { todo.append(a) } }
        guard !todo.isEmpty else { lib.status = "Photos library: everything imported"; return }

        var new = 0, had = 0, failed = 0
        var finished = known
        for (i, a) in todo.enumerated() {
            lib.status = "Importing from Photos \(i + 1) of \(todo.count)…"
            do {
                if try await upload(a) { new += 1 } else { had += 1 }
                finished.insert(Self.uuid(a))
                if i % 25 == 0 { done = finished }
            } catch { failed += 1 }
        }
        done = finished
        lib.status = "From Photos: \(new) new" + (had > 0 ? ", \(had) already there" : "") + (failed > 0 ? ", \(failed) failed" : "")
        if new > 0 { await lib.load() }
    }

    nonisolated static func uuid(_ a: PHAsset) -> String {
        String(a.localIdentifier.split(separator: "/").first ?? Substring(a.localIdentifier))
    }

    /// Original des Objekts in eine Zwischendatei, SHA1, beim Server nachfragen, ggf. hochladen.
    private func upload(_ a: PHAsset) async throws -> Bool {
        let resources = PHAssetResource.assetResources(for: a)
        // Original (unbearbeitet) wie beim ersten Import – gleiche Datei, gleiche SHA1 → nichts doppelt
        let original: PHAssetResourceType = a.mediaType == .video ? .video : .photo
        let fallback: PHAssetResourceType = a.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
        guard let res = resources.first(where: { $0.type == original }) ?? resources.first(where: { $0.type == fallback })
        else { return false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fotos-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let o = PHAssetResourceRequestOptions(); o.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: res, toFile: file, options: o)

        let api = ImmichClient.shared
        let sha1 = try await Task.detached { try Transfer.sha1Hex(file) }.value
        let id = "mac-fotos-" + Self.uuid(a)
        if try await api.bulkUploadCheck(id: id, checksum: sha1) != nil { return false }
        let iso = ISO8601DateFormatter()
        let created = a.creationDate ?? Date()
        var fields = ["fileCreatedAt": iso.string(from: created),
                      "fileModifiedAt": iso.string(from: a.modificationDate ?? created),
                      "filename": res.originalFilename, "deviceAssetId": id, "deviceId": "Mac-Fotos-Mediathek"]
        if a.isFavorite { fields["isFavorite"] = "true" }
        let r = try await api.uploadAsset(file: file, filename: res.originalFilename, uti: res.uniformTypeIdentifier,
                                          fields: fields, checksum: sha1, expensive: true)
        if a.isHidden { try? await api.update([r.id], ["visibility": "archive"]) }
        return r.status != "duplicate"
    }

    // Neue Fotos in Apples Fotos-App → kurz warten (Import läuft oft in Schüben), dann abgleichen
    nonisolated func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor in
            guard self.auto else { return }
            self.pending?.cancel()
            self.pending = Task { try? await Task.sleep(for: .seconds(20)); guard !Task.isCancelled else { return }; await self.run() }
        }
    }
}
