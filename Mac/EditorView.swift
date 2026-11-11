import AppKit
import SwiftUI

/// Bearbeiten wie in Fotos auf dem Mac (IPXAdjustmentStackController): Bild links, Werkzeuge rechts,
/// Reiter Anpassen · Filter · Stile · Zuschneiden. Rechnet mit dem geteilten iPhone-Kern (EditSession/EditRenderer),
/// speichert also genauso: Zuschnitt/Drehen beim Server, Licht/Farbe als neue Fassung gestapelt mit dem Original.
struct EditorView: View {
    @Bindable var lib: Library
    @State private var session: EditSession
    @State private var tab: Tab = .adjust
    @State private var comparing = false
    @State private var original: CGImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var error: String?

    enum Tab: String, CaseIterable { case adjust = "Adjust", filter = "Filters", style = "Styles", crop = "Crop", retouch = "Clean Up" }
    @State private var brush = 0.03

    init(lib: Library, asset: Asset) {
        self.lib = lib
        _session = State(initialValue: EditSession(asset: asset))
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if tab == .crop && !comparing, let full = session.fullPreview?.cgImage {
                    CropCanvas(image: full, rect: $session.state.displayCrop).padding(24)
                } else if tab == .retouch && !comparing, let img = session.cleanupPreview?.cgImage ?? original {
                    BrushCanvas(image: img, width: brush) { stroke in
                        session.state.cleanup.append(stroke)
                        Task { await session.applyCleanup() }
                    }.padding(24)
                    if session.cleaning { ProgressView("Cleaning Up…").padding().background(.thinMaterial, in: .rect(cornerRadius: 10)) }
                } else if let img = comparing ? original : session.preview?.cgImage {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(24)
                } else if session.loading { ProgressView() }
                if let e = error ?? session.error { Text(e).foregroundStyle(.red).padding().background(.thinMaterial, in: .rect(cornerRadius: 8)) }
                if session.saving { ProgressView("Saving…").padding().background(.thinMaterial, in: .rect(cornerRadius: 10)) }
                KeyCatcher { e in
                    if e.keyCode == 53 { lib.editing = nil; return true }                       // Esc = abbrechen
                    if e.charactersIgnoringModifiers == "m" { comparing.toggle(); return true }  // M = vergleichen (wie Fotos)
                    return false
                }.frame(width: 0, height: 0)
            }
            Divider()
            tools.frame(width: 300).background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { bar }
        .task {
            await session.load()
            if let b = session.base { original = session.renderer.cgImage(b) }
        }
        .onChange(of: session.state) { _, _ in
            renderTask?.cancel()
            renderTask = Task { try? await Task.sleep(for: .milliseconds(40)); guard !Task.isCancelled else { return }; await session.render() }
        }
    }

    @ToolbarContentBuilder private var bar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { comparing.toggle() } label: { Label("Compare", systemImage: comparing ? "square.split.2x1.fill" : "square.split.2x1") }
                .help("Show without edits (M)")
            if session.canRestore {
                Button("Revert to Original") { Task { await finish { try await session.restore() } } }
            }
            Button("Reset") { session.state = EditState() }.disabled(session.state.isIdentity)
            Button("Cancel") { lib.editing = nil }.keyboardShortcut(.cancelAction)
            Button("Done") { Task { await finish { try await session.save() } } }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(session.loading || session.saving || !session.changed)
        }
    }

    private func finish(_ op: () async throws -> Asset) async {
        do {
            let new = try await op()
            await lib.afterEdit(old: session.asset, new: new)
        } catch { self.error = error.localizedDescription }
    }

    @ViewBuilder private var tools: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch tab {
                case .adjust: adjust
                case .filter: filters
                case .style: styles
                case .crop: crop
                case .retouch: retouch
                }
            }
            .padding(14)
        }
        .disabled(session.loading || session.saving)
    }

    // MARK: Anpassen

    @ViewBuilder private var adjust: some View {
        HStack {
            Toggle("Auto", isOn: Binding(get: { session.state.auto }, set: { _ in session.toggleAuto() })).toggleStyle(.button)
            if session.state.auto {
                Slider(value: $session.state.autoStrength, in: -1...1).help("Auto strength")
            }
        }
        ForEach(Adjust.allCases) { a in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(a.title).font(.callout)
                    Spacer()
                    Text(valueText(session.state.storedValue(a))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { session.state.values[a] = nil }
                .help("Double-click to reset")
                Slider(value: Binding(get: { session.state.storedValue(a) },
                                      set: { session.state.values[a] = $0; session.state.disabled.remove(a) }),
                       in: a.range)
                    .controlSize(.small)
            }
        }
        pro
    }

    // MARK: Profi-Werkzeuge (Mac): Tonwerte, Kurven, Selektive Farbe

    @State private var hue: SelectiveHue = .red

    @ViewBuilder private var pro: some View {
        Divider()
        HStack { Text("Levels").font(.headline); Spacer()
            Button("Reset") { session.state.levels = nil }.buttonStyle(.borderless).font(.caption).disabled(session.state.levels == nil) }
        ForEach(Array(["Black", "Midtones", "White"].enumerated()), id: \.offset) { i, name in
            HStack {
                Text(name).font(.callout).frame(width: 80, alignment: .leading)
                Slider(value: Binding(get: { (session.state.levels ?? [0, 1, 1])[i] },
                                      set: { var l = session.state.levels ?? [0, 1, 1]; l[i] = $0; session.state.levels = l }),
                       in: i == 1 ? 0.25...4 : 0...1).controlSize(.small)
            }
        }
        HStack { Text("Curves").font(.headline); Spacer()
            Button("Reset") { session.state.curves = nil }.buttonStyle(.borderless).font(.caption).disabled(session.state.curves == nil) }
        CurveEditor(values: Binding(get: { session.state.curves ?? [0, 0.25, 0.5, 0.75, 1] }, set: { session.state.curves = $0 }))
            .frame(height: 180)
        HStack { Text("Selective Color").font(.headline); Spacer()
            Button("Reset") { session.state.selective = [:] }.buttonStyle(.borderless).font(.caption).disabled(session.state.selective.isEmpty) }
        HStack(spacing: 6) {
            ForEach(SelectiveHue.allCases) { h in
                Circle().fill(Color(hue: h.center, saturation: 0.85, brightness: 0.95))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(hue == h ? Color.primary : .clear, lineWidth: 2))
                    .onTapGesture { hue = h }.help(h.title)
            }
        }
        ForEach(Array(["Hue", "Saturation", "Luminance"].enumerated()), id: \.offset) { i, name in
            HStack {
                Text(name).font(.callout).frame(width: 80, alignment: .leading)
                Slider(value: Binding(get: { session.state.selective[hue.rawValue]?[i] ?? 0 },
                                      set: { var v = session.state.selective[hue.rawValue] ?? [0, 0, 0]; v[i] = $0
                                             session.state.selective[hue.rawValue] = v.allSatisfy({ abs($0) < 0.003 }) ? nil : v }),
                       in: -1...1).controlSize(.small)
            }
        }
    }

    // MARK: Retusche (Bereinigen-Dienst auf dem Server, wie am iPhone)

    @ViewBuilder private var retouch: some View {
        Text("Paint over distracting areas – the server fills them in to match.").font(.callout).foregroundStyle(.secondary)
        Text("Brush Size").font(.callout)
        Slider(value: $brush, in: 0.008...0.12)
        HStack {
            Button("Undo Last Stroke") {
                guard !session.state.cleanup.isEmpty else { return }
                session.state.cleanup.removeLast(); Task { await session.applyCleanup() }
            }.disabled(session.state.cleanup.isEmpty || session.cleaning)
            Button("Remove All") { session.state.cleanup = []; Task { await session.applyCleanup() } }
                .disabled(session.state.cleanup.isEmpty || session.cleaning)
        }
        if let e = session.cleanError { Text(e).foregroundStyle(.red).font(.callout) }
        Text(session.state.cleanup.count == 1 ? "1 stroke" : "\(session.state.cleanup.count) strokes").font(.caption).foregroundStyle(.secondary)
    }

    private func valueText(_ v: Double) -> String { abs(v) < 0.005 ? "0" : String(Int((v * 100).rounded())) }

    // MARK: Filter / Stile

    @ViewBuilder private var filters: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 10) {
            ForEach(PhotoFilter.allCases) { f in
                tile(session.filterThumbs[f]?.cgImage, f.title, selected: session.state.filter == f) { session.state.filter = f }
            }
        }
        if session.state.filter != .original {
            Text("Intensity").font(.callout)
            Slider(value: $session.state.filterAmount, in: 0...1)
        }
    }

    @ViewBuilder private var styles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 10) {
            ForEach(PhotoStyle.allCases) { s in
                tile(session.styleThumbs[s]?.cgImage, s.title, selected: session.state.style == s) { session.state.style = s }
            }
        }
        Group {
            Text("Tone").font(.callout); Slider(value: $session.state.styleTone, in: -1...1)
            Text("Color").font(.callout); Slider(value: $session.state.styleColor, in: -1...1)
            Text("Palette").font(.callout); Slider(value: $session.state.stylePalette, in: 0...1)
        }.disabled(session.state.style == .standard && session.state.styleTone == 0 && session.state.styleColor == 0)
        // Fotografische Stile 3 (wie iPhone): Textur und Körnung, auch ohne Stil
        Text("Texture").font(.callout); Slider(value: $session.state.styleTexture, in: -1...1)
        Text("Grain").font(.callout); Slider(value: $session.state.styleGrain, in: 0...1)
    }

    private func tile(_ img: CGImage?, _ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Rectangle().fill(Color(white: 0.2)).aspectRatio(1, contentMode: .fit)
                    .overlay { if let img { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill) } }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
                Text(title).font(.caption).lineLimit(1)
            }
        }.buttonStyle(.plain)
    }

    // MARK: Zuschneiden

    @ViewBuilder private var crop: some View {
        HStack {
            Button { session.state.angle = (session.state.angle + 270) % 360 } label: { Label("Rotate", systemImage: "rotate.left") }
            Button { session.state.mirrored.toggle() } label: { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
        }
        Text("Straighten \(String(format: "%.1f", session.state.straighten))°").font(.callout)
        HStack {
            Slider(value: $session.state.straighten, in: -45...45)
            Button("Auto") { Task { if let a = await session.suggestedStraighten() { session.state.straighten = a } } }
        }
        Text("Vertical").font(.callout); Slider(value: $session.state.perspV, in: -1...1)
        Text("Horizontal").font(.callout); Slider(value: $session.state.perspH, in: -1...1)
        Divider()
        Text("Aspect Ratio").font(.callout)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
            ForEach(Aspect.allCases, id: \.self) { a in Button(a.rawValue) { apply(a) } }
        }
    }

    enum Aspect: String, CaseIterable { case free = "Freeform", square = "Square", r169 = "16:9", r43 = "4:3", r32 = "3:2", r916 = "9:16", r45 = "4:5" }

    /// Größtmöglicher Ausschnitt im gewünschten Format, mittig (wie „Seitenverhältnis“ bei Apple).
    private func apply(_ a: Aspect) {
        guard let img = session.fullPreview?.cgImage else { return }
        let ratio: Double? = switch a {
        case .free: nil; case .square: 1; case .r169: 16.0 / 9; case .r43: 4.0 / 3; case .r32: 3.0 / 2; case .r916: 9.0 / 16; case .r45: 4.0 / 5
        }
        guard let r = ratio else { session.state.crop = EditState.unit; return }
        let A = Double(img.width) / Double(img.height)
        let (w, h) = r < A ? (r / A, 1.0) : (1.0, A / r)
        session.state.displayCrop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}


// MARK: - Zuschnittrahmen, Pinsel, Kurven

/// Rechteck, in dem ein Bild mit „fit“ liegt.
private func fitted(_ img: CGImage, in size: CGSize) -> CGRect {
    let a = CGFloat(img.width) / CGFloat(img.height)
    let w = min(size.width, size.height * a), h = w / a
    return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
}

/// Zuschneiden wie Fotos: Rahmen mit Ecken zum Ziehen, Fläche verschieben, Drittel-Raster; außen abgedunkelt.
struct CropCanvas: View {
    let image: CGImage
    @Binding var rect: CGRect          // normiert 0…1, Ursprung oben links (EditState.displayCrop)
    @State private var start: CGRect?

    var body: some View {
        GeometryReader { g in
            let f = fitted(image, in: g.size)
            let r = CGRect(x: f.minX + rect.minX * f.width, y: f.minY + rect.minY * f.height,
                           width: rect.width * f.width, height: rect.height * f.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
                Path { p in p.addRect(CGRect(origin: .zero, size: g.size)); p.addRect(r) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }.stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { v in move(v, f) }.onEnded { _ in start = nil })
                ForEach(0..<4, id: \.self) { c in
                    let px = c % 2 == 0 ? r.minX : r.maxX, py = c < 2 ? r.minY : r.maxY
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 14, height: 14)
                        .offset(x: px - 7, y: py - 7)
                        .gesture(DragGesture().onChanged { v in corner(c, v, f) }.onEnded { _ in start = nil })
                }
            }
        }
    }

    private func move(_ v: DragGesture.Value, _ f: CGRect) {
        if start == nil { start = rect }
        guard let s = start else { return }
        var n = s.offsetBy(dx: v.translation.width / f.width, dy: v.translation.height / f.height)
        n.origin.x = min(max(0, n.minX), 1 - n.width); n.origin.y = min(max(0, n.minY), 1 - n.height)
        rect = n
    }

    private func corner(_ c: Int, _ v: DragGesture.Value, _ f: CGRect) {
        if start == nil { start = rect }
        guard let s = start else { return }
        let dx = v.translation.width / f.width, dy = v.translation.height / f.height, minSide = 0.05
        var x0 = s.minX, y0 = s.minY, x1 = s.maxX, y1 = s.maxY
        if c % 2 == 0 { x0 = min(max(0, x0 + dx), x1 - minSide) } else { x1 = max(min(1, x1 + dx), x0 + minSide) }
        if c < 2 { y0 = min(max(0, y0 + dy), y1 - minSide) } else { y1 = max(min(1, y1 + dy), y0 + minSide) }
        rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Malen über dem unbearbeiteten Bild; ein Strich = eine Bereinigung (Punkte normiert, oben links).
struct BrushCanvas: View {
    let image: CGImage
    let width: Double
    let onStroke: (CleanStroke) -> Void
    @State private var points: [CGPoint] = []

    var body: some View {
        GeometryReader { g in
            let f = fitted(image, in: g.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: f.minX + first.x * f.width, y: f.minY + first.y * f.height))
                    for q in points.dropFirst() { p.addLine(to: CGPoint(x: f.minX + q.x * f.width, y: f.minY + q.y * f.height)) }
                }.stroke(Color.red.opacity(0.5), style: StrokeStyle(lineWidth: width * f.width, lineCap: .round, lineJoin: .round))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let p = CGPoint(x: (v.location.x - f.minX) / f.width, y: (v.location.y - f.minY) / f.height)
                    if (0...1).contains(p.x) && (0...1).contains(p.y) { points.append(p) }
                }
                .onEnded { _ in
                    if !points.isEmpty { onStroke(CleanStroke(points: points, width: width)) }
                    points = []
                })
        }
    }
}

/// Kurve mit fünf Punkten (Eingabe 0, ¼, ½, ¾, 1), Punkte senkrecht ziehen.
struct CurveEditor: View {
    @Binding var values: [Double]
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let pts = values.enumerated().map { CGPoint(x: CGFloat($0.offset) / 4 * w, y: (1 - CGFloat($0.element)) * h) }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12))
                Path { p in
                    for i in 1...3 {
                        p.move(to: CGPoint(x: w * CGFloat(i) / 4, y: 0)); p.addLine(to: CGPoint(x: w * CGFloat(i) / 4, y: h))
                        p.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 4)); p.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 4))
                    }
                }.stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                Path { p in p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w, y: 0)) }
                    .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Path { p in p.addLines(pts) }.stroke(Color.white, lineWidth: 1.5)
                ForEach(0..<5, id: \.self) { i in
                    Circle().fill(.white).frame(width: 12, height: 12)
                        .offset(x: pts[i].x - 6, y: pts[i].y - 6)
                        .gesture(DragGesture(coordinateSpace: .named("kurve")).onChanged { v in
                            values[i] = Double(min(1, max(0, 1 - v.location.y / h)))
                        })
                }
            }
            .coordinateSpace(name: "kurve")
        }
    }
}
