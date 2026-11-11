import SwiftUI

/// Sortierung der Alben-Übersicht wie auf dem iPhone (Fotos: „Sortieren nach“).
enum AlbumSort: String, CaseIterable, Identifiable {
    case modified, name, newest, oldest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modified: "Recently Modified"; case .name: "Name"
        case .newest: "Newest First"; case .oldest: "Oldest First"
        }
    }
    func apply(_ l: [AlbumDTO]) -> [AlbumDTO] {
        switch self {
        case .modified: l.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        case .name: l.sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
        case .newest: l.sorted { ($0.endDate ?? "") > ($1.endDate ?? "") }
        case .oldest: l.sorted { ($0.endDate ?? "") < ($1.endDate ?? "") }
        }
    }
}

/// Album-Ordner wie auf dem iPhone: nur auf diesem Mac gespeichert (Immich kennt keine Ordner), je Konto getrennt.
@MainActor @Observable
final class AlbumFolders {
    static let shared = AlbumFolders()
    struct Folder: Codable, Identifiable, Hashable { let id: String; var name: String; var albums: [String] }
    private(set) var folders: [Folder] = []
    private var account = ""

    private var key: String { "mac.albumFolders.\(account)" }
    func use(_ account: String) {
        guard account != self.account else { return }
        self.account = account
        folders = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Folder].self, from: $0) } ?? []
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(folders), forKey: key) }

    func folder(of album: String) -> Folder? { folders.first { $0.albums.contains(album) } }
    @discardableResult func create(_ name: String) -> Folder {
        let f = Folder(id: UUID().uuidString, name: name, albums: [])
        folders.append(f); save(); return f
    }
    func rename(_ id: String, _ name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name; save()
    }
    /// Ordner weg, die Alben darin bleiben (wie Fotos)
    func delete(_ id: String) { folders.removeAll { $0.id == id }; save() }
    /// nil = aus jedem Ordner nehmen (zurück nach „Albums“)
    func move(_ album: String, to folder: String?) {
        for i in folders.indices { folders[i].albums.removeAll { $0 == album } }
        if let folder, let i = folders.firstIndex(where: { $0.id == folder }) { folders[i].albums.append(album) }
        save()
    }
}

/// „Move to Folder“ / „Remove from Folder“ im Albummenü.
struct AlbumFolderMenu: View {
    let album: String
    var body: some View {
        let folders = AlbumFolders.shared
        let current = folders.folder(of: album)
        let others = folders.folders.filter { $0.id != current?.id }
        if !others.isEmpty || current != nil { Divider() }
        if !others.isEmpty {
            Menu("Move to Folder") {
                ForEach(others) { f in Button(f.name) { withAnimation(.snappy) { folders.move(album, to: f.id) } } }
            }
        }
        if let current {
            Button("Remove from “\(current.name)”") { withAnimation(.snappy) { folders.move(album, to: nil) } }
        }
    }
}

/// Alben-Übersicht wie in Fotos: Ordner oben, darunter die Alben; neues Album, neuer Ordner und Sortieren in der Kopfzeile.
struct AlbumsOverview: View {
    @Bindable var lib: Library
    @AppStorage("mac.albumSort") private var sortRaw = AlbumSort.modified.rawValue
    @State private var openFolder: String?
    private var folders: AlbumFolders { AlbumFolders.shared }

    private var sort: AlbumSort { AlbumSort(rawValue: sortRaw) ?? .modified }
    private var folder: AlbumFolders.Folder? { openFolder.flatMap { id in folders.folders.first { $0.id == id } } }
    /// In einem Ordner nur dessen Alben, sonst alle, die in keinem Ordner liegen
    private var shown: [AlbumDTO] {
        if let folder { return sort.apply(lib.albums.filter { folder.albums.contains($0.id) }) }
        let inFolders = Set(folders.folders.flatMap(\.albums))
        return sort.apply(lib.albums.filter { !inFolders.contains($0.id) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                    if folder == nil {
                        ForEach(folders.folders) { f in folderTile(f) }
                    }
                    ForEach(shown) { a in
                        Button { lib.open(.album(a.id, a.albumName)) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Thumb(id: a.albumThumbnailAssetId).frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(a.albumName).lineLimit(1)
                                Text("\(a.assetCount)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { AlbumContextMenu(a: a, lib: lib) }
                    }
                }.padding(20)
            }
        }
        .onAppear { folders.use(AccountStore.shared.currentID ?? "") }
        .onChange(of: AccountStore.shared.currentID) { _, id in openFolder = nil; folders.use(id ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let folder {
                Button { openFolder = nil } label: { Label("Albums", systemImage: "chevron.left") }
                    .help("Back to all albums")
                Text(folder.name).font(.headline)
            }
            Spacer()
            Picker("Sort By", selection: $sortRaw) {
                ForEach(AlbumSort.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu).fixedSize()
            Menu {
                Button("New Album…") { newAlbum() }.disabled(!AccountStore.shared.canWrite)
                if folder == nil { Button("New Folder…") { newFolder() } }
            } label: { Label("New", systemImage: "plus") }
            .fixedSize()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func folderTile(_ f: AlbumFolders.Folder) -> some View {
        let covers = f.albums.compactMap { id in lib.albums.first { $0.id == id }?.albumThumbnailAssetId }.prefix(4)
        return Button { openFolder = f.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                // 2 × 2 Vorschau der ersten Alben wie in Fotos
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        if i < covers.count { Thumb(id: covers[covers.startIndex + i]).frame(height: 84).clipped() }
                        else { Color.secondary.opacity(0.15).frame(height: 84) }
                    }
                }
                .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "folder.fill").padding(8).foregroundStyle(.white).shadow(radius: 2)
                }
                Text(f.name).lineLimit(1)
                Text("\(f.albums.count) \(f.albums.count == 1 ? "album" : "albums")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename Folder…") {
                if let n = Menus.ask("Rename Folder", info: f.name, value: f.name), !n.isEmpty { folders.rename(f.id, n) }
            }
            Button("Delete Folder") { withAnimation(.snappy) { folders.delete(f.id) } }
        }
    }

    private func newAlbum() {
        guard let name = Menus.ask("New Album", info: "Album name", value: "New Album"), !name.isEmpty else { return }
        let target = openFolder
        Task {
            let before = lib.lastAlbumID
            await lib.createAlbum(name, assets: [])
            // im geöffneten Ordner angelegt → gleich dort einsortieren
            if let target, let new = lib.lastAlbumID, new != before { folders.move(new, to: target) }
        }
    }

    private func newFolder() {
        guard let name = Menus.ask("New Folder", info: "Folder name", value: "New Folder"), !name.isEmpty else { return }
        withAnimation(.snappy) { folders.create(name) }
    }
}
