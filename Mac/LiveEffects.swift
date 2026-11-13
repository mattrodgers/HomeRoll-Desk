import AppKit
import AVFoundation
import CoreImage
import SwiftUI
import Vision

/// Live Photos auf dem Mac (GitHub #8): Abzeichen „LIVE“ oben links in der Einzelansicht wie in Fotos – Zeiger
/// darauf spielt das Live-Video, das Menü daneben schaltet die Effekte (Live · Loop · Bounce · Long Exposure · Off).
/// Nur Anzeige, das Foto auf dem Server bleibt unverändert; die Wahl wird je Foto gemerkt.
enum LiveMode: String, CaseIterable, Identifiable {
    case live, loop, bounce, longExposure, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live"; case .loop: "Loop"; case .bounce: "Bounce"; case .longExposure: "Long Exposure"; case .off: "Off"
        }
    }
    var icon: String {
        switch self {
        case .live: "livephoto"; case .loop: "repeat"; case .bounce: "arrow.left.arrow.right"
        case .longExposure: "camera.aperture"; case .off: "livephoto.slash"
        }
    }
    private static let key = "mac.liveModes"
    static func get(_ id: String) -> LiveMode {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id].flatMap(LiveMode.init) ?? .live
    }
    static func set(_ m: LiveMode, for id: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[id] = m == .live ? nil : m.rawValue
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// Das kurze Video eines Live Photos einmal in den Cache laden (Bounce und Schlüsselbild im Editor brauchen eine lokale Datei).
enum LiveClip {
    static func file(_ videoID: String) async -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("live")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(videoID).mov")
        if FileManager.default.fileExists(atPath: f.path) { return f }
        guard let url = ImmichClient.shared.videoURL(videoID), let d = try? await ImmichClient.shared.data(url) else { return nil }
        try? d.write(to: f, options: .atomic)
        return f
    }

    /// Langzeitbelichtung: alle Bilder des Clips aufeinander ausgerichtet (Vision) und gemittelt.
    static func longExposure(_ videoID: String) async -> CGImage? {
        guard let f = await file(videoID) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let av = AVURLAsset(url: f)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 2048, height: 2048)
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            guard let d = try? await av.load(.duration).seconds, d > 0 else { return nil }
            let n = 30
            let times = (0..<n).map { CMTime(seconds: d * Double($0) / Double(n), preferredTimescale: 600) }
            var sum: CIImage?, count = 0
            var reference: CGImage?
            for await r in gen.images(for: times) {
                guard let cg = try? r.image else { continue }
                var img = CIImage(cgImage: cg)
                if let ref = reference {
                    let req = VNTranslationalImageRegistrationRequest(targetedCGImage: cg)
                    if (try? VNImageRequestHandler(cgImage: ref).perform([req])) != nil,
                       let t = (req.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform {
                        img = img.transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: ref.width, height: ref.height))
                        img = img.composited(over: CIImage(cgImage: ref))
                    }
                } else { reference = cg }
                count += 1
                if let s = sum {
                    let a = CGFloat(1) / CGFloat(count)
                    sum = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)]).composited(over: s)
                } else { sum = img }
            }
            guard let sum else { return nil }
            return CIContext().createCGImage(sum, from: sum.extent)
        }.value
    }
}

/// Spielt das Live-Video stumm: einmal (Live, danach verschwindet es wieder), in Schleife oder vor/zurück (Bounce).
struct LiveVideo: NSViewRepresentable {
    enum Style { case once, loop, bounce }
    let videoID: String
    let style: Style
    var onEnd: () -> Void = {}

    func makeCoordinator() -> Coord { Coord() }
    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        context.coordinator.start(videoID, style: style, in: v, onEnd: onEnd)
        return v
    }
    func updateNSView(_ v: LayerView, context: Context) {}
    static func dismantleNSView(_ v: LayerView, coordinator: Coord) { coordinator.stop() }

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); playerLayer.frame = bounds }
        override func hitTest(_ p: NSPoint) -> NSView? { nil }   // Klicks/Zoomen gehen an das Foto darunter
    }

    @MainActor final class Coord {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var obs: NSObjectProtocol?
        private var task: Task<Void, Never>?
        private var bounceTask: Task<Void, Never>?

        func start(_ id: String, style: Style, in v: LayerView, onEnd: @escaping () -> Void) {
            task = Task { [weak self, weak v] in
                guard let f = await LiveClip.file(id), !Task.isCancelled, let self, let v else { if !Task.isCancelled { onEnd() }; return }
                let item = AVPlayerItem(url: f)
                let p = AVQueuePlayer(); p.isMuted = true
                switch style {
                case .loop:
                    self.looper = AVPlayerLooper(player: p, templateItem: item)
                case .once:
                    p.insert(item, after: nil)
                    self.obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in onEnd() }
                case .bounce:
                    p.insert(item, after: nil)
                    p.actionAtItemEnd = .pause
                    self.obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
                        MainActor.assumeIsolated { if item.canPlayReverse { p?.rate = -1 } else { p?.seek(to: .zero); p?.play() } }
                    }
                    self.bounceTask = Task { @MainActor [weak p] in
                        while let p, !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(100))
                            if p.rate < 0, p.currentTime().seconds <= 0.05 { p.rate = 1 }
                        }
                    }
                }
                v.playerLayer.player = p
                self.player = p
                p.play()
            }
        }
        func stop() {
            task?.cancel(); bounceTask?.cancel(); player?.pause(); player = nil; looper = nil
            if let obs { NotificationCenter.default.removeObserver(obs) }
        }
    }
}

/// Abzeichen oben links wie in Fotos: „LIVE ⌄“ – Zeiger auf dem Abzeichen spielt das Video, Menü wählt den Effekt.
struct LiveBadge: View {
    let mode: LiveMode
    let onHover: (Bool) -> Void
    let onSelect: (LiveMode) -> Void

    var body: some View {
        Menu {
            Picker("Live Photo Effect", selection: Binding(get: { mode }, set: onSelect)) {
                ForEach(LiveMode.allCases) { m in Label(m.title, systemImage: m.icon).tag(m) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                Text(mode == .live ? "LIVE" : mode.title.uppercased())
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.button).buttonStyle(.borderless).fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .onHover(perform: onHover)
        .help("Hover to play · choose a Live Photo effect")
        .accessibilityIdentifier("liveBadge")
    }
}
