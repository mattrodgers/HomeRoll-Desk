#if DEBUG
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Selbsttest ohne Mausklicks (nur Debug, nur mit Testkonto über FOTOS_SERVER/FOTOS_TOKEN):
/// FOTOS_SELFTEST=<Ordner> → geht alle Bereiche durch, fotografiert das eigene Fenster (braucht keine
/// Bildschirmaufnahme-Freigabe) und prüft Änderungen am Server – jede Änderung wird wieder zurückgenommen.
/// Ausgabe: Zeilen „ERGEBNIS|Schritt|ok|Details“ auf stdout, Bilder als PNG im Ordner.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FOTOS_SELFTEST"], env["FOTOS_TOKEN"] != nil else { return }
        Task { await run(URL(fileURLWithPath: dir)) }
    }

    private static var out: URL!
    private static let lib = Library.shared
    private static let api = ImmichClient.shared

    static func log(_ step: String, _ ok: Bool, _ detail: String = "") {
        print("ERGEBNIS|\(step)|\(ok ? "ok" : "FEHLER")|\(detail)")
        fflush(stdout)
    }

    static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// Bereich wählen und warten, bis genau dieser fertig geladen ist (nicht der vorige).
    static func show(_ s: Source) async {
        lib.select(s)
        await wait(0.4)
        _ = await waitFor(20) { lib.source == s && !lib.loading }
    }

    static func waitFor(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        var t = 0.0
        while !cond() && t < timeout { await wait(0.25); t += 0.25 }
        return cond()
    }

    static func snap(_ name: String, window: NSWindow? = nil) {
        guard let w = window ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.frame.height > 300 }),
              let img = windowImage(CGWindowID(w.windowNumber)) ?? viewImage(w.contentView)
        else { log("Bild \(name)", false, "kein Fenster"); return }
        let url = out.appendingPathComponent("\(name).png")
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }

    /// Eigenes Fenster als Bild. CGWindowListCreateImage ist im SDK gesperrt, im System aber noch da; für die
    /// eigenen Fenster braucht es keine Bildschirmaufnahme-Freigabe (ScreenCaptureKit schon).
    private static func windowImage(_ id: CGWindowID) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        // optionIncludingWindow = 8, boundsIgnoreFraming | bestResolution = 1 | 8
        return unsafeBitCast(sym, to: Fn.self)(.null, 8, id, 9)?.takeRetainedValue()
    }

    /// Ersatz, wenn das System kein Fensterbild liefert (schwebende Fenster): Inhalt selbst zeichnen lassen.
    private static func viewImage(_ v: NSView?) -> CGImage? {
        guard let v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
    }

    static func run(_ dir: URL) async {
        out = dir
        NSApp.activate()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.frame.height > 300 }) {
            w.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 800), display: true)
        }

        // 1. Mediathek
        let t0 = Date()
        let loaded = await waitFor(25) { !lib.sections.isEmpty }
        log("Mediathek laden", loaded, "\(lib.sections.count) Monate, \(lib.totalCount) Objekte, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        guard loaded else { return finish() }
        let last = lib.sections.count - 1
        _ = await waitFor(15) { lib.sections[last].assets != nil }
        await wait(2.5)
        snap("01-mediathek")
        // nur Fußzeile + Offline prüfen (schneller Durchlauf): FOTOS_SELFTEST_ONLY=footer
        if ProcessInfo.processInfo.environment["FOTOS_SELFTEST_ONLY"] == "footer" {
            await footerTests()
            await offlineTest()
            return finish()
        }
        // nur Albumcover prüfen: FOTOS_SELFTEST_ONLY=albums
        if ProcessInfo.processInfo.environment["FOTOS_SELFTEST_ONLY"] == "albums" {
            await keyPhotoTest()
            return finish()
        }
        await scrollBenchmark()
        await footerTests()

        // 2. Auswahl + Einzelansicht + Blättern + Info
        guard let la = lib.sections[last].assets?.last, let lp = lib.indexPath(la.id) else { log("Auswahl", false); return finish() }
        lib.selection = [la.id]; lib.focused = la; lib.onReloadAll?()
        await wait(0.5)
        log("Auswahl", lib.selectedAssets.count == 1)
        lib.open(lp)
        await wait(3)
        snap("02-einzelansicht")
        let before = lib.viewer
        if let p = lib.step(lp, by: -1) { lib.viewer = p }
        await wait(2)
        log("Blättern ←", lib.viewer != before && lib.viewer != nil, "\(String(describing: before)) → \(String(describing: lib.viewer))")
        snap("03-einzelansicht-zurueck")
        InfoWindow.show()
        await wait(3)
        if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) {
            (panel as? NSPanel)?.hidesOnDeactivate = false; panel.orderFrontRegardless(); panel.display(); await wait(2)
            snap("04-info", window: panel); log("Info-Fenster", true)
        }
        else { log("Info-Fenster", false) }
        InfoWindow.show()   // wieder zu
        lib.closeViewer()
        await wait(1)
        log("Einzelansicht schließen", lib.viewer == nil)

        // 3. Zoomstufen
        let z = lib.zoom
        lib.zoom = 0; await wait(2); snap("05-zoom-klein")
        lib.zoom = 4; await wait(2.5); snap("06-zoom-gross")
        lib.zoom = z; await wait(1)

        // 3b. Jahre / Monate / Sprung in „Alle Fotos“
        lib.granularity = .years; await wait(3); snap("05b-jahre")
        lib.granularity = .months; await wait(3); snap("05c-monate")
        let target = max(0, lib.sections.count / 2)
        lib.jump(to: target); await wait(2.5)
        let visible = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(findScroll) }.first
            .flatMap { ($0.documentView as? NSCollectionView)?.indexPathsForVisibleItems().map(\.section) } ?? []
        log("Monat anspringen", lib.granularity == .all && visible.contains(target), "Ziel \(target), sichtbar \(Set(visible).sorted())")
        snap("05d-sprung")

        // 4. Bereiche der Seitenleiste
        for (s, name) in [(Source.favorites, "07-favoriten"), (.videos, "08-videos"), (.albums, "09-alben"),
                          (.people, "10-personen"), (.category("Bildschirmfotos"), "11-bildschirmfotos"),
                          (.search("Strand"), "12-suche"), (.trash, "13-geloescht")] {
            lib.select(s)
            let ok = await waitFor(20) { !lib.loading && (s.isOverview || !lib.sections.isEmpty || lib.error != nil) }
            await wait(2.5)
            snap(name)
            let n = s == .albums ? lib.albums.count : s == .people ? lib.people.count : lib.totalCount
            log("Bereich \(s.title)", ok && lib.error == nil, "\(n) Einträge")
            lib.error = nil
        }
        // 4b. Rückblicke, Karte, Duplikate (eigene Ansichten)
        for (s, name) in [(Source.memories, "15-rueckblicke"), (.map, "16-karte"), (.duplicates, "17-duplikate")] {
            lib.select(s); await wait(6); snap(name)
            log("Bereich \(s.title)", lib.error == nil, s == .memories ? "\(lib.memories.count) Rückblicke" : "")
        }
        // Ort aus der Karte
        let markers = (try? await api.mapMarkers()) ?? []
        if let city = markers.compactMap(\.city).first {
            let expected = markers.filter { $0.city == city }.count
            await show(.city(city))
            log("Ort aus der Karte", lib.totalCount > 0, "„\(city)“: \(lib.totalCount) Objekte (Karte: \(expected))")
        }

        // 4c. Intelligentes Album (Favorit = ja) muss dieselbe Anzahl wie „Favoriten“ liefern
        var sa = SmartAlbum(); sa.name = "Selbsttest Favoriten"; sa.conditions[0].field = .favorite
        SmartAlbums.shared.save(sa)
        await show(.favorites)
        let favCount = lib.totalCount
        await show(.smart(sa.id, sa.name))
        await wait(1); snap("18-intelligentes-album")
        log("Intelligentes Album", lib.totalCount == favCount && favCount > 0, "\(lib.totalCount) = Favoriten \(favCount)")
        var sb = SmartAlbum(); sb.conditions = [SmartAlbum.Condition(field: .video), SmartAlbum.Condition(field: .lastDays, number: 3650)]
        let vids = (try? await api.search(filter: sb.filter, size: 1000))?.count ?? -1
        log("Intelligentes Album: Video + Zeitraum", vids >= 0, "\(vids) Videos der letzten 10 Jahre")
        SmartAlbums.shared.delete(sa.id)

        // 4d. Person umbenennen und zurück (Testkonto)
        if AccountStore.shared.canWrite {
            await lib.loadPeople()
            if let p = lib.people.first {
                await PeopleActions.update(p, ["name": "Selbsttest Person"], lib)
                let renamed = lib.people.contains { $0.id == p.id && $0.name == "Selbsttest Person" }
                await PeopleActions.update(p, ["name": p.name], lib)
                let back = lib.people.contains { $0.id == p.id && $0.name == p.name }
                log("Person umbenennen", renamed && back, "„\(p.name)“ → „Selbsttest Person“ → zurück")
            }
        }

        lib.select(.library)
        _ = await waitFor(20) { lib.source == .library && !lib.loading && lib.sections.last?.bucket != nil }
        lib.ensureLoaded(lib.sections.count - 1)
        _ = await waitFor(15) { lib.sections.last?.assets != nil }

        // 5. Änderungen am Testkonto – jeweils zurückgenommen
        if AccountStore.shared.canWrite, let s = lib.sections.last?.assets ?? nil, let a = s.last {
            lib.selection = [a.id]; lib.focused = a
            await lib.toggleFavorite()
            let f1 = (try? await api.asset(a.id))?.isFavorite
            await lib.toggleFavorite()
            let f2 = (try? await api.asset(a.id))?.isFavorite
            log("Favorit an/aus", f1 == !a.isFavorite && f2 == a.isFavorite, "\(a.isFavorite) → \(String(describing: f1)) → \(String(describing: f2))")

            if a.isImage {
                await lib.rotate(clockwise: true)
                let r1 = String(data: (try? await api.raw("assets/\(a.id)/edits")) ?? Data(), encoding: .utf8) ?? ""
                await lib.rotate(clockwise: false)
                let r2 = String(data: (try? await api.raw("assets/\(a.id)/edits")) ?? Data(), encoding: .utf8) ?? ""
                log("Drehen ⌘R/⌥⌘R", r1.contains("\"angle\":90") && !r2.contains("rotate"), "\(r1.prefix(120)) | \(r2.prefix(80))")
            }

            // Album anlegen → Foto drin → wieder löschen
            lib.selection = [a.id]
            let name = "Mac-Selbsttest \(Int(Date().timeIntervalSince1970))"
            log("Ziel für Album", lib.targets.count == 1, "\(lib.targets.count) ausgewählt, Index: \(lib.indexPath(a.id) != nil)")
            await lib.createAlbum(name)
            let al = lib.albums.first { $0.albumName == name }
            log("Neues Album mit Auswahl", al?.assetCount == 1, al.map { "\($0.assetCount) Objekt" } ?? "fehlt")
            if let al { await lib.deleteAlbum(al.id) }
            log("Album löschen", !lib.albums.contains { $0.albumName == name })
            await keyPhotoTest()
            // Bearbeiten: Oberfläche zeigen, dann über denselben Kern sichern → neue Fassung gestapelt, danach entfernen
            if let photo = s.last(where: \.isImage) {
                lib.selection = [photo.id]; lib.focused = photo
                lib.edit()
                await wait(4)
                snap("14-bearbeiten")
                let pdf = await Printing.pdf([photo.id])
                log("Drucken (Seiten erzeugt)", pdf.pageCount == 1, "\(pdf.pageCount) Seite")
                lib.editing = nil
                let es = EditSession(asset: photo)
                await es.load()
                // Profi-Werkzeuge müssen das Bild sichtbar verändern (gleicher Kern wie am iPhone)
                if let b = es.base {
                    var p = EditState(); p.curves = [0, 0.1, 0.35, 0.7, 1]; p.levels = [0.1, 1.3, 0.9]
                    p.selective = [SelectiveHue.blue.rawValue: [0.5, 0.8, -0.3]]
                    let r = es.renderer
                    let a = r.cgImage(r.apply(b, EditState())), c = r.cgImage(r.apply(b, p))
                    let diff = (a.flatMap { $0.dataProvider?.data as Data? } ?? Data()) != (c.flatMap { $0.dataProvider?.data as Data? } ?? Data())
                    var roundTrip = false
                    if let d = try? JSONEncoder().encode(p), let back = try? JSONDecoder().decode(EditState.self, from: d) { roundTrip = back == p && back.hasPro }
                    log("Kurven/Tonwerte/Selektive Farbe", diff && roundTrip && p.hasColor, "Bild verändert: \(diff), Speichern/Laden: \(roundTrip)")
                }
                es.state.values[.exposure] = 0.35; es.state.filter = .vivid; es.state.curves = [0, 0.2, 0.5, 0.8, 1]
                do {
                    let new = try await es.save()
                    let dto = try? await api.asset(new.id)
                    let meta = await api.metadata(new.id, key: "fotos.edit")
                    log("Bearbeiten sichern", new.id != photo.id && dto?.stack != nil && (meta?["originalId"] as? String) == photo.id,
                        "neue Fassung, Stapel: \(dto?.stack?.assetCount ?? 0), Original verknüpft: \(meta?["originalId"] as? String == photo.id)")
                    await lib.afterEdit(old: photo, new: new)
                    try? await api.deleteForever([new.id])
                    await lib.load()
                    lib.ensureLoaded(lib.sections.count - 1)
                    _ = await waitFor(15) { lib.sections.last?.assets != nil }
                    let back = (try? await api.asset(photo.id)) != nil
                    log("Bearbeitung wieder entfernt", back, "Original noch da: \(back)")
                } catch { log("Bearbeiten sichern", false, error.localizedDescription) }
            }
        } else { log("Änderungen", false, "Konto nur ansehen oder leer") }

        // 6. Import (zweimal dieselbe Datei → einmal neu, einmal schon vorhanden), danach endgültig löschen
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mac-selbsttest-\(UUID().uuidString.prefix(8)).png")
        if !AccountStore.shared.canImport { log("Import übersprungen (Konto nur ansehen)", true) }
        else if writeTestImage(tmp) {
            let first = (try? await Transfer.upload(tmp))
            let second = (try? await Transfer.upload(tmp))
            log("Import + Duplikat-Erkennung", first == true && second == false, "1. \(String(describing: first)), 2. \(String(describing: second))")
            let sha = (try? Transfer.sha1Hex(tmp)) ?? ""
            if let id = try? await api.bulkUploadCheck(id: "x", checksum: sha) {
                try? await api.deleteForever([id])
                log("Testbild wieder entfernt", (try? await api.bulkUploadCheck(id: "x", checksum: sha)) == nil)
            }
            try? FileManager.default.removeItem(at: tmp)
        }

        // 7. Export (Original einer Datei)
        if let a = lib.sections.last?.assets?.last {
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("mac-export-\(a.id)")
            do {
                try await Transfer.download(a.id, edited: true, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
                log("Export", size > 1000, "\(size) Byte")
                try? FileManager.default.removeItem(at: dest)
            } catch { log("Export", false, error.localizedDescription) }
        }
        await offlineTest()
        finish()
    }

    // MARK: Fußzeile der Mediathek

    /// Zustände der Fußzeile: PhotosSync per Debug-Hook nachgestellt (kein Fotozugriff, kein Upload), Text + Knopf
    /// geprüft, Fußzeile fotografiert (Ausschnitt unten im Fenster), hell und dunkel, Details, Konto „View only“.
    static func footerTests() async {
        let sync = PhotosSync.shared, model = FooterModel.shared
        if lib.granularity != .all { lib.granularity = .all; await wait(1) }
        lib.onScrollToEnd?()
        await wait(1.5)
        let stats = await api.statistics()
        _ = await waitFor(10) { model.stats != nil }
        let c = model.countText ?? ""
        let countOK = stats.map { s in
            (s.images == 0 || c.contains("\(FooterStatus.number(s.images)) Photo")) &&
            (s.videos == 0 || c.contains("\(FooterStatus.number(s.videos)) Video"))
        } ?? false
        log("Fußzeile: Anzahl wie Server", countOK,
            "„\(model.countText ?? "-")“, Server \(stats.map { "\($0.images)/\($0.videos)" } ?? "-")")
        log("Fußzeile: unten in der Mediathek", footerHeight() == LibraryFooter.height, "Höhe \(footerHeight())")

        typealias A = FooterStatus.Action
        let cases: [(String, String, String, A?)] = [
            ("done", "fz-01-backed-up", "Backed up to your server · 5 minutes ago", nil),
            ("running", "fz-02-running", "676 items being backed up", .pause),
            ("paused", "fz-03-paused", "Backup paused for 676 items", .resume),
            ("searching", "fz-04-searching", "Looking for new photos…", .pause),
            ("error", "fz-05-error", "Sync interrupted: No access to the Photos library", .retry),
            ("partial", "fz-06-partial", "3 items not backed up yet", .retry),
            ("off", "fz-07-off", "Sync with Photos is off", .turnOn),
            ("never", "fz-08-never", "Sync with Photos hasn’t run yet", .syncNow),
            ("offline", "fz-09-offline", "Offline – will resume when your server is reachable", nil),
        ]
        for (state, name, text, action) in cases {
            sync.simulate(state)
            await wait(0.8)
            let st = FooterStatus.current()
            snapFooter(name)
            log("Fußzeile \(state)", st?.text == text && st?.action == action,
                "„\(st?.text ?? "-")“ · \(st?.action?.title ?? "ohne Knopf")")
        }
        // Balken: läuft = Anteil fertig, pausiert gedimmt
        sync.simulate("running")
        let pr = FooterStatus.current()
        log("Fußzeile: Balken", abs((pr?.progress ?? 0) - 312.0 / 988.0) < 0.001 && pr?.dimmed == false, "\(pr?.progress ?? -1)")

        // Pausieren gilt 24 h (wie iCloud), Fortsetzen hebt es auf – ohne Fotozugriff (run() ist im Selbsttest gesperrt)
        sync.simulate(nil)
        FooterStatus.Action.pause.perform()
        let until = sync.pausedUntil.map { $0.timeIntervalSinceNow } ?? 0
        let stored = UserDefaults.standard.object(forKey: "mac.photosSync.pausedUntil") != nil
        log("Pausieren: 24 h", sync.paused && abs(until - 24 * 3600) < 60 && stored, "\(Int(until)) s, gemerkt: \(stored)")
        FooterStatus.Action.resume.perform()
        await wait(0.5)
        log("Fortsetzen", !sync.paused && UserDefaults.standard.object(forKey: "mac.photosSync.pausedUntil") == nil)

        // hell und dunkel ausdrücklich (unabhängig vom Systemlook)
        for (look, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: look)
            for (state, name) in [("running", "fz-11-\(tag)-running"), ("paused", "fz-11-\(tag)-paused"), ("done", "fz-11-\(tag)-backed-up")] {
                sync.simulate(state); await wait(1.2); snapFooter(name)
            }
            snap("fz-11-\(tag)-window")
        }
        NSApp.appearance = nil
        await wait(0.8)

        // Details (Klick auf die Fußzeile)
        sync.simulate("partial")
        model.showDetails = true
        await wait(1.5)
        if let pop = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
            snap("fz-13-details", window: pop); log("Fußzeile: Details", true, "\(Int(pop.frame.width))×\(Int(pop.frame.height))")
        } else { log("Fußzeile: Details", false, "kein Popover") }
        model.showDetails = false
        await wait(0.5)

        // Konto „View only“: nur die Anzahl (Einstellungen danach unverändert zurück)
        let d = UserDefaults.standard
        let keep = (d.object(forKey: "mac.accounts"), d.object(forKey: "mac.currentAccount"))
        if let a = AccountStore.shared.current {
            var ro = a; ro.readOnly = true
            AccountStore.shared.update(ro)
            await wait(0.8)
            snapFooter("fz-14-view-only")
            log("Fußzeile View only: nur Anzahl", FooterStatus.current() == nil && model.countText != nil, model.countText ?? "-")
            AccountStore.shared.update(a)
        }
        for (k, v) in [("mac.accounts", keep.0), ("mac.currentAccount", keep.1)] {
            if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
        sync.simulate(nil)

        // nicht in anderen Bereichen
        await show(.favorites)
        await wait(1)
        log("Fußzeile nicht in Favoriten", footerHeight() == 0, "Höhe \(footerHeight())")
        await show(.library)
        _ = await waitFor(15) { lib.sections.last?.assets != nil }
        lib.onScrollToEnd?()
        await wait(1)
    }

    /// Server „weg“ (Adresse ohne Dienst) → kein Fehlerfenster, Raster bleibt stehen, Symbolleiste und Fußzeile zeigen
    /// Offline; danach Server zurück → die App lädt von selbst neu (Neuversuch nach 2/5/15 s), Offline verschwindet.
    static func offlineTest() async {
        let env = ProcessInfo.processInfo.environment
        guard let srv = env["FOTOS_SERVER"], let tok = env["FOTOS_TOKEN"], let url = URL(string: srv) else { return }
        PhotosSync.shared.simulate(nil)
        if lib.source != .library { await show(.library) }
        let before = lib.totalCount
        ImmichClient.shared.activate(server: URL(string: "http://127.0.0.1:9")!, token: tok)
        await lib.load()
        await wait(1.5)
        let fz = FooterStatus.current()?.text ?? "-"
        snap("fz-12-offline-window")
        snapFooter("fz-12-offline")
        log("Offline: kein Fehlerfenster", lib.error == nil && lib.offline, "error: \(lib.error ?? "–"), offline: \(lib.offline)")
        log("Offline: Symbolleiste", lib.status?.hasPrefix("Offline") == true, lib.status ?? "-")
        log("Offline: Raster bleibt", lib.totalCount == before && before > 0 && footerHeight() == LibraryFooter.height,
            "\(lib.totalCount) von \(before) Objekten, Fußzeile \(footerHeight())")
        log("Fußzeile offline (echt)", fz == "Offline – will resume when your server is reachable", fz)
        // Aktionen melden Fehler weiter als Fenster
        if AccountStore.shared.canWrite, let a = lib.sections.last?.assets?.last {
            lib.selection = [a.id]; lib.focused = a
            await lib.toggleFavorite()
            log("Offline: Aktion meldet Fehler", lib.error != nil, lib.error ?? "-")
            lib.error = nil
            lib.selection = []; lib.focused = nil
        }
        // Server zurück: kein Neuladen von Hand – der Neuversuch muss es von selbst schaffen
        ImmichClient.shared.activate(server: url, token: tok)
        let back = await waitFor(30) { !lib.offline && !lib.loading && !lib.sections.isEmpty }
        _ = await waitFor(10) { !Connectivity.shared.serverOffline }
        await wait(1)
        snapFooter("fz-15-online-again")
        log("Wieder online (automatischer Neuversuch)", back && lib.status?.hasPrefix("Offline") != true
            && FooterStatus.current()?.text.hasPrefix("Offline") == false,
            "\(lib.totalCount) Objekte, „\(FooterStatus.current()?.text ?? "-")“")
    }

    private static var gridView: NSCollectionView? {
        NSApp.windows.lazy.compactMap { $0.contentView.flatMap(findScroll) }.first?.documentView as? NSCollectionView
    }

    private static func footerHeight() -> CGFloat {
        guard let cv = gridView, cv.numberOfSections > 0 else { return 0 }
        cv.layoutSubtreeIfNeeded()
        return cv.collectionViewLayout?.layoutAttributesForSupplementaryView(
            ofKind: NSCollectionView.elementKindSectionFooter, at: IndexPath(item: 0, section: cv.numberOfSections - 1))?.frame.height ?? 0
    }

    /// Ausschnitt: Fußzeile + die letzte Bildreihe darüber (wie man sie unten im Fenster sieht).
    static func snapFooter(_ name: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.frame.height > 300 }),
              let cv = gridView, cv.numberOfSections > 0,
              let v = cv.supplementaryView(forElementKind: NSCollectionView.elementKindSectionFooter,
                                           at: IndexPath(item: 0, section: cv.numberOfSections - 1)),
              let img = windowImage(CGWindowID(w.windowNumber))
        else { snap(name); return }
        let r = v.convert(v.bounds, to: nil)
        let scale = CGFloat(img.width) / w.frame.width
        let extra: CGFloat = 90
        let crop = CGRect(x: r.minX * scale, y: max(0, (w.frame.height - r.maxY - extra) * scale),
                          width: r.width * scale, height: (r.height + extra) * scale)
        guard let part = img.cropping(to: crop),
              let d = CGImageDestinationCreateWithURL(out.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { snap(name); return }
        CGImageDestinationAddImage(d, part, nil)
        CGImageDestinationFinalize(d)
    }

    /// Scrollt von unten nach oben durchs Raster und misst, wie lange der Hauptthread je Schritt braucht
    /// (> 50 ms = sichtbarer Ruckler). Monate werden dabei nachgeladen wie beim echten Scrollen.
    private static func scrollBenchmark() async {
        guard let sv = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(findScroll) }).first,
              let doc = sv.documentView else { log("Scrollen", false, "kein Raster"); return }
        let h = doc.frame.height, page = sv.contentView.bounds.height
        var y = max(0, h - page), worst = 0.0, total = 0.0, steps = 0
        while y > 0 && steps < 400 {
            y = max(0, y - page * 0.9)
            let t = Date()
            sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
            doc.layoutSubtreeIfNeeded(); sv.displayIfNeeded()
            let ms = Date().timeIntervalSince(t) * 1000
            worst = max(worst, ms); total += ms; steps += 1
            await wait(0.016)
        }
        log("Scrollen", worst < 120, "\(steps) Seiten, Ø \(Int(total / Double(max(1, steps)))) ms, langsamste \(Int(worst)) ms, Höhe \(Int(h)) pt")
        await wait(1.5)
        snap("01b-ganz-oben")
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, h - page))); sv.reflectScrolledClipView(sv.contentView)
    }

    private static func findScroll(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView, s.documentView is NSCollectionView { return s }
        for c in v.subviews { if let s = findScroll(c) { return s } }
        return nil
    }

    private static func writeTestImage(_ url: URL) -> Bool {
        let w = 64, h = 64
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, img, nil)
        return CGImageDestinationFinalize(d)
    }

    /// Album mit zwei Fotos → zweites als Cover („Make Key Photo“) → Server und Seitenleiste prüfen → Album löschen.
    static func keyPhotoTest() async {
        await show(.library)
        let all = lib.sections.compactMap(\.assets).flatMap { $0 }
        guard all.count >= 2 else { log("Albumcover", false, "zu wenige Objekte"); return }
        let two = Array(all.suffix(2))
        lib.selection = Set(two.map(\.id))
        let name = "Mac-Selbsttest Cover \(Int(Date().timeIntervalSince1970))"
        await lib.createAlbum(name)
        guard let al = lib.albums.first(where: { $0.albumName == name }) else { log("Albumcover: Album anlegen", false); return }
        await show(.album(al.id, al.albumName))
        let other = two.first { $0.id != al.albumThumbnailAssetId } ?? two[0]
        lib.selection = [other.id]; lib.focused = other
        let menu = Menus.assetMenu(lib)
        log("Albumcover: Menüpunkt", menu.items.contains { $0.title == "Make Key Photo" && $0.isEnabled })
        await lib.makeKeyPhoto()
        let server = (try? await api.albums())?.first { $0.id == al.id }?.albumThumbnailAssetId
        log("Albumcover: Server", server == other.id, "\(String(describing: server)) = \(other.id)")
        log("Albumcover: Seitenleiste", lib.albums.first { $0.id == al.id }?.albumThumbnailAssetId == other.id)
        await wait(2.5)
        // „My Albums“ liegt unten in der Seitenleiste → für das Bild ans Ende scrollen
        func tables(_ v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables) }
        if let content = NSApp.windows.first(where: \.isVisible)?.contentView,
           let side = tables(content).min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) {
            side.scrollRowToVisible(side.numberOfRows - 1)
        }
        await wait(1.5)
        snap("25-albumcover-seitenleiste")
        await lib.deleteAlbum(al.id)
        log("Albumcover: Testalbum gelöscht", !lib.albums.contains { $0.id == al.id })
    }

    private static func finish() {
        print("SELBSTTEST FERTIG"); fflush(stdout)
        NSApp.terminate(nil)
    }
}
#endif
