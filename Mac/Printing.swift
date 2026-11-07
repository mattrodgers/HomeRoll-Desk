import AppKit
import PDFKit

/// Drucken wie in Fotos (⌘P): je Foto eine Seite, eingepasst und automatisch gedreht; der Mac-Druckdialog
/// bietet Drucker, Papier, Anzahl und „Als PDF sichern“.
@MainActor
enum Printing {
    static func printSelection() async {
        let lib = Library.shared
        let items = lib.targets.filter(\.isImage)
        guard !items.isEmpty else { return }
        let doc = PDFDocument()
        for (i, a) in items.enumerated() {
            lib.status = "Preparing to print \(i + 1) of \(items.count)…"
            var img = await ImageCache.shared.load(a.id, .fullsize)
            if img == nil { img = await ImageCache.shared.load(a.id, .preview) }
            guard let cg = img else { continue }
            if let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        lib.status = nil
        guard doc.pageCount > 0 else { lib.error = "The photos couldn’t be loaded."; return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        op.jobTitle = items.count == 1 ? "Photo" : "\(items.count) Photos"
        if let w = NSApp.mainWindow { op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    /// Für den Selbsttest: PDF erzeugen, ohne Dialog.
    static func pdf(_ ids: [String]) async -> PDFDocument {
        let doc = PDFDocument()
        for id in ids {
            if let cg = await ImageCache.shared.load(id, .preview),
               let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        return doc
    }
}
