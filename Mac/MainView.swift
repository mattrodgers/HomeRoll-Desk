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
            .navigationTitle(lib.viewer != nil ? "" : lib.source.title)
            .navigationSubtitle(lib.viewer != nil ? "" : subtitle)
            .searchableIf(lib.viewer == nil && lib.editing == nil, text: $query, focused: $searchFocused, prompt: "Search")
            .onSubmit(of: .search) {
                let q = query.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { lib.select(.search(q)) }
            }
            .toolbar { if lib.editing == nil { toolbar } }
            .task(id: accounts.currentID) { lib.reset(); await lib.load() }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
                if lib.viewer == nil { searchFocused = true }
            }
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
        ToolbarItemGroup(placement: .navigation) {
            if lib.viewer != nil {
                Button {
                    lib.closeViewer()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back (Space)")

                ViewerZoomControl(lib: lib)
            } else {
                if lib.canGoBack {
                    Button { lib.goBack() } label: { Label("Back", systemImage: "chevron.left") }.help("Back (⌘[)")
                }
                if !lib.source.isOverview && (lib.source != .library || lib.granularity == .all) {
                    Slider(value: Binding(get: { Double(lib.zoom) }, set: { lib.zoom = Int($0.rounded()) }),
                           in: 0...Double(Library.zoomSizes.count - 1), step: 1)
                        .frame(width: 110).help("Zoom (⌘+ / ⌘−)")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            if lib.viewer != nil {
                VStack(spacing: 1) {
                    Text(lib.viewerTitle)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    if !lib.viewerSubtitle.isEmpty {
                        Text(lib.viewerSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else if lib.source == .library {
                Picker("View", selection: $lib.granularity) {
                    ForEach(Library.Granularity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Years · Months · All Photos")
            }
        }
        ToolbarItem(placement: .status) {
            if lib.viewer == nil, let s = lib.status {
                Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let a = lib.viewerAsset {
                ControlGroup {
                    Button { InfoWindow.show() } label: { Image(systemName: "info.circle") }.help("Info (⌘I)")
                    ViewerShareButton(asset: a)
                    Button { Task { await lib.toggleFavorite() } } label: {
                        Image(systemName: a.isFavorite ? "heart.fill" : "heart")
                    }.disabled(!accounts.canWrite).help("Favorite (.)")
                    Button { Task { await lib.rotate(clockwise: false) } } label: {
                        Image(systemName: "rotate.left")
                    }.disabled(!accounts.canWrite || a.isVideo).help("Rotate Counterclockwise (⌘R)")
                    Button { Task { await lib.autoEnhance() } } label: {
                        Image(systemName: "wand.and.stars")
                    }.disabled(!accounts.canWrite || a.isVideo).help("Auto Enhance (⌘E)")
                }
                Button("Edit") { lib.edit() }
                    .buttonStyle(.bordered)
                    .disabled(!accounts.canWrite || !a.isImage)
                    .help("Edit (↩)")
            } else {
                Button { InfoWindow.show() } label: { Label("Info", systemImage: "info.circle") }.help("Info (⌘I)")
                Button { Task { await lib.toggleFavorite() } } label: { Label("Favorite", systemImage: "heart") }
                    .disabled(!accounts.canWrite || lib.targets.isEmpty).help("Favorite (.)")
                ShareButton(lib: lib)
                if accounts.canImport {
                    Button { Transfer.chooseAndImport() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                        .help("Import (⇧⌘I)")
                }
                AccountMenu()
            }
        }
    }
}

extension View {
    @ViewBuilder
    func searchableIf(_ condition: Bool, text: Binding<String>, focused: FocusState<Bool>.Binding, prompt: String = "Search") -> some View {
        if condition {
            self.searchable(text: text, placement: .toolbar, prompt: prompt)
                .searchFocused(focused)
        } else {
            self
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
                    // kleines Albumcover wie in Apples Seitenleiste (GitHub-Issue HomeRoll-Desk #2)
                    Label {
                        Text(a.albumName)
                    } icon: {
                        if let cover = a.albumThumbnailAssetId {
                            Thumb(id: cover).frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 3))
                        } else {
                            Image(systemName: "rectangle.stack")
                        }
                    }
                    .tag(Source.album(a.id, a.albumName))
                    .contextMenu { AlbumContextMenu(a: a, lib: lib) }
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
}

// MARK: Übersichten

/// Kontextmenü eines Albums – in der Seitenleiste und in der Alben-Übersicht gleich.
struct AlbumContextMenu: View {
    let a: AlbumDTO
    @Bindable var lib: Library
    var body: some View {
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
        AlbumFolderMenu(album: a.id)
    }
}

struct PeopleOverview: View {
    @Bindable var lib: Library
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 18)], spacing: 22) {
                ForEach(lib.people) { p in
                    Button { lib.open(.person(p.id, p.name)) } label: {
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
