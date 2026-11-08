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

    // Fortschritt für die Fußzeile der Mediathek (LibraryFooter)
    /// Objekte, die dieser (bzw. der letzte) Abgleich anfassen will, und wie viele davon schon bearbeitet sind
    private(set) var total = 0
    private(set) var finished = 0
    /// davon neu hochgeladen / schon am Server / fehlgeschlagen
    private(set) var uploaded = 0
    private(set) var skipped = 0
    private(set) var failed = 0
    /// Abgleich lief nicht (z. B. kein Fotozugriff) – Grund für „Try Again“
    private(set) var lastError: String?
    /// Fehler des letzten fehlgeschlagenen Objekts (nur für die Details)
    private(set) var lastFailure: String?
    /// Server nicht erreichbar → Abgleich angehalten, läuft von selbst weiter, sobald er wieder antwortet
    private(set) var offline = false
    /// Ende des letzten vollständigen Abgleichs (je Konto gemerkt)
    private(set) var lastRun: Date?
    /// Wie bei iCloud-Fotos: einen Tag pausieren (oder bis „Resume“)
    private(set) var pausedUntil = UserDefaults.standard.object(forKey: "mac.photosSync.pausedUntil") as? Date
    var paused: Bool { pausedUntil.map { $0 > Date() } ?? false }
    /// Rest des laufenden bzw. pausierten Abgleichs
    var remaining: Int { max(0, total - finished) }
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var resumeTimer: Task<Void, Never>?
    @ObservationIgnored private var lastRunAccount: String?
    #if DEBUG
    /// Selbsttest: „Abgleich an/aus“ zeigen, ohne `auto` zu setzen (das würde run() und die Fotos-Abfrage auslösen)
    private var simAuto: Bool?
    /// Selbsttest läuft → nie auf Apples Fotos-Mediathek zugreifen (Zustände nur per `simulate`)
    private static let selfTest = ProcessInfo.processInfo.environment["FOTOS_SELFTEST"] != nil
    #endif

    /// Für die Anzeige: Abgleich eingeschaltet?
    var autoOn: Bool {
        #if DEBUG
        if let simAuto { return simAuto }
        #endif
        return auto
    }

    private var doneKey: String { "mac.photosSync.done.\(AccountStore.shared.currentID ?? "-")" }
    private var lastRunKey: String { "mac.photosSync.lastRun.\(AccountStore.shared.currentID ?? "-")" }
    private var done: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: doneKey) }
    }

    /// Letzten Abgleich des gerade gezeigten Kontos holen (nach Kontowechsel).
    func refreshLastRun() {
        let id = AccountStore.shared.currentID
        guard id != lastRunAccount else { return }
        lastRunAccount = id
        lastRun = UserDefaults.standard.object(forKey: lastRunKey) as? Date
        if !running { total = 0; finished = 0; uploaded = 0; skipped = 0; failed = 0; lastError = nil; lastFailure = nil }
    }

    /// Beim Start: nur wenn eingeschaltet und Zugriff schon erlaubt (keine Abfrage ohne Klick des Nutzers).
    func startIfEnabled() {
        refreshLastRun()
        if let until = pausedUntil, until > Date() { scheduleResume(until) }
        #if DEBUG
        if Self.selfTest { return }
        #endif
        guard auto, !paused, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        Task { await run() }
    }

    /// Pausieren: das gerade laufende Objekt wird noch fertig, danach hält der Abgleich an (24 h oder bis Fortsetzen).
    func pause(for seconds: TimeInterval = 24 * 3600) {
        let until = Date(timeIntervalSinceNow: seconds)
        pausedUntil = until
        UserDefaults.standard.set(until, forKey: "mac.photosSync.pausedUntil")
        pending?.cancel()
        scheduleResume(until)
    }

    func resume() {
        clearPause()
        // nur weitermachen, wenn es etwas fortzusetzen gibt (eingeschaltet oder abgebrochener Lauf)
        if autoOn || remaining > 0 { Task { await run() } }
    }

    private func clearPause() {
        pausedUntil = nil
        UserDefaults.standard.removeObject(forKey: "mac.photosSync.pausedUntil")
        resumeTimer?.cancel(); resumeTimer = nil
    }

    private func scheduleResume(_ until: Date) {
        resumeTimer?.cancel()
        resumeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.pausedUntil == until else { return }
            self.resume()
        }
    }

    func run() async {
        let lib = Library.shared
        guard !running else { return }
        guard AccountStore.shared.canImport else {
            lib.status = "Syncing with Photos only works in an account set to “Use for imports from this Mac”"; return
        }
        #if DEBUG
        if Self.selfTest { lib.status = "Self-test: no access to the Photos library"; return }
        #endif
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            lib.error = "No access to the Photos library. Please allow “HomeRoll Desktop” in System Settings → Privacy & Security → Photos."
            lastError = "No access to the Photos library"
            return
        }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        // „Sync Now“ von Hand hebt eine Pause auf (wie Fortsetzen)
        if paused { clearPause() }
        refreshLastRun()
        running = true
        lastError = nil; lastFailure = nil; offline = false
        total = 0; finished = 0; uploaded = 0; skipped = 0; failed = 0
        defer { running = false }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: opts)
        var todo: [PHAsset] = []
        let known = done
        result.enumerateObjects { a, _, _ in if !known.contains(Self.uuid(a)) { todo.append(a) } }
        guard !todo.isEmpty else { lib.status = "Photos library: everything imported"; markRun(); return }

        total = todo.count
        var new = 0, had = 0, failed = 0
        var finishedIDs = known
        for (i, a) in todo.enumerated() {
            if paused { break }
            lib.status = "Importing from Photos \(i + 1) of \(todo.count)…"
            do {
                if try await upload(a) { new += 1; uploaded += 1 } else { had += 1; skipped += 1 }
                finishedIDs.insert(Self.uuid(a))
                if i % 25 == 0 { done = finishedIDs }
            } catch {
                failed += 1; self.failed += 1
                lastFailure = error.localizedDescription
                // Verbindung weg (nicht nur ein einzelnes zu großes Video)? → anhalten statt alle Objekte durchzuprobieren
                if Library.isConnectionError(error), !(await Self.serverReachable()) { offline = true; finished += 1; break }
            }
            finished += 1
        }
        done = finishedIDs
        if offline {
            lib.status = "Offline – sync with Photos resumes when your server is reachable"
            waitForServer()
        } else if paused {
            lib.status = "Sync with Photos paused"
        } else {
            lib.status = "From Photos: \(new) new" + (had > 0 ? ", \(had) already there" : "") + (failed > 0 ? ", \(failed) failed" : "")
            markRun()
        }
        if new > 0 { await lib.load() }
    }

    private func markRun() {
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: lastRunKey)
    }

    /// Antwortet der Server überhaupt? (/api/server/ping braucht keine Anmeldung)
    static func serverReachable() async -> Bool {
        guard let d = try? await ImmichClient.shared.raw("server/ping", auth: false) else { return false }
        return String(data: d, encoding: .utf8)?.contains("pong") == true
    }

    /// Offline: in wachsenden Abständen nachsehen, ob der Server wieder da ist, dann den Abgleich fortsetzen.
    private func waitForServer() {
        guard retry == nil else { return }
        retry = Task { [weak self] in
            var delay = 15.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 300)
                guard let self, !Task.isCancelled else { return }
                if await Self.serverReachable() {
                    self.offline = false
                    self.retry = nil
                    if !self.paused { await self.run() }
                    return
                }
            }
        }
    }

    #if DEBUG
    /// Selbsttest: Zustände der Fußzeile nachstellen, ohne Fotozugriff und ohne etwas hochzuladen.
    /// nil = wieder echter Zustand.
    func simulate(_ s: String?) {
        simAuto = nil; offline = false; lastError = nil; lastFailure = nil; running = false
        total = 0; finished = 0; uploaded = 0; skipped = 0; failed = 0
        pausedUntil = UserDefaults.standard.object(forKey: "mac.photosSync.pausedUntil") as? Date
        lastRun = UserDefaults.standard.object(forKey: lastRunKey) as? Date
        guard let s else { return }
        simAuto = true
        lastRun = Date(timeIntervalSinceNow: -300)
        switch s {
        case "searching": running = true
        case "running": running = true; total = 988; finished = 312; uploaded = 300; skipped = 12
        case "paused": total = 988; finished = 312; pausedUntil = Date(timeIntervalSinceNow: 3600)
        case "error": lastError = "No access to the Photos library"
        case "partial": total = 40; finished = 40; uploaded = 37; failed = 3; lastFailure = "The file couldn’t be read."
        case "offline": total = 988; finished = 312; offline = true
        case "off": simAuto = false; lastRun = nil
        case "never": lastRun = nil
        default: total = 12; finished = 12; uploaded = 5; skipped = 7
        }
    }
    #endif

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
            guard self.auto, !self.paused else { return }
            self.pending?.cancel()
            self.pending = Task { try? await Task.sleep(for: .seconds(20)); guard !Task.isCancelled else { return }; await self.run() }
        }
    }
}
