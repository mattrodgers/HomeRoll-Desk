import AppKit

/// Ein durchgehendes Raster über alle Monate wie Fotos auf dem Mac (GitHub #7): Die Monate (Abschnitte) folgen
/// ohne Lücke am Monatsende aufeinander, der Monat steht als mitlaufende Kapsel oben (MainView). Abschnitte bleiben
/// für das monatsweise Nachladen erhalten; nur die Anordnung zählt global durch.
final class ContinuousGridLayout: NSCollectionViewLayout {
    var edge: CGFloat = 150 { didSet { if edge != oldValue { invalidateLayout() } } }
    /// Höhe der Fußzeile unter dem letzten Abschnitt (0 = keine) – bei jedem Layout neu erfragt
    var footerProvider: () -> CGFloat = { 0 }
    private var footerHeight: CGFloat = 0
    private let spacing: CGFloat = 2
    private var starts: [Int] = []
    private var total = 0
    private var cols = 1
    private var side: CGFloat = 100
    private var width: CGFloat = 1

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        width = max(1, cv.enclosingScrollView?.contentSize.width ?? cv.bounds.width)
        cols = max(1, Int((width + spacing) / (edge + spacing)))
        side = floor((width - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        footerHeight = footerProvider()
        starts = []; total = 0
        for s in 0..<cv.numberOfSections { starts.append(total); total += cv.numberOfItems(inSection: s) }
    }

    private var rows: Int { (total + cols - 1) / cols }
    private var gridHeight: CGFloat { rows == 0 ? 0 : CGFloat(rows) * (side + spacing) - spacing }
    override var collectionViewContentSize: NSSize { NSSize(width: width, height: gridHeight + footerHeight) }

    private func rect(_ g: Int) -> NSRect {
        NSRect(x: CGFloat(g % cols) * (side + spacing), y: CGFloat(g / cols) * (side + spacing), width: side, height: side)
    }
    /// Globale Nummer → Abschnitt/Objekt (Abschnittsanfänge sind sortiert → Binärsuche)
    func indexPath(global g: Int) -> IndexPath? {
        guard g >= 0, g < total, !starts.isEmpty else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi { let m = (lo + hi + 1) / 2; if starts[m] <= g { lo = m } else { hi = m - 1 } }
        return IndexPath(item: g - starts[lo], section: lo)
    }
    /// Erstes Objekt oben links im sichtbaren Bereich (für den mitlaufenden Monat)
    func indexPath(atY y: CGFloat) -> IndexPath? {
        indexPath(global: min(total - 1, max(0, Int(max(0, y) / (side + spacing)) * cols)))
    }

    private func attributes(_ p: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard p.section < starts.count else { return nil }
        let a = NSCollectionViewLayoutAttributes(forItemWith: p)
        a.frame = rect(starts[p.section] + p.item)
        return a
    }
    private func footer() -> NSCollectionViewLayoutAttributes? {
        guard footerHeight > 0, !starts.isEmpty else { return nil }
        let a = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
                                                 with: IndexPath(item: 0, section: starts.count - 1))
        a.frame = NSRect(x: 0, y: gridHeight, width: width, height: footerHeight)
        return a
    }

    override func layoutAttributesForElements(in r: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var out: [NSCollectionViewLayoutAttributes] = []
        if total > 0 {
            let r0 = max(0, Int(r.minY / (side + spacing))), r1 = min(rows - 1, Int(r.maxY / (side + spacing)))
            if r0 <= r1 {
                for g in (r0 * cols)...min(total - 1, r1 * cols + cols - 1) {
                    if let p = indexPath(global: g), let a = attributes(p) { out.append(a) }
                }
            }
        }
        if let f = footer(), f.frame.intersects(r) { out.append(f) }
        return out
    }
    override func layoutAttributesForItem(at p: IndexPath) -> NSCollectionViewLayoutAttributes? { attributes(p) }
    override func layoutAttributesForSupplementaryView(ofKind k: NSCollectionView.SupplementaryElementKind,
                                                       at p: IndexPath) -> NSCollectionViewLayoutAttributes? {
        k == NSCollectionView.elementKindSectionFooter && p.section == starts.count - 1 ? footer() : nil
    }
    override func shouldInvalidateLayout(forBoundsChange b: NSRect) -> Bool { b.width != width }
}
