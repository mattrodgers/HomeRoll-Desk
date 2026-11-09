import AppKit

/// Menüpunkt mit Block statt Ziel/Aktion.
final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(_ title: String, symbol: String? = nil, enabled: Bool = true, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}

/// Kontextmenü der Fotos (Texte wie Apples „IPXAssetsContextMenu…“, siehe MAC-PLAN.md §3).
@MainActor
enum Menus {
    static func assetMenu(_ lib: Library) -> NSMenu {
        let m = NSMenu()
        let w = AccountStore.shared.canWrite
        let t = lib.targets
        let n = t.count
        func add(_ title: String, _ symbol: String? = nil, enabled: Bool = true, _ b: @escaping () async -> Void) {
            m.addItem(BlockMenuItem(title, symbol: symbol, enabled: enabled) { Task { await b() } })
        }
        add("Get Info", "info.circle") { InfoWindow.show() }
        if n == 1, let p = lib.indexPath(t[0].id) { add("Open", "arrow.up.left.and.arrow.down.right") { lib.open(p) } }
        m.addItem(.separator())
        if lib.source == .trash {
            add("Recover", "arrow.uturn.backward", enabled: w) { await lib.restore() }
            add("Delete Permanently…", "trash.slash", enabled: w) { if confirmDeleteForever(n) { await lib.deleteForever() } }
            return m
        }
        let fav = t.allSatisfy(\.isFavorite)
        add(fav ? "Unfavorite" : "Favorite", fav ? "heart.slash" : "heart", enabled: w) { await lib.toggleFavorite() }
        add("Rotate Clockwise", "rotate.right", enabled: w) { await lib.rotate(clockwise: true) }
        add("Rotate Counterclockwise", "rotate.left", enabled: w) { await lib.rotate(clockwise: false) }
        m.addItem(.separator())
        let addTo = NSMenuItem(title: "Add to", action: nil, keyEquivalent: "")
        addTo.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
        addTo.submenu = albumMenu(lib)
        addTo.isEnabled = w
        m.addItem(addTo)
        if case .album = lib.source {
            if n == 1 { add("Make Key Photo", "photo.badge.checkmark", enabled: w) { await lib.makeKeyPhoto() } }
            add("Remove from Album", "rectangle.stack.badge.minus", enabled: w) { await lib.removeFromAlbum() }
        }
        m.addItem(.separator())
        add("Export…", "square.and.arrow.up") { Transfer.export(original: false) }
        add("Export Unmodified Original…", "square.and.arrow.up.on.square") { Transfer.export(original: true) }
        add(n == 1 ? "Share Link" : "Share Link for \(n) Items", "link") { await shareLink(lib) }
        add("Print…", "printer") { await Printing.printSelection() }
        m.addItem(.separator())
        add(lib.source == .hidden ? "Unhide" : "Hide", lib.source == .hidden ? "eye" : "eye.slash", enabled: w) { await lib.toggleHidden() }
        add(n == 1 ? "Delete" : "Delete \(n) Items", "trash", enabled: w) { await lib.trash() }
        if !w {
            m.addItem(.separator())
            let i = NSMenuItem(title: "Account “\(AccountStore.shared.current?.name ?? "")” is set to view only", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        return m
    }

    static func albumMenu(_ lib: Library) -> NSMenu {
        let m = NSMenu()
        m.addItem(BlockMenuItem("New Album…", symbol: "plus") { newAlbum(lib) })
        if let last = lib.lastAlbumID, let a = lib.albums.first(where: { $0.id == last }) {
            m.addItem(BlockMenuItem("Add to Last Album: \(a.albumName)", symbol: "clock") { Task { await lib.addToAlbum(a.id) } })
        }
        m.addItem(.separator())
        for a in lib.albums {
            m.addItem(BlockMenuItem(a.albumName, symbol: "rectangle.stack") { Task { await lib.addToAlbum(a.id) } })
        }
        return m
    }

    static func newAlbum(_ lib: Library) {
        guard let name = ask("New Album", info: lib.targets.isEmpty ? "Album name" : "New album with \(itemsText(lib.targets.count))",
                             value: "New Album") else { return }
        Task { await lib.createAlbum(name) }
    }

    static func ask(_ title: String, info: String, value: String) -> String? {
        let a = NSAlert()
        a.messageText = title; a.informativeText = info
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = value
        a.accessoryView = f
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let s = f.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func confirmDeleteForever(_ n: Int) -> Bool {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = n == 1 ? "Permanently delete this item?" : "Permanently delete \(n) items?"
        a.informativeText = "This action can’t be undone."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        return a.runModal() == .alertFirstButtonReturn
    }

    static func shareLink(_ lib: Library) async {
        let ids = lib.targets.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            guard let url = try await ImmichClient.shared.shareLink(ids) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            lib.status = "Link copied (valid for 30 days)"
        } catch { lib.error = error.localizedDescription }
    }
}
