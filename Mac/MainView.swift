import AppKit
import SwiftUI

/// Hauptfenster: Seitenleiste wie Fotos (macOS 15) + Raster/Übersicht, Einzelansicht im selben Fenster.
struct MainView: View {
    @Bindable var lib = Library.shared
    @Bindable var accounts = AccountStore.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if accounts.current == nil {
            LoginView()
        } else {
            NavigationSplitView {
                Sidebar(lib: lib)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            } detail: {
                detail
            }
            .navigationTitle(lib.source.title)
            .navigationSubtitle(subtitle)
            .searchable(text: $query, placement: .toolbar, prompt: "Search")
            .searchFocused($searchFocused)
            .onSubmit(of: .search) {
                let q = query.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { lib.select(.search(q)) }
            }
            .toolbar { if lib.editing == nil { toolbar } }
            .task(id: accounts.currentID) { lib.reset(); await lib.load() }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
            // Fußzeile der Mediathek → Einstellungen (Abgleich mit Fotos)
            .onReceive(NotificationCenter.default.publisher(for: .openBackupSettings)) { _ in openSettings() }
            .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
                // Server lehnt die Anmeldung ab (z. B. Passwort im Browser geändert) → neu anmelden, Konto bleibt
                guard lib.error == nil else { return }
                lib.error = "The session for “\(accounts.current?.name ?? "")” has expired. Please sign in again in the window that opens."
                LoginWindow.show()
            }
            .alert("Error", isPresented: Binding(get: { lib.error != nil }, set: { if !$0 { lib.error = nil } })) {
                Button("OK") { lib.error = nil }
            } message: { Text(lib.error ?? "") }
        }
    }

    private var subtitle: String {
        if lib.source.isOverview { return "" }
        let n = lib.totalCount
        let sel = lib.selection.count
        return sel > 0 ? "\(sel) of \(n) selected" : itemsText(n)
    }

    @ViewBuilder private var detail: some View {
        ZStack {
            switch lib.source {
            case .people: PeopleOverview(lib: lib)
            case .albums: AlbumsOverview(lib: lib)
            case .memories: MemoriesOverview(lib: lib)
            case .map: MapOverview(lib: lib)
            case .duplicates: DuplicatesOverview(lib: lib)
            case .library where lib.granularity != .all:
                PeriodGrid(lib: lib, years: lib.granularity == .years)
            default:
                PhotoGrid(lib: lib, edge: Library.zoomSizes[lib.zoom])
                if lib.loading && lib.sections.isEmpty { ProgressView() }
                else if !lib.loading && lib.sections.isEmpty {
                    ContentUnavailableView(lib.source == .trash ? "No Recently Deleted Items" : "No Photos",
                                           systemImage: "photo.on.rectangle",
                                           description: Text(AccountStore.shared.canImport ? "Drag photos or folders here, or press ⇧⌘I to import." : ""))
                }
            }
            if let v = lib.viewer { ViewerView(lib: lib, path: v).transition(.opacity) }
            if let e = lib.editing { EditorView(lib: lib, asset: e).id(e.id).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: lib.viewer)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if !lib.source.isOverview && lib.viewer == nil && (lib.source != .library || lib.granularity == .all) {
                Slider(value: Binding(get: { Double(lib.zoom) }, set: { lib.zoom = Int($0.rounded()) }),
                       in: 0...Double(Library.zoomSizes.count - 1), step: 1)
                    .frame(width: 110).help("Zoom (⌘+ / ⌘−)")
            }
        }
        ToolbarItem(placement: .principal) {
            if lib.source == .library && lib.viewer == nil {
                Picker("View", selection: $lib.granularity) {
                    ForEach(Library.Granularity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Years · Months · All Photos")
            }
        }
        ToolbarItem(placement: .status) {
            if let s = lib.status { Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { InfoWindow.show() } label: { Label("Info", systemImage: "info.circle") }.help("Info (⌘I)")
            Button { Task { await lib.toggleFavorite() } } label: { Label("Favorite", systemImage: "heart") }
                .disabled(!accounts.canWrite || lib.targets.isEmpty).help("Favorite (.)")
            Button { Transfer.export(original: false) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(lib.targets.isEmpty).help("Export (⇧⌘E)")
            if accounts.canImport {
                Button { Transfer.chooseAndImport() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import (⇧⌘I)")
            }
            AccountMenu()
        }
    }
}

extension Notification.Name { static let focusSearch = Notification.Name("focusSearch") }

/// Konto wechseln wie in der iPhone-App; Mac- und iPhone-Konto bleiben getrennte Mediatheken.
struct AccountMenu: View {
    @Bindable var accounts = AccountStore.shared
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Menu {
            ForEach(accounts.accounts) { a in
                Button { accounts.switchTo(a.id) } label: {
                    if a.id == accounts.currentID { Label(title(a), systemImage: "checkmark") } else { Text(title(a)) }
                }
            }
            Divider()
            Button("Add Another Account…") { LoginWindow.show() }
            Button("Manage Accounts…") { openSettings() }
        } label: {
            Label(accounts.current?.name ?? "Account", systemImage: accounts.current?.readOnly == true ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
        }
        .help(accounts.current.map { "\($0.name) – \($0.email)\($0.readOnly ? " (view only)" : "")" } ?? "")
    }
    private func title(_ a: Account) -> String { a.name + (a.readOnly ? " (view only)" : "") + (a.importTarget ? " – imports from this Mac" : "") }
}

/// Seitenleiste mit Apples Bereichen (Lemonade: Fotos, Sammlungen, Medienarten, Sonstige, Meine Alben).
struct Sidebar: View {
    @Bindable var lib: Library
    var body: some View {
        List(selection: Binding(get: { lib.source }, set: { if let s = $0 { lib.select(s) } })) {
            Section("Photos") {
                item(.library, "photo.on.rectangle")
                item(.recentlySaved, "square.and.arrow.down")
                item(.favorites, "heart")
            }
            Section("Collections") {
                item(.memories, "clock.arrow.circlepath")
                item(.people, "person.2")
                item(.map, "map")
                item(.albums, "rectangle.stack")
            }
            Section("Media Types") {
                item(.videos, "video")
                item(.livePhotos, "livephoto")
                ForEach(Source.mediaTags, id: \.self) { t in item(.category(t), Source.icon(tag: t)) }
            }
            Section("Utilities") {
                ForEach(Source.otherTags, id: \.self) { t in item(.category(t), Source.icon(tag: t)) }
                item(.duplicates, "square.on.square")
                item(.hidden, "eye.slash")
                item(.trash, "trash")
            }
            Section("My Albums") {
                ForEach(lib.albums) { a in
                    Label(a.albumName, systemImage: "rectangle.stack").tag(Source.album(a.id, a.albumName))
                        .contextMenu { albumContext(a) }
                }
                ForEach(SmartAlbums.shared.albums) { a in
                    Label(a.name, systemImage: "gearshape").tag(Source.smart(a.id, a.name))
                        .contextMenu {
                            Button("Edit Smart Album…") { SmartAlbumWindow.show(a) }
                            Button("Delete") { SmartAlbums.shared.delete(a.id); if case .smart = lib.source { lib.select(.library) } }
                        }
                }
                Button { SmartAlbumWindow.show() } label: { Label("New Smart Album", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button { Menus.newAlbum(lib) } label: { Label("New Album", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(!AccountStore.shared.canWrite)
            }
        }
        .listStyle(.sidebar)
    }

    private func item(_ s: Source, _ icon: String) -> some View { Label(s.title, systemImage: icon).tag(s) }

    @ViewBuilder private func albumContext(_ a: AlbumDTO) -> some View {
        let w = AccountStore.shared.canWrite
        Button("Add Selected Items") { Task { await lib.addToAlbum(a.id) } }.disabled(!w || lib.targets.isEmpty)
        Button("Rename…") {
            if let n = Menus.ask("Rename Album", info: a.albumName, value: a.albumName) { Task { await lib.renameAlbum(a.id, n) } }
        }.disabled(!w)
        Divider()
        Button("Delete Album…") {
            let al = NSAlert()
            al.messageText = "Delete album “\(a.albumName)”?"
            al.informativeText = "The photos remain in your library."
            al.addButton(withTitle: "Delete"); al.addButton(withTitle: "Cancel")
            if al.runModal() == .alertFirstButtonReturn { Task { await lib.deleteAlbum(a.id) } }
        }.disabled(!w)
    }
}

// MARK: Übersichten

struct AlbumsOverview: View {
    @Bindable var lib: Library
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                ForEach(lib.albums) { a in
                    Button { lib.select(.album(a.id, a.albumName)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Thumb(id: a.albumThumbnailAssetId).frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(a.albumName).lineLimit(1)
                            Text("\(a.assetCount)").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(20)
        }
    }
}

struct PeopleOverview: View {
    @Bindable var lib: Library
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 18)], spacing: 22) {
                ForEach(lib.people) { p in
                    Button { lib.select(.person(p.id, p.name)) } label: {
                        VStack(spacing: 6) {
                            PersonThumb(id: p.id).frame(width: 110, height: 110).clipShape(Circle())
                                .overlay(alignment: .bottomTrailing) {
                                    if p.isFavorite == true { Image(systemName: "heart.fill").foregroundStyle(.white).shadow(radius: 2) }
                                }
                            Text(p.name.isEmpty ? "Unnamed" : p.name).lineLimit(1).foregroundStyle(p.name.isEmpty ? .secondary : .primary)
                        }
                    }.buttonStyle(.plain)
                    .contextMenu { PeopleActions.menu(p, lib: lib) }
                }
            }.padding(20)
        }
    }
}

struct Thumb: View {
    let id: String?
    @State private var img: CGImage?
    var body: some View {
        Rectangle().fill(Color(white: 0.2))
            .overlay { if let img { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill) } }
            .clipped()
            .task(id: id) { if let id { img = await ImageCache.shared.load(id, .thumbnail) } }
    }
}

struct PersonThumb: View {
    let id: String
    @State private var img: CGImage?
    var body: some View {
        Circle().fill(Color(white: 0.2))
            .overlay { if let img { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill) } }
            .clipped()
            .task(id: id) {
                guard let u = ImmichClient.shared.personThumbURL(id), let d = try? await ImmichClient.shared.data(u) else { return }
                img = ImageCache.decode(d)
            }
    }
}
