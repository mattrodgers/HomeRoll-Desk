import AppKit
import SwiftUI

/// Ordneransicht (GitHub HomeRoll-Desk #10, wie HomeRoll #42/#46): Fotos so, wie sie auf dem Server in Ordnern liegen –
/// vor allem für externe Bibliotheken. Ordner mit Unterordnern als 2 × 2-Mosaik, der letzte Ordner einer Kette wie ein
/// Album. Immichs interne Ablage hochgeladener Fotos (upload/<Benutzer-ID>/ab/cd) ist kein echter Ordner und bleibt weg.
@MainActor @Observable final class FolderStore {
    static let shared = FolderStore()
    private(set) var paths: [String] = []
    private(set) var root = ""
    private(set) var loaded = false
    private var covers: [String: String] = [:]
    private var contents: [String: [Asset]] = [:]
    private var latestCache: [String: Date] = [:]

    func load() async {
        guard let all = try? await ImmichClient.shared.folderPaths() else { return }
        #if DEBUG
        let showAll = ProcessInfo.processInfo.environment["FOTOS_FOLDERS_ALL"] != nil
        #else
        let showAll = false
        #endif
        paths = (showAll ? all : all.filter { !Self.isInternal($0) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        root = Self.commonDirectory(paths)
        covers = [:]; contents = [:]; latestCache = [:]
        loaded = true
    }
    func reset() { paths = []; root = ""; loaded = false; covers = [:]; contents = [:]; latestCache = [:] }

    nonisolated static func isInternal(_ p: String) -> Bool {
        let c = p.split(separator: "/")
        if let i = c.lastIndex(of: "upload"), i + 1 < c.count, c[i + 1].count == 36 { return true }
        return c.contains("encoded-video") || c.contains("thumbs")
    }

    nonisolated static func commonDirectory(_ paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        var common = first.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if paths.count == 1 { common.removeLast() }
        for p in paths.dropFirst() {
            let c = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var n = 0
            while n < common.count, n < c.count, common[n] == c[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        let j = common.joined(separator: "/")
        if paths.count > 1, paths.contains(j), !common.isEmpty { common.removeLast() }
        return common.joined(separator: "/")
    }

    /// Alle Ordner unterhalb der obersten Ebene, auch reine Zwischenordner – für die Suche (HomeRoll-Desk #12)
    var allDirectories: [String] {
        var out = Set<String>()
        let pre = root.isEmpty ? "" : root + "/"
        for p in paths where p.hasPrefix(pre) {
            var d = p
            while d.count > pre.count, d.hasPrefix(pre) {
                out.insert(d)
                guard let i = d.lastIndex(of: "/") else { break }
                d = String(d[..<i])
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated static func name(_ dir: String) -> String { dir.split(separator: "/").last.map(String.init) ?? dir }

    func children(of dir: String) -> [String] {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        var seen = Set<String>(), out: [String] = []
        for p in paths where p.hasPrefix(prefix) {
            guard let name = p.dropFirst(prefix.count).split(separator: "/").first else { continue }
            let child = prefix + name
            if seen.insert(child).inserted { out.append(child) }
        }
        return out
    }
    func hasPhotos(_ dir: String) -> Bool { paths.contains(dir) }

    func assets(_ dir: String) async -> [Asset] {
        if let c = contents[dir] { return c }
        let a = ((try? await ImmichClient.shared.folderAssets(dir)) ?? []).map(\.asset).sorted { $0.date < $1.date }
        contents[dir] = a
        return a
    }
    func cover(_ dir: String) async -> String? {
        if let c = covers[dir] { return c }
        let source = hasPhotos(dir) ? dir : paths.first { $0.hasPrefix(dir + "/") }
        guard let source, let id = await assets(source).last?.id else { return nil }
        covers[dir] = id
        return id
    }
    func mosaic(_ dir: String) async -> [String] {
        var out: [String] = []
        for c in children(of: dir).prefix(4) { if let id = await cover(c) { out.append(id) } }
        if out.count < 4, hasPhotos(dir) {
            for a in await assets(dir).reversed() where !out.contains(a.id) { out.append(a.id); if out.count == 4 { break } }
        }
        return out
    }
    /// „3 folders · 120 items“ – nur eine Ebene tief
    func summary(_ dir: String) async -> String {
        let folders = children(of: dir).count
        let photos = hasPhotos(dir) ? await assets(dir).count : 0
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if photos > 0 || folders == 0 { parts.append(photos == 1 ? "1 item" : "\(photos) items") }
        return parts.joined(separator: " · ")
    }
    func latest(_ dir: String) async -> Date {
        if let d = latestCache[dir] { return d }
        var best = Date.distantPast
        if hasPhotos(dir), let d = await assets(dir).last?.date { best = d }
        for c in children(of: dir) { best = max(best, await latest(c)) }
        latestCache[dir] = best
        return best
    }
}

enum FolderSort: String, CaseIterable, Identifiable {
    case nameAsc, nameDesc, newest, oldest
    var id: String { rawValue }
    var title: String {
        switch self { case .nameAsc: "Name (A–Z)"; case .nameDesc: "Name (Z–A)"; case .newest: "Newest First"; case .oldest: "Oldest First" }
    }
}

/// Ein Ordner als Übersicht (Quelle `.folderList`): Unterordner als Kacheln, sortierbar. Hinein geht es über
/// `lib.open`, so führt „Zurück“ (⌘[) Ebene für Ebene wieder heraus.
struct FoldersOverview: View {
    @Bindable var lib: Library
    let path: String
    @AppStorage("mac.folderSort") private var sortRaw = FolderSort.nameAsc.rawValue
    @State private var order: [String] = []
    private var store: FolderStore { .shared }
    private var dir: String { path.isEmpty ? store.root : path }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path.isEmpty ? "Folders" : FolderStore.name(path)).font(.headline)
                Spacer()
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(FolderSort.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu).fixedSize()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 22) {
                    if !path.isEmpty, store.hasPhotos(dir) {
                        Button { lib.open(.folder(dir)) } label: { FolderTileMac(path: dir, ownPhotos: true) }.buttonStyle(.plain)
                    }
                    ForEach(order.isEmpty ? store.children(of: dir) : order, id: \.self) { f in
                        Button {
                            lib.open(store.children(of: f).isEmpty ? .folder(f) : .folderList(f))
                        } label: { FolderTileMac(path: f) }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .overlay {
                if !store.loaded { ProgressView() }
                else if store.paths.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder",
                                           description: Text("Folders show up when your server has an external library with its own folder structure."))
                }
            }
        }
        .task { if !store.loaded { await store.load() } }
        .task(id: "\(sortRaw)|\(dir)|\(store.paths.count)") { order = await sorted(store.children(of: dir)) }
    }

    private func sorted(_ subs: [String]) async -> [String] {
        switch FolderSort(rawValue: sortRaw) ?? .nameAsc {
        case .nameAsc: return subs.sorted { FolderStore.name($0).localizedStandardCompare(FolderStore.name($1)) == .orderedAscending }
        case .nameDesc: return subs.sorted { FolderStore.name($0).localizedStandardCompare(FolderStore.name($1)) == .orderedDescending }
        case .newest, .oldest:
            var d: [String: Date] = [:]
            for s in subs { d[s] = await store.latest(s) }
            let newest = sortRaw == FolderSort.newest.rawValue
            return subs.sorted { newest ? d[$0]! > d[$1]! : d[$0]! < d[$1]! }
        }
    }
}

/// Kachel: Ordner mit Unterordnern als 2 × 2-Mosaik mit Ordnersymbol, der letzte Ordner einer Kette wie ein Album
private struct FolderTileMac: View {
    let path: String
    var ownPhotos = false
    @State private var covers: [String] = []
    @State private var summary = ""
    private var store: FolderStore { .shared }

    var body: some View {
        let isFolder = !ownPhotos && !store.children(of: path).isEmpty
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if isFolder {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                        ForEach(0..<4, id: \.self) { i in
                            if i < covers.count { Thumb(id: covers[i]).frame(height: 84).clipped() }
                            else { Color.secondary.opacity(0.15).frame(height: 84) }
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        Image(systemName: "folder.fill").padding(8).foregroundStyle(.white).shadow(radius: 2)
                    }
                } else {
                    Thumb(id: covers.first)
                }
            }
            .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(ownPhotos ? "Photos in This Folder" : FolderStore.name(path)).lineLimit(1)
            Text(summary.isEmpty ? " " : summary).font(.caption).foregroundStyle(.secondary)
        }
        .task(id: path) {
            if isFolder { covers = await store.mosaic(path) }
            else if ownPhotos { covers = [await store.assets(path).last?.id].compactMap { $0 } }
            else { covers = [await store.cover(path)].compactMap { $0 } }
            if ownPhotos { let n = await store.assets(path).count; summary = n == 1 ? "1 item" : "\(n) items" }
            else { summary = await store.summary(path) }
        }
    }
}
