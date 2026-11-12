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

/// Foto: Vorschau sofort, volle Auflösung danach; Zoomen per Trackpad/Scrollrad, Verschieben per Zwei-Finger-Geste oder Klick & Ziehen.
private struct StillView: View {
    let asset: Asset
    @State private var image: CGImage?
    @State private var hdr = false
    @State private var pan = ViewerPanState()
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { g in
            let currentScale = pan.scale * pinch
            let rawOffset = CGSize(width: pan.offset.width + drag.width, height: pan.offset.height + drag.height)
            let currentOffset = pan.clamp(rawOffset, scale: currentScale)

            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .allowedDynamicRange(hdr ? .high : .standard)
                        .scaleEffect(currentScale)
                        .offset(currentOffset)
                        .frame(width: g.size.width, height: g.size.height)
                        .simultaneousGesture(
                            MagnifyGesture()
                                .updating($pinch) { v, s, _ in s = v.magnification }
                                .onEnded { v in
                                    let newScale = min(6, max(1, pan.scale * v.magnification))
                                    pan.scale = newScale
                                    if newScale <= 1 {
                                        pan.offset = .zero
                                    } else {
                                        pan.offset = pan.clamp(pan.offset, scale: newScale)
                                    }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 1)
                                .updating($drag) { v, s, _ in
                                    if pan.scale * pinch > 1 {
                                        s = v.translation
                                    }
                                }
                                .onEnded { v in
                                    if pan.scale > 1 {
                                        pan.offset = pan.clamp(
                                            CGSize(width: pan.offset.width + v.translation.width, height: pan.offset.height + v.translation.height),
                                            scale: pan.scale
                                        )
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.snappy) {
                                if pan.scale > 1 {
                                    pan.scale = 1
                                    pan.offset = .zero
                                } else {
                                    pan.scale = 2.5
                                }
                            }
                        }
                } else {
                    ProgressView().frame(width: g.size.width, height: g.size.height)
                }
            }
            .onAppear {
                pan.viewSize = g.size
                if let image {
                    pan.imageSize = CGSize(width: image.width, height: image.height)
                }
            }
            .onChange(of: g.size) { _, newSize in
                pan.viewSize = newSize
                pan.offset = pan.clamp(pan.offset, scale: pan.scale)
            }
            .onChange(of: image) { _, newImg in
                if let newImg {
                    pan.imageSize = CGSize(width: newImg.width, height: newImg.height)
                    pan.offset = pan.clamp(pan.offset, scale: pan.scale)
                }
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
        .onAppear {
            setupScrollMonitor()
        }
        .onDisappear {
            removeScrollMonitor()
        }
    }

    private func setupScrollMonitor() {
        removeScrollMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak pan] event in
            guard let pan, pan.scale > 1.0 else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return event }
            pan.handleScroll(dx: dx, dy: dy)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
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

@Observable
@MainActor
final class ViewerPanState {
    var scale: CGFloat = 1.0
    var offset: CGSize = .zero
    var viewSize: CGSize = .zero
    var imageSize: CGSize = .zero

    func handleScroll(dx: CGFloat, dy: CGFloat) {
        guard scale > 1.0 else { return }
        offset = clamp(CGSize(width: offset.width + dx, height: offset.height + dy), scale: scale)
    }

    func clamp(_ target: CGSize, scale s: CGFloat) -> CGSize {
        guard s > 1.0, viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let aspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        let fitW: CGFloat
        let fitH: CGFloat
        if aspect > viewAspect {
            fitW = viewSize.width
            fitH = viewSize.width / aspect
        } else {
            fitH = viewSize.height
            fitW = viewSize.height * aspect
        }
        let scaledW = fitW * s
        let scaledH = fitH * s
        let maxOffsetX = max(0, (scaledW - viewSize.width) / 2)
        let maxOffsetY = max(0, (scaledH - viewSize.height) / 2)
        return CGSize(
            width: min(maxOffsetX, max(-maxOffsetX, target.width)),
            height: min(maxOffsetY, max(-maxOffsetY, target.height))
        )
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
