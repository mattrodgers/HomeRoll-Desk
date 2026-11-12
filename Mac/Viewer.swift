import AppKit
import AVKit
import SwiftUI

/// Einzelansicht im selben Fenster (wie IPXOneUpViewerController): Leertaste/Esc/⌘↑ zurück, ←/→ blättern,
/// „.“ Favorit, ⌘I Infos. Erst die schnelle Vorschau, dann die volle Auflösung.
struct ViewerView: View {
    @Bindable var lib: Library
    let path: IndexPath

    var body: some View {
        let a = lib.asset(at: path)
        ZStack {
            Color.black.ignoresSafeArea()
            if let a {
                if a.isVideo { VideoPlayerView(asset: a).id(a.id) }
                else { StillView(asset: a).id(a.id) }
            } else { ProgressView() }
            KeyCatcher { key in handle(key) }.frame(width: 0, height: 0)
        }
        .overlay(alignment: .top) {
            if let a {
                HStack(spacing: 14) {
                    Button { lib.closeViewer() } label: { Image(systemName: "chevron.left") }.help("Back (Space)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Fmt.relativeDay(a.date, fallback: Fmt.dayLongMonthYear)).font(.headline)
                        Text([Fmt.time.string(from: a.date), a.city].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await lib.toggleFavorite() } } label: {
                        Image(systemName: a.isFavorite ? "heart.fill" : "heart")
                    }.disabled(!AccountStore.shared.canWrite).help("Favorite (.)")
                    Button { InfoWindow.show() } label: { Image(systemName: "info.circle") }.help("Info (⌘I)")
                    if a.isImage {
                        Button("Edit") { lib.edit() }.disabled(!AccountStore.shared.canWrite).help("Edit (↩)")
                    }
                }
                .buttonStyle(.borderless)
                .font(.title3)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear { lib.focused = a }
        .onChange(of: path) { lib.focused = lib.asset(at: path) }
    }

    private func handle(_ e: NSEvent) -> Bool {
        let plain = e.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch e.keyCode {
        case 123: go(-1); return true                         // ←
        case 124: go(1); return true                          // →
        case 49 where plain, 53: lib.closeViewer(); return true   // Leertaste, Esc
        case 126 where e.modifierFlags.contains(.command): lib.closeViewer(); return true   // ⌘↑
        case 36 where plain, 76 where plain: lib.edit(); return true                          // ↩ = Bearbeiten
        default:
            if e.charactersIgnoringModifiers == "." && plain { Task { await lib.toggleFavorite() }; return true }
            if e.keyCode == 51 && plain && lib.source != .trash { Task { await lib.trash() }; return true }
            return false
        }
    }

    private func go(_ d: Int) {
        guard let p = lib.step(path, by: d) else { return }
        lib.viewer = p
        if let a = lib.asset(at: p) { lib.selection = [a.id]; lib.focused = a }
    }
}

/// Foto: Vorschau sofort, volle Auflösung danach; Zoomen per Trackpad/Scrollrad.
private struct StillView: View {
    let asset: Asset
    @State private var image: CGImage?
    @State private var hdr = false
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { g in
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .allowedDynamicRange(hdr ? .high : .standard)
                    .scaleEffect(scale * pinch)
                    .frame(width: g.size.width, height: g.size.height)
                    .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                        .onEnded { v in scale = min(6, max(1, scale * v.magnification)) })
                    .onTapGesture(count: 2) { withAnimation(.snappy) { scale = scale > 1 ? 1 : 2.5 } }
            } else {
                ProgressView().frame(width: g.size.width, height: g.size.height)
            }
        }
        .task {
            if let t = ImageCache.shared.get(asset.id, .preview) ?? ImageCache.shared.get(asset.id, .thumbnail) { image = t }
            if let p = await ImageCache.shared.load(asset.id, .preview) { image = p }
            // GitHub HomeRoll #36: Immichs Vorschauen sind ohne HDR → Original mit Gain-Map selbst dekodieren
            if UserDefaults.standard.object(forKey: "mac.alwaysOriginal") as? Bool ?? true, asset.isImage,
               let f = await Self.original(asset.id) { image = f; hdr = true; return }
            if let f = await ImageCache.shared.load(asset.id, .fullsize) { image = f }
        }
    }

    /// Original vom Server als HDR-Bild (Gain-Map/HDR-Format), höchstens 6000 px; nil = nicht dekodierbar.
    static func original(_ id: String) async -> CGImage? {
        guard let url = ImmichClient.shared.originalURL(id), let data = try? await ImmichClient.shared.data(url) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 6000, kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
        }.value
    }
}

/// Video mit den Mac-Bedienelementen (AVPlayerView); nicht abspielbare Formate → Original/HLS wie auf dem iPhone.
private struct VideoPlayerView: NSViewRepresentable {
    let asset: Asset
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        let api = ImmichClient.shared
        if let url = api.videoURL(asset.id) {
            let item = AVPlayerItem(asset: api.avAsset(url))
            v.player = AVPlayer(playerItem: item)
            v.player?.play()
            let id = asset.id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if item.status == .failed, let alt = await api.playableFallback(for: id) {
                    v.player = AVPlayer(playerItem: AVPlayerItem(asset: alt)); v.player?.play()
                }
            }
        }
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}

/// Nimmt Tasten an, solange die Einzelansicht offen ist (wird beim Erscheinen Ersthelfer).
struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyView {
        let v = KeyView(); v.onKey = onKey
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ v: KeyView, context: Context) { v.onKey = onKey }

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
    }
}
