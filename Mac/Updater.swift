import AppKit
import CryptoKit
import Foundation

/// Update aus der App heraus: fragt beim Start GitHub nach der neuesten Version, lädt das Zip selbst
/// (dadurch kein Quarantäne-Vermerk → kein „Trotzdem öffnen“ mehr), prüft es und tauscht die App aus.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    nonisolated private static let repo = "silentprovider423/HomeRoll-Desk"
    private static let page = URL(string: "https://github.com/\(repo)/releases/latest")!

    var auto: Bool = UserDefaults.standard.object(forKey: "mac.update.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "mac.update.auto") }
    }
    private(set) var busy = false
    private var skipped: String? {
        get { UserDefaults.standard.string(forKey: "mac.update.skipped") }
        set { UserDefaults.standard.set(newValue, forKey: "mac.update.skipped") }
    }

    struct Release { let version: String; let notes: String; let zip: URL; let sha256: String? }

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// „1.0.10“ > „1.0.9“ – Zahl für Zahl, nicht als Text
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func checkAtLaunch() { if auto { Task { await check(manual: false) } } }

    func check(manual: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        guard let r = await Self.latest() else {
            if manual { Self.info("Couldn’t check for updates", "GitHub could not be reached. Try again later.") }
            return
        }
        guard Self.isNewer(r.version, than: Self.current) else {
            if manual { Self.info("You’re up to date", "HomeRoll Desktop \(Self.current) is the newest version.") }
            return
        }
        if !manual && skipped == r.version { return }
        let a = NSAlert()
        a.messageText = "HomeRoll Desktop \(r.version) is available"
        a.informativeText = "You have \(Self.current).\n\n" + String(r.notes.prefix(600))
        a.addButton(withTitle: "Install Update")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Skip This Version")
        switch a.runModal() {
        case .alertFirstButtonReturn: await install(r)
        case .alertThirdButtonReturn: skipped = r.version
        default: break
        }
    }

    private static func info(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    nonisolated static func latest() async -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (d, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let assets = j["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let s = asset["browser_download_url"] as? String, let zip = URL(string: s),
              s.hasPrefix("https://github.com/\(repo)/releases/download/") else { return nil }
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        // Installationshinweis und Prüfsumme aus den Notizen gehören nicht in den Dialog
        let notes = (j["body"] as? String ?? "").components(separatedBy: "\n")
            .filter { !$0.hasPrefix("**Install:**") && !$0.hasPrefix("SHA-256:") }
            .joined(separator: "\n").replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, notes: notes, zip: zip, sha256: digest)
    }

    enum Failure: Error { case download, checksum, unpack, wrongApp, signature, notWritable }

    /// Lädt, prüft und entpackt das Update; liefert die neue App in einem Arbeitsordner.
    nonisolated static func fetch(_ r: Release) async throws -> (app: URL, work: URL) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("homeroll-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            guard let (tmp, resp) = try? await URLSession.shared.download(from: r.zip),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            let zip = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: tmp, to: zip)
            if let want = r.sha256 {
                let got = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard got == want.lowercased() else { throw Failure.checksum }
            }
            let out = work.appendingPathComponent("new")
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]) else { throw Failure.unpack }
            guard let app = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
                  let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let id = info["CFBundleIdentifier"] as? String, (Bundle.main.bundleIdentifier ?? "").hasPrefix(id),
                  info["CFBundleShortVersionString"] as? String == r.version else { throw Failure.wrongApp }
            guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { throw Failure.signature }
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            return (app, work)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func install(_ r: Release) async {
        let target = Bundle.main.bundleURL
        // Aus dem Downloads-Ordner gestartet läuft die App von einem schreibgeschützten Zufallspfad – dort lässt sie sich nicht ersetzen
        guard !target.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            Self.info("Move the app to Applications first",
                      "HomeRoll Desktop can only update itself from the Applications folder. The download page opens now.")
            NSWorkspace.shared.open(Self.page)
            return
        }
        do {
            let (app, work) = try await Self.fetch(r)
            try Self.swapAndRelaunch(new: app, work: work, target: target)
            NSApp.terminate(nil)
        } catch {
            Self.info("Update failed", "The update could not be installed (\(error)). The download page opens now.")
            NSWorkspace.shared.open(Self.page)
        }
    }

    /// Ein kleines Skript wartet, bis die App beendet ist, tauscht sie aus und startet die neue.
    /// Schlägt das Einsetzen fehl, kommt die alte App zurück.
    nonisolated static func swapAndRelaunch(new: URL, work: URL, target: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$3" "$4/old.app"; then
          if mv "$2" "$3"; then rm -rf "$4/old.app"; else mv "$4/old.app" "$3"; fi
        fi
        open "$3"
        rm -rf "$4"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), new.path, target.path, work.path]
        try p.run()
    }
}
