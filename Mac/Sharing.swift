import AppKit
import Foundation
import SwiftUI

/// Verwaltet das native macOS-Teilen-Menü (NSSharingServicePicker) für ausgewählte Fotos und Videos.
@MainActor
enum Sharing {
    fileprivate static var activePicker: NSSharingServicePicker?
    fileprivate static var lastDismissedAt: Date?

    /// Prüft, ob das Teilen-Menü gerade geöffnet ist oder durch den Klick gerade geschlossen wurde.
    static var isOpen: Bool {
        if activePicker != nil { return true }
        if let last = lastDismissedAt, Date().timeIntervalSince(last) < 0.45 {
            return true
        }
        return false
    }

    /// Schließt das Teilen-Menü, falls es geöffnet ist.
    static func close() {
        if let picker = activePicker {
            picker.close()
            activePicker = nil
        }
        lastDismissedAt = Date()
    }

    /// Zwischenspeicher für geteilte Dateien in temporärem Ordner
    private static var cacheDirectory: URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("HomeRollShare", isDirectory: true).resolvingSymlinksInPath()
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    /// Bereitet lokale Datei-URLs für die übergebenen Assets vor (lädt sie bei Bedarf herunter).
    static func prepareFiles(for assets: [Asset], lib: Library = Library.shared) async -> [URL] {
        guard !assets.isEmpty else { return [] }
        pruneCache()

        var urls: [URL] = []
        let total = assets.count

        for (index, asset) in assets.enumerated() {
            if total > 1 {
                lib.status = "Preparing \(index + 1) of \(total) to share…"
            } else {
                lib.status = "Preparing to share…"
            }

            do {
                let fileURL = try await prepareFile(for: asset, lib: lib)
                urls.append(fileURL)
            } catch {
                if !Task.isCancelled {
                    let name = await lib.fileName(asset)
                    lib.error = "Could not prepare “\(name)”: \(error.localizedDescription)"
                }
            }
        }

        lib.status = nil
        return urls
    }

    /// Lädt eine einzelne Datei in den Cache oder nutzt die bestehende Datei.
    private static func prepareFile(for asset: Asset, lib: Library) async throws -> URL {
        let filename = await lib.fileName(asset)
        let version = ImageCache.shared.version(asset.id) ?? "0"
        let folder = cacheDirectory.appendingPathComponent("\(asset.id)-\(version)", isDirectory: true).resolvingSymlinksInPath()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let dest = folder.appendingPathComponent(filename).resolvingSymlinksInPath()

        if FileManager.default.fileExists(atPath: dest.path),
           let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
            return dest
        }

        try await Transfer.download(asset.id, edited: true, to: dest)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        return dest
    }

    /// Löscht Dateien im Cache, die älter als 24 Stunden sind.
    private static func pruneCache() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86400)
        guard let items = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            if let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    /// Öffnet das native macOS Share Sheet für die übergebenen Assets.
    static func share(_ assets: [Asset], from sourceView: NSView? = nil) async {
        if isOpen {
            close()
            return
        }

        let lib = Library.shared
        guard !assets.isEmpty else { return }

        let files = await prepareFiles(for: assets, lib: lib)
        guard !files.isEmpty else { return }

        if isOpen {
            close()
            return
        }

        SharingDelegate.shared.setContext(assets: assets, files: files)

        let picker = NSSharingServicePicker(items: files)
        picker.delegate = SharingDelegate.shared
        activePicker = picker
        lastDismissedAt = nil

        if let anchor = resolveAnchor(sourceView) {
            picker.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .minY)
        }
    }

    /// Öffnet einen Finder-Dialog (NSOpenPanel) und exportiert die Assets auf die Festplatte.
    static func exportToDisk(assets: [Asset], cachedFiles: [URL]) {
        let count = assets.count
        guard count > 0 else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = count == 1 ? "Choose a folder to export the item to…" : "Choose a folder to export \(itemsText(count)) to…"

        guard panel.runModal() == .OK, let dir = panel.url else { return }

        Task {
            var ok = 0
            let lib = Library.shared
            for (index, asset) in assets.enumerated() {
                lib.status = "Exporting \(index + 1) of \(count)…"
                let name = await lib.fileName(asset)
                let dest = Transfer.unique(dir.appendingPathComponent(name))

                // Falls die Datei bereits im Teilen-Cache liegt, direkt kopieren
                let cached = cachedFiles.first(where: { $0.lastPathComponent == name || $0.path.contains(asset.id) })
                if let cached, FileManager.default.fileExists(atPath: cached.path) {
                    do {
                        try FileManager.default.copyItem(at: cached, to: dest)
                        ok += 1
                        continue
                    } catch { }
                }

                if (try? await Transfer.download(asset.id, edited: true, to: dest)) != nil {
                    ok += 1
                }
            }

            lib.status = "Exported \(ok) of \(count)"
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    /// Ermittelt die passende NSView und das Rechteck für das Popup.
    private static func resolveAnchor(_ sourceView: NSView?) -> (view: NSView, rect: NSRect)? {
        if let v = sourceView, (v.window != nil || v.superview?.window != nil) {
            let target = v.window != nil ? v : (v.superview ?? v)
            return (target, target.bounds)
        }
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let contentView = w.contentView else { return nil }

        if let event = NSApp.currentEvent, event.window == w {
            let p = contentView.convert(event.locationInWindow, from: nil)
            return (contentView, NSRect(origin: p, size: .zero))
        }

        let y = contentView.isFlipped ? 20.0 : max(0, contentView.bounds.height - 40.0)
        return (contentView, NSRect(x: contentView.bounds.maxX - 100, y: y, width: 1, height: 1))
    }
}

/// Delegat für das Teilen-Menü: Rückmeldungen, eigene Dienste (Export) und Bereinigung.
final class SharingDelegate: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate, @unchecked Sendable {
    static let shared = SharingDelegate()

    private let lock = NSLock()
    private var currentAssets: [Asset] = []
    private var currentFiles: [URL] = []

    func setContext(assets: [Asset], files: [URL]) {
        lock.withLock {
            self.currentAssets = assets
            self.currentFiles = files
        }
    }

    private func getContext() -> (assets: [Asset], files: [URL]) {
        lock.withLock { (currentAssets, currentFiles) }
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        let (assets, files) = getContext()
        let exportService = NSSharingService(
            title: "Export to Disk…",
            image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Export to Disk") ??
                   NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Export to Disk") ?? NSImage(),
            alternateImage: nil
        ) {
            Task { @MainActor in
                Sharing.exportToDisk(assets: assets, cachedFiles: files)
            }
        }

        var services = proposedServices
        if let airdropIndex = services.firstIndex(where: { $0.title.localizedCaseInsensitiveContains("airdrop") }) {
            services.insert(exportService, at: airdropIndex + 1)
        } else {
            services.insert(exportService, at: 0)
        }
        return services
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        self
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        Task { @MainActor in
            Sharing.activePicker = nil
            Sharing.lastDismissedAt = Date()
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in
            Library.shared.status = "Shared successfully"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Library.shared.status == "Shared successfully" {
                Library.shared.status = nil
            }
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
        if ns.domain == "NSSharingServiceErrorDomain" && ns.code == 1 { return }
        Task { @MainActor in
            Library.shared.error = "Sharing failed: \(error.localizedDescription)"
        }
    }
}

/// SwiftUI-Hilfsansicht, die Zugriff auf die darunterliegende NSView ermöglicht.
struct ViewAccessor: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            if let v { onView(v) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let nsView { onView(nsView) }
        }
    }
}

/// Teilen-Schaltfläche für die Symbolleiste (Toolbar).
struct ShareButton: View {
    @Bindable var lib = Library.shared
    @State private var isPreparing = false
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            Task {
                if Sharing.isOpen {
                    Sharing.close()
                    return
                }
                guard !isPreparing else { return }
                isPreparing = true
                defer { isPreparing = false }
                await Sharing.share(lib.targets, from: anchorView)
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .background(ViewAccessor { anchorView = $0 })
        .disabled(lib.targets.isEmpty)
        .help("Share")
    }
}

/// Teilen-Schaltfläche für die Einzelansicht (Viewer).
struct ViewerShareButton: View {
    let asset: Asset
    @State private var isPreparing = false
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            Task {
                if Sharing.isOpen {
                    Sharing.close()
                    return
                }
                guard !isPreparing else { return }
                isPreparing = true
                defer { isPreparing = false }
                await Sharing.share([asset], from: anchorView)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .background(ViewAccessor { anchorView = $0 })
        .help("Share")
    }
}
