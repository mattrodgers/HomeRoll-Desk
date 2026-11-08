import AppKit
import SwiftUI

/// Fußzeile unten im Raster der Mediathek wie in Fotos auf dem Mac (dort: Stand von iCloud „Updated Just Now“ +
/// Pausieren) – hier der Stand der Sicherung auf dem eigenen Server: Anzahl Fotos/Videos, darunter der Abgleich mit
/// Apples Fotos (PhotosSync) mit dünnem Balken, Pausieren/Fortsetzen, Erneut versuchen, Offline statt Fehlern.
/// Klick zeigt die Details mit Schalter und Weg in die Einstellungen.
struct LibraryFooter: View {
    static let height: CGFloat = 86
    /// Nur unter „Library → All Photos“ (wie Apple), nicht in Alben, Personen, Suche …
    @MainActor static func shows(_ lib: Library) -> Bool { lib.source == .library && !lib.sections.isEmpty }

    @Bindable private var model = FooterModel.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let line = FooterStatus.current(now: ctx.date)
            VStack(spacing: 5) {
                if let count = model.countText { Text(count).font(.system(size: 13, weight: .semibold)) }
                if let line {
                    if let p = line.progress {
                        ProgressView(value: p)
                            .progressViewStyle(.linear).controlSize(.small)
                            .tint(line.dimmed ? Color.secondary : Color.accentColor)
                            .frame(width: 220)
                    }
                    statusRow(line)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(.rect)
            .onTapGesture { model.showDetails = true }
            .popover(isPresented: $model.showDetails, arrowEdge: .top) { FooterDetails() }
            .help("Details about the backup to your server")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel([model.countText, line?.text].compactMap { $0 }.joined(separator: ", "))
        }
        .task(id: FooterModel.refreshKey) { await model.refresh() }
    }

    private func statusRow(_ line: FooterStatus) -> some View {
        HStack(spacing: 4) {
            if let s = line.symbol { Image(systemName: s).imageScale(.small) }
            Text(line.text).lineLimit(1).truncationMode(.middle)
            if let a = line.action {
                Text(verbatim: "·")
                Button(a.title) { a.perform() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).fontWeight(.medium)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

/// Eine Zeile Sicherungsstatus – reine Berechnung aus PhotosSync/Library/Connectivity, damit der Selbsttest sie prüfen kann.
struct FooterStatus: Equatable {
    enum Action: Equatable {
        case pause, resume, retry, turnOn, syncNow
        var title: String {
            switch self {
            case .pause: "Pause"; case .resume: "Resume"; case .retry: "Try Again"
            case .turnOn: "Turn On"; case .syncNow: "Sync Now"
            }
        }
        @MainActor func perform() {
            let sync = PhotosSync.shared
            switch self {
            case .pause: sync.pause()
            case .resume: sync.resume()
            case .retry, .syncNow: Task { await sync.run() }
            case .turnOn: sync.auto = true      // macOS fragt beim ersten Mal nach dem Fotozugriff
            }
        }
    }
    var text: String
    var action: Action?
    var progress: Double?
    var dimmed = false
    var symbol: String?

    /// Oberfläche ist englisch: Zeitangaben auch („5 minutes ago“), Zahlen aber im Format der Region des Macs.
    static let appLocale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))

    /// nil = nur die Anzahl (Konto „View only“ bzw. ohne „Use for imports from this Mac“ – dorthin sichert der Mac nie)
    @MainActor static func current(now: Date = Date()) -> FooterStatus? {
        let sync = PhotosSync.shared
        guard AccountStore.shared.canImport else { return nil }
        // Offline zuerst: dann sind Fehler nur Folge der fehlenden Verbindung, und alles läuft von selbst weiter
        if Library.shared.offline || sync.offline || Connectivity.shared.serverOffline {
            return FooterStatus(text: "Offline – will resume when your server is reachable", symbol: "wifi.slash")
        }
        let fraction = sync.total > 0 ? Double(sync.finished) / Double(sync.total) : nil
        if sync.paused {
            let n = sync.remaining
            return FooterStatus(text: n > 0 ? "Backup paused for \(items(n))" : "Backup paused",
                                action: .resume, progress: n > 0 ? fraction : nil, dimmed: true)
        }
        let busy = sync.running ? sync.remaining : 0
        if busy > 0 { return FooterStatus(text: "\(items(busy)) being backed up", action: .pause, progress: fraction ?? 0) }
        if sync.running { return FooterStatus(text: "Looking for new photos…", action: .pause) }
        if let e = sync.lastError { return FooterStatus(text: "Sync interrupted: \(e)", action: .retry, symbol: "exclamationmark.triangle") }
        if sync.failed > 0 {
            return FooterStatus(text: "\(items(sync.failed)) not backed up yet", action: .retry, symbol: "exclamationmark.triangle")
        }
        if !sync.autoOn { return FooterStatus(text: "Sync with Photos is off", action: .turnOn) }
        if let last = sync.lastRun { return FooterStatus(text: "Backed up to your server · \(relative(last, now: now))") }
        return FooterStatus(text: "Sync with Photos hasn’t run yet", action: .syncNow)
    }

    static func number(_ n: Int) -> String { n.formatted(.number.locale(appLocale)) }
    static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(number(n)) items" }

    /// „just now“, sonst „5 minutes ago“, „yesterday“ …
    static func relative(_ d: Date, now: Date) -> String {
        if now.timeIntervalSince(d) < 60 { return "just now" }
        return d.formatted(Date.RelativeFormatStyle(presentation: .named, locale: appLocale, calendar: .current))
    }
}

/// Anzahl vom Server (gemerkt, damit das Raster beim Neuzeichnen nicht kurz ohne Zahl dasteht).
@MainActor @Observable
final class FooterModel {
    static let shared = FooterModel()
    struct Stats: Equatable { var images: Int; var videos: Int }
    private(set) var stats: Stats?
    var showDetails = false
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var account: String?

    /// ändert sich mit Konto, Mediathek und neuen Uploads → Anzahl neu holen
    static var refreshKey: String {
        "\(AccountStore.shared.currentID ?? "-")|\(Library.shared.totalCount)|\(PhotosSync.shared.uploaded)"
    }

    func refresh() async {
        let acc = AccountStore.shared.currentID
        if acc != account { account = acc; stats = nil; loadedKey = nil; PhotosSync.shared.refreshLastRun() }
        let key = Self.refreshKey
        guard key != loadedKey || stats == nil else { return }
        // beim Start ist das Netz manchmal noch nicht da → wiederholen, bis der Server antwortet
        while !Task.isCancelled {
            if let s = await ImmichClient.shared.statistics() { stats = Stats(images: s.images, videos: s.videos); loadedKey = key; return }
            try? await Task.sleep(for: .seconds(stats == nil ? 3 : 30))
        }
    }

    /// „12,345 Photos, 678 Videos“; ohne Server die Zahl aus der geladenen Mediathek
    var countText: String? {
        guard let s = stats else {
            let n = Library.shared.totalCount
            return n > 0 ? (n == 1 ? "1 Item" : "\(FooterStatus.number(n)) Items") : nil
        }
        let photos = s.images == 1 ? "1 Photo" : "\(FooterStatus.number(s.images)) Photos"
        let videos = s.videos == 1 ? "1 Video" : "\(FooterStatus.number(s.videos)) Videos"
        return switch (s.images, s.videos) {
        case (_, 0): photos
        case (0, _): videos
        default: "\(photos), \(videos)"
        }
    }
}

/// Klick auf die Fußzeile: was gesichert wird, wohin, wann zuletzt, warum nicht – mit Schalter und Weg in die Einstellungen.
struct FooterDetails: View {
    @Bindable private var sync = PhotosSync.shared
    @Bindable private var accounts = AccountStore.shared
    @Bindable private var lib = Library.shared
    private let when = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: FooterStatus.appLocale)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup to Your Server").font(.headline)
            if let a = accounts.current, accounts.canImport {
                Text("Destination: \(a.name) (\(a.email))").font(.caption).foregroundStyle(.secondary)
                Divider()
                photos
            } else {
                readOnly
            }
            if lib.offline || Connectivity.shared.serverOffline {
                Divider()
                Label("Your server can’t be reached right now. The library reloads on its own as soon as it responds.",
                      systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("Settings…") {
                    FooterModel.shared.showDetails = false
                    NotificationCenter.default.post(name: .openBackupSettings, object: nil)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder private var photos: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sync with Photos").font(.subheadline.weight(.semibold))
            Toggle("Automatically upload new photos", isOn: Binding(get: { sync.autoOn }, set: { sync.auto = $0 }))
                .toggleStyle(.switch).controlSize(.small).font(.callout)
            Group {
                if sync.running, sync.total > 0 {
                    Text("\(FooterStatus.number(sync.finished)) of \(FooterStatus.number(sync.total)) processed – \(FooterStatus.number(sync.uploaded)) new, \(FooterStatus.number(sync.skipped)) already there")
                } else if sync.paused, let u = sync.pausedUntil {
                    Text("Paused until \(u.formatted(when))")
                } else if let l = sync.lastRun {
                    Text("Last sync: \(l.formatted(when))" + summary)
                } else {
                    Text("No sync on this Mac yet")
                }
                if sync.offline { Text("Server not reachable – the sync continues on its own as soon as it responds.") }
                if let e = sync.lastError { Text(e).foregroundStyle(.red) }
                else if sync.failed > 0, let f = sync.lastFailure { Text("Last error: \(f)").foregroundStyle(.red) }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if sync.paused { Button("Resume") { sync.resume() } }
                else if sync.running { Button("Pause") { sync.pause() } }
                Button("Sync Now") { Task { await sync.run() } }.disabled(sync.running)
            }.controlSize(.small)
            Text("Pausing stops the sync for 24 hours.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var summary: String {
        guard sync.total > 0 || sync.failed > 0 else { return "" }
        var p = ["\(FooterStatus.number(sync.uploaded)) new"]
        if sync.skipped > 0 { p.append("\(FooterStatus.number(sync.skipped)) already there") }
        if sync.failed > 0 { p.append("\(FooterStatus.number(sync.failed)) failed") }
        return " – " + p.joined(separator: ", ")
    }

    @ViewBuilder private var readOnly: some View {
        let target = accounts.accounts.first { $0.importTarget && !$0.readOnly }
        Text(accounts.current?.readOnly == true
             ? "This account is set to “View only” – this Mac doesn’t back up anything here."
             : "This account doesn’t receive imports from this Mac.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        Text(target.map { "Photos from this Mac (Sync with Photos, imports) go to “\($0.name)”." }
             ?? "No account is set to “Use for imports from this Mac” – change it in Settings → Accounts.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

extension Notification.Name { static let openBackupSettings = Notification.Name("openBackupSettings") }

/// Fußzeile als Zusatzansicht der NSCollectionView (Abschnittsende des letzten Monats) – scrollt mit wie bei Apple.
final class LibraryFooterCell: NSView, NSCollectionViewElement {
    static let ident = NSUserInterfaceItemIdentifier("LibraryFooter")
    override init(frame: NSRect) {
        super.init(frame: frame)
        let host = NSHostingView(rootView: LibraryFooter())
        host.sizingOptions = []          // Größe bestimmt das Raster, nicht SwiftUI
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }
}
