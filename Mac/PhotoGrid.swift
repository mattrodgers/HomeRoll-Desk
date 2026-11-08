import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Foto-Raster wie in Fotos auf dem Mac: NSCollectionView mit Monatsüberschriften, Auswahl per Klick/⇧/⌘/Rahmen,
/// Doppelklick/Leertaste öffnet, Kontextmenü, Ziehen in den Finder und Ablegen aus dem Finder (Import).
/// Monate der Mediathek lädt erst das Hinscrollen (Library.ensureLoaded) – 80 000 Objekte bleiben flüssig.
struct PhotoGrid: NSViewRepresentable {
    let lib: Library
    let edge: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(lib) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.headerReferenceSize = NSSize(width: 100, height: 40)
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        let cv = GridCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.dataSource = c
        cv.delegate = c
        cv.prefetchDataSource = c
        cv.register(ThumbItem.self, forItemWithIdentifier: ThumbItem.ident)
        cv.register(MonthHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                    withIdentifier: MonthHeader.ident)
        cv.register(LibraryFooterCell.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
                    withIdentifier: LibraryFooterCell.ident)
        cv.registerForDraggedTypes([.fileURL])
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)
        cv.coordinator = c
        c.cv = cv
        c.edge = edge
        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        c.attach()
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.edge != edge {
            c.edge = edge
            c.cv?.collectionViewLayout?.invalidateLayout()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSCollectionViewPrefetching {
        let lib: Library
        weak var cv: GridCollectionView?
        var edge: CGFloat = 150
        private var promises: [AssetPromise] = []

        init(_ l: Library) { lib = l }

        func attach() {
            lib.onReloadAll = { [weak self] in self?.reloadAll() }
            lib.onReloadSection = { [weak self] s in
                guard let cv = self?.cv, s < cv.numberOfSections else { self?.reloadAll(); return }
                cv.reloadSections(IndexSet(integer: s))
                self?.restoreSelection()
            }
            lib.onReloadItems = { [weak self] p in
                guard let cv = self?.cv else { return }
                let valid = Set(p.filter { $0.section < cv.numberOfSections && $0.item < cv.numberOfItems(inSection: $0.section) })
                for ip in valid { (cv.item(at: ip) as? ThumbItem)?.show(self?.lib.asset(at: ip), edge: self?.edge ?? 150, reload: true) }
            }
            lib.onScrollToSection = { [weak self] s in
                guard let cv = self?.cv, s < cv.numberOfSections else { return }
                cv.layoutSubtreeIfNeeded()
                if let a = cv.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                      at: IndexPath(item: 0, section: s)) {
                    cv.scroll(NSPoint(x: 0, y: a.frame.minY))
                }
            }
            lib.onScrollToEnd = { [weak self] in
                // wie Fotos: Neuestes unten, beim Öffnen ganz unten
                guard let cv = self?.cv else { return }
                DispatchQueue.main.async {
                    cv.layoutSubtreeIfNeeded()
                    cv.scroll(NSPoint(x: 0, y: max(0, cv.frame.height - (cv.enclosingScrollView?.contentSize.height ?? 0))))
                }
            }
        }

        func reloadAll() {
            cv?.reloadData()
            restoreSelection()
        }

        private func restoreSelection() {
            guard let cv else { return }
            let paths = Set(lib.selection.compactMap(lib.indexPath).filter { $0.section < cv.numberOfSections })
            if cv.selectionIndexPaths != paths { cv.selectionIndexPaths = paths }
        }

        // MARK: Daten

        func numberOfSections(in cv: NSCollectionView) -> Int { lib.sections.count }
        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection s: Int) -> Int { lib.sections[s].count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt p: IndexPath) -> NSCollectionViewItem {
            let item = cv.makeItem(withIdentifier: ThumbItem.ident, for: p) as! ThumbItem
            lib.ensureLoaded(p.section)
            item.show(lib.asset(at: p), edge: edge)
            return item
        }

        func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                            at p: IndexPath) -> NSView {
            if kind == NSCollectionView.elementKindSectionFooter {
                return cv.makeSupplementaryView(ofKind: kind, withIdentifier: LibraryFooterCell.ident, for: p)
            }
            let h = cv.makeSupplementaryView(ofKind: kind, withIdentifier: MonthHeader.ident, for: p) as! MonthHeader
            h.label.stringValue = lib.sections.indices.contains(p.section) ? lib.sections[p.section].title : ""
            return h
        }

        func collectionView(_ cv: NSCollectionView, prefetchItemsAt paths: [IndexPath]) {
            for s in Set(paths.map(\.section)) { lib.ensureLoaded(s) }
            let size: ImmichClient.Size = edge > 220 ? .preview : .thumbnail
            for p in paths.prefix(60) { if let a = lib.asset(at: p) { Task { _ = await ImageCache.shared.load(a.id, size) } } }
        }

        // MARK: Größe – Spalten füllen die Breite (wie Fotos), Kantenlänge ≈ Zoomstufe

        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt p: IndexPath) -> NSSize {
            let w = max(1, cv.enclosingScrollView?.contentSize.width ?? cv.bounds.width)
            let cols = max(1, Int((w + 2) / (edge + 2)))
            let side = floor((w - CGFloat(cols - 1) * 2) / CGFloat(cols))
            return NSSize(width: side, height: side)
        }

        /// Sicherungsstatus unter dem neuesten Monat (nur Mediathek, siehe LibraryFooter)
        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, referenceSizeForFooterInSection s: Int) -> NSSize {
            guard LibraryFooter.shows(lib), s == lib.sections.count - 1 else { return .zero }
            return NSSize(width: max(1, cv.enclosingScrollView?.contentSize.width ?? cv.bounds.width), height: LibraryFooter.height)
        }

        // MARK: Auswahl

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) { syncSelection(cv, last: paths.max()) }
        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt paths: Set<IndexPath>) { syncSelection(cv, last: nil) }

        private func syncSelection(_ cv: NSCollectionView, last: IndexPath?) {
            lib.selection = Set(cv.selectionIndexPaths.compactMap { lib.asset(at: $0)?.id })
            if let last, let a = lib.asset(at: last) { lib.focused = a }
            else if let f = lib.focused, !lib.selection.contains(f.id) { lib.focused = lib.selectedAssets.last }
        }

        func open(_ p: IndexPath) { lib.open(p) }

        // MARK: Ziehen in den Finder

        func collectionView(_ cv: NSCollectionView, canDragItemsAt paths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

        func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt p: IndexPath) -> NSPasteboardWriting? {
            guard let a = lib.asset(at: p) else { return nil }
            let name = lib.fileNames[a.id] ?? "\(Fmt.dayLongMonthYear.string(from: a.date)) \(a.id.prefix(6)).\(a.isVideo ? "mov" : "jpg")"
            let d = AssetPromise(a, name: name)
            promises.append(d)
            if promises.count > 500 { promises.removeFirst(250) }
            return NSFilePromiseProvider(fileType: (a.isVideo ? UTType.movie : UTType.image).identifier, delegate: d)
        }

        // MARK: Ablegen aus dem Finder = Import ins Mac-Konto

        func collectionView(_ cv: NSCollectionView, validateDrop info: NSDraggingInfo,
                            proposedIndexPath p: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard info.draggingSource == nil, AccountStore.shared.canImport,
                  info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            else { return [] }
            return .copy
        }

        func collectionView(_ cv: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath,
                            dropOperation: NSCollectionView.DropOperation) -> Bool {
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            Task { await Transfer.importFiles(urls) }
            return true
        }

        // MARK: Kontextmenü

        func menu(for p: IndexPath?) -> NSMenu? {
            guard let cv else { return nil }
            if let p, !cv.selectionIndexPaths.contains(p) {
                cv.selectionIndexPaths = [p]
                syncSelection(cv, last: p)
            }
            guard !lib.selection.isEmpty else { return nil }
            return Menus.assetMenu(lib)
        }
    }
}

/// Doppelklick, Leertaste/Eingabe öffnen, ⌫ löscht, „.“ = Favorit – wie Fotos.
final class GridCollectionView: NSCollectionView {
    weak var coordinator: PhotoGrid.Coordinator?

    override func mouseDown(with e: NSEvent) {
        super.mouseDown(with: e)
        if e.clickCount == 2, let p = indexPathForItem(at: convert(e.locationInWindow, from: nil)) { coordinator?.open(p) }
    }

    override func keyDown(with e: NSEvent) {
        let lib = Library.shared
        switch e.keyCode {
        case 49:                  // Leertaste = Einzelansicht
            if let p = selectionIndexPaths.max() { coordinator?.open(p) }
        case 36, 76:              // ↩ = Bearbeiten (wie Fotos)
            lib.edit()
        case 51 where e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:   // ⌫
            Task { await lib.source == .trash ? () : lib.trash() }
        default:
            if e.charactersIgnoringModifiers == "." && e.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                Task { await lib.toggleFavorite() }
            } else { super.keyDown(with: e) }
        }
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        coordinator?.menu(for: indexPathForItem(at: convert(e.locationInWindow, from: nil)))
    }
}

/// Kachel: Bild füllt das Quadrat, unten Herz/Videodauer/LIVE, Auswahl als blauer Rahmen.
final class ThumbItem: NSCollectionViewItem {
    static let ident = NSUserInterfaceItemIdentifier("ThumbItem")
    private let imageLayer = CALayer()
    private let badge = NSTextField(labelWithString: "")
    private let heart = NSImageView()
    private var assetID: String?
    private var task: Task<Void, Never>?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        v.layer?.addSublayer(imageLayer)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.shadow = { let s = NSShadow(); s.shadowBlurRadius = 2; s.shadowColor = .black; return s }()
        heart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Favorite")
        heart.contentTintColor = .white
        heart.shadow = badge.shadow
        for s in [badge, heart] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -5),
            badge.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
            heart.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 5),
            heart.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -5),
            heart.widthAnchor.constraint(equalToConstant: 13), heart.heightAnchor.constraint(equalToConstant: 12)])
        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = view.bounds
        CATransaction.commit()
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }

    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection
        view.layer?.borderWidth = on ? 3 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        imageLayer.opacity = on ? 0.85 : 1
    }

    func show(_ a: Asset?, edge: CGFloat, reload: Bool = false) {
        _ = view
        let id = a?.id
        if id != assetID || reload {
            task?.cancel()
            assetID = id
            imageLayer.contents = nil
            if let a {
                let size: ImmichClient.Size = edge > 220 ? .preview : .thumbnail
                if let img = ImageCache.shared.get(a.id, size) { imageLayer.contents = img }
                else {
                    imageLayer.contents = ImageCache.shared.placeholder(a.id)
                    // Vorschau fehlt noch (Server rechnet nach dem Hochladen nach) → später erneut versuchen,
                    // solange die Kachel dieses Objekt zeigt
                    task = Task { [weak self] in
                        for delay in [0.0, 3, 6, 12, 20, 30, 45, 60, 60, 90, 120, 180] {
                            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                            guard !Task.isCancelled else { return }
                            if let img = await ImageCache.shared.load(a.id, size) {
                                guard !Task.isCancelled, let self, self.assetID == a.id else { return }
                                self.imageLayer.contents = img
                                return
                            }
                        }
                    }
                }
            }
        }
        heart.isHidden = !(a?.isFavorite ?? false)
        if let a, a.isVideo { badge.stringValue = Fmt.duration(a.durationMs) }
        else if a?.isLivePhoto == true && edge > 140 { badge.stringValue = "LIVE" }
        else { badge.stringValue = "" }
        view.setAccessibilityLabel(a.map { "\($0.isVideo ? "Video" : "Photo"), \(Fmt.dayLongMonthYear.string(from: $0.date))" })
        updateSelection()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel(); task = nil
        assetID = nil
        imageLayer.contents = nil
    }
}

final class MonthHeader: NSView, NSCollectionViewElement {
    static let ident = NSUserInterfaceItemIdentifier("MonthHeader")
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        let blur = NSVisualEffectView()
        blur.material = .headerView; blur.blendingMode = .withinWindow
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur); addSubview(label)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
