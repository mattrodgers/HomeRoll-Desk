import AppKit
import AVFoundation
import SwiftUI

// MARK: - Eigene Rückblicke (HomeRoll-Desk #14)

/// Selbst erstellter Rückblick wie in der iPhone-App: Titel, Fotos in eigener Reihenfolge, Musik.
/// Gespeichert je Konto auf dem Mac (wie intelligente Alben); die Fotos selbst bleiben auf dem Server.
struct MyMemory: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title: String
    var assetIDs: [String]
    var mood = MemoryMood.gentle.rawValue
}

@MainActor @Observable
final class MyMemories {
    static let shared = MyMemories()
    private(set) var items: [MyMemory] = []
    private var key: String { "mac.memories.\(AccountStore.shared.currentID ?? "-")" }

    init() { reload() }
    func reload() {
        items = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([MyMemory].self, from: $0) } ?? []
    }
    func memory(_ id: String) -> MyMemory? { items.first { $0.id == id } }

    func save(_ m: MyMemory) {
        if let i = items.firstIndex(where: { $0.id == m.id }) { items[i] = m } else { items.insert(m, at: 0) }
        persist()
    }
    func update(_ id: String, _ change: (inout MyMemory) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i]); persist()
    }
    func delete(_ id: String) { items.removeAll { $0.id == id }; persist() }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key) }

    /// Fotos hinten anhängen (schon enthaltene bleiben an ihrem Platz).
    func add(_ ids: [String], to id: String) {
        update(id) { m in m.assetIDs += ids.filter { !m.assetIDs.contains($0) } }
    }
    func remove(_ ids: Set<String>, from id: String) { update(id) { $0.assetIDs.removeAll { ids.contains($0) } } }

    /// Ausgewählte an die Stelle `index` (Position in der alten Liste) verschieben, Reihenfolge untereinander bleibt.
    func move(_ ids: [String], to index: Int, in id: String) {
        update(id) { m in
            let set = Set(ids)
            let moving = m.assetIDs.filter { set.contains($0) }
            let before = m.assetIDs.prefix(max(0, min(index, m.assetIDs.count))).filter { !set.contains($0) }.count
            m.assetIDs.removeAll { set.contains($0) }
            m.assetIDs.insert(contentsOf: moving, at: min(before, m.assetIDs.count))
        }
    }
    /// Eine Stelle früher (-1) oder später (+1).
    func shift(_ ids: [String], by d: Int, in id: String) {
        guard let m = memory(id) else { return }
        let set = Set(ids)
        let positions = m.assetIDs.enumerated().filter { set.contains($0.element) }.map(\.offset)
        guard let first = positions.first, let last = positions.last else { return }
        move(ids, to: d < 0 ? max(0, first - 1) : min(m.assetIDs.count, last + 2), in: id)
    }

    /// Objekte zu den gespeicherten IDs vom Server (gelöschte fallen weg), in der gespeicherten Reihenfolge.
    static func assets(_ ids: [String]) async -> [Asset] {
        var found: [String: Asset] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 12).map({ Array(ids[$0..<min(ids.count, $0 + 12)]) }) {
            await withTaskGroup(of: Asset?.self) { g in
                for id in chunk {
                    g.addTask {
                        guard let d = try? await ImmichClient.shared.asset(id), d.isTrashed != true else { return nil }
                        return d.asset
                    }
                }
                for await a in g { if let a { found[a.id] = a } }
            }
        }
        return ids.compactMap { found[$0] }
    }

    // MARK: Anlegen

    /// „Rückblick erstellen“ aus der Auswahl (Rechtsklick auf Fotos).
    static func create(from assets: [Asset], lib: Library) {
        guard assets.count >= 3 else { lib.error = "A memory needs at least 3 photos."; return }
        let first = assets.map(\.date).min() ?? Date()
        let suggestion = assets.first(where: { $0.city != nil })?.city ?? Fmt.monthYear.string(from: first)
        guard let title = Menus.ask("New Memory", info: "New memory with \(itemsText(assets.count))", value: suggestion) else { return }
        let m = MyMemory(title: title, assetIDs: assets.sorted { $0.date < $1.date }.map(\.id))
        shared.save(m)
        lib.open(.myMemory(m.id, m.title))
    }
}

// MARK: - „Neuer Rückblick“ aus einem Zeitraum

struct NewMemoryEditor: View {
    let onDone: (MyMemory?) -> Void
    @State private var title = ""
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var to = Date()
    @State private var person = ""
    @State private var people: [PersonDTO] = []
    @State private var count: Int?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).font(.title3)
            HStack {
                Text("Photos taken from")
                DatePicker("", selection: $from, displayedComponents: .date).labelsHidden()
                Text("to")
                DatePicker("", selection: $to, displayedComponents: .date).labelsHidden()
            }
            Picker("With", selection: $person) {
                Text("Anyone").tag("")
                ForEach(people) { Text($0.name).tag($0.id) }
            }.frame(width: 320)
            Text("Up to 120 photos are picked evenly from this time. You can add, remove and reorder them afterwards.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let count { Text(count == 0 ? "No photos in this time" : "\(itemsText(count)) found").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || count == 0 || busy)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { people = ((try? await ImmichClient.shared.people()) ?? []).filter { !$0.name.isEmpty } }
        .task(id: "\(from)\(to)\(person)") {
            try? await Task.sleep(for: .milliseconds(300))
            count = await fetch().count
        }
    }

    private var filter: [String: Any] {
        let iso = ISO8601DateFormatter()
        var f: [String: Any] = ["takenAt": ["gte": iso.string(from: Calendar.current.startOfDay(for: min(from, to))),
                                            "lt": iso.string(from: Calendar.current.startOfDay(for: max(from, to)).addingTimeInterval(86400))]]
        if !person.isEmpty { f["personIds"] = ["any": [person]] }
        return f
    }

    private func fetch() async -> [Asset] {
        ((try? await ImmichClient.shared.search(filter: filter, size: 5000, order: "asc")) ?? []).map(\.asset)
    }

    private func create() async {
        busy = true; defer { busy = false }
        let all = await fetch().sorted { $0.date < $1.date }
        guard !all.isEmpty else { count = 0; return }
        // gleichmäßig über den Zeitraum verteilt, höchstens 120
        let n = min(120, all.count)
        let picked = (0..<n).map { all[Int((Double($0) + 0.5) * Double(all.count) / Double(n))] }
        onDone(MyMemory(title: title.trimmingCharacters(in: .whitespaces), assetIDs: picked.map(\.id)))
    }
}

@MainActor
enum NewMemoryWindow {
    private static var window: NSWindow?
    static func show(_ lib: Library) {
        window?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "New Memory"
        w.contentView = NSHostingView(rootView: NewMemoryEditor { m in
            if let m { MyMemories.shared.save(m); lib.open(.myMemory(m.id, m.title)) }
            window?.close(); window = nil
        })
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

/// Rechtsklick auf einen eigenen Rückblick (Übersicht).
struct MyMemoryContextMenu: View {
    let m: MyMemory
    @Bindable var lib: Library
    var body: some View {
        Button("Play") { Task { await lib.play(.myMemory(m.id, m.title)) } }
        Button("Rename…") {
            if let n = Menus.ask("Rename Memory", info: m.title, value: m.title) {
                MyMemories.shared.update(m.id) { $0.title = n }
            }
        }
        Divider()
        Button("Delete Memory…") {
            let al = NSAlert()
            al.messageText = "Delete memory “\(m.title)”?"
            al.informativeText = "The photos remain in your library."
            al.addButton(withTitle: "Delete"); al.addButton(withTitle: "Cancel")
            if al.runModal() == .alertFirstButtonReturn { MyMemories.shared.delete(m.id) }
        }
    }
}

// MARK: - Abspielen

/// Was gerade abgespielt wird.
struct MemoryShow: Equatable {
    let title: String
    let subtitle: String
    let assets: [Asset]
    var mood: MemoryMood
    /// eigener Rückblick: gewählte Musik merken
    let myID: String?
}

/// Rückblick als Film im Fenster: Titel, Fotos mit langsamer Kamerafahrt und Überblendung, Musik.
/// Leertaste = Pause, ←/→ = vor/zurück, Esc = schließen.
struct MemoryPlayerView: View {
    @Bindable var lib: Library
    @State var show: MemoryShow
    @State private var index = 0
    @State private var playing = true
    @State private var images: [String: CGImage] = [:]
    @State private var hover = false
    @State private var music = MemoryMusic()
    @FocusState private var focused: Bool
    private let perSlide: Double = 3.4

    var body: some View {
        ZStack {
            Color.black
            if let a = current {
                Slide(image: images[a.id], index: index, duration: perSlide + 1.2)
                    .id(a.id)
                    .transition(.opacity)
            }
            if index == 0 {
                VStack(spacing: 6) {
                    Text(show.title).font(.system(size: 44, weight: .bold))
                    if !show.subtitle.isEmpty { Text(show.subtitle).font(.title3.weight(.semibold)).opacity(0.85) }
                }
                .foregroundStyle(.white).shadow(radius: 12)
                .transition(.opacity)
            }
            if ended {
                VStack(spacing: 14) {
                    Text(show.title).font(.title.bold()).foregroundStyle(.white)
                    HStack {
                        Button { index = 0; playing = true; music.play(show.mood) } label: { Label("Play Again", systemImage: "arrow.counterclockwise") }
                        Button { close() } label: { Label("Close", systemImage: "xmark") }
                    }.controlSize(.large)
                }
                .padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .overlay(alignment: .bottom) { if hover || !playing { controls.transition(.opacity) } }
        .animation(.easeInOut(duration: 1.0), value: index)
        .animation(.easeOut(duration: 0.2), value: hover)
        .onHover { hover = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) { toggle(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear { focused = true; music.play(show.mood) }
        .onDisappear { music.stop() }
        .task(id: index) { await preload() }
        .task(id: "\(index)\(playing)") {
            guard playing, !ended else { return }
            try? await Task.sleep(for: .seconds(index == 0 ? perSlide + 1 : perSlide))
            guard !Task.isCancelled, playing else { return }
            if index + 1 < show.assets.count { index += 1 } else { playing = false; index = show.assets.count; music.stop() }
        }
    }

    private var current: Asset? { show.assets.indices.contains(index) ? show.assets[index] : show.assets.last }
    private var ended: Bool { index >= show.assets.count }

    private var controls: some View {
        HStack(spacing: 18) {
            Button { step(-1) } label: { Image(systemName: "backward.fill") }.help("Previous (←)")
            Button { toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }.help("Play/Pause (Space)")
            Button { step(1) } label: { Image(systemName: "forward.fill") }.help("Next (→)")
            Text("\(min(index + 1, show.assets.count)) / \(show.assets.count)").monospacedDigit().foregroundStyle(.secondary)
            Menu {
                ForEach(MemoryMood.allCases) { m in
                    Button { setMood(m) } label: {
                        if m == show.mood { Label(m.title, systemImage: "checkmark") } else { Label(m.title, systemImage: m.icon) }
                    }
                }
            } label: { Label(show.mood.title, systemImage: show.mood.icon) }
                .menuStyle(.borderlessButton).fixedSize().help("Music")
            Button { close() } label: { Image(systemName: "xmark") }.help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 28)
    }

    private func toggle() {
        if ended { index = 0; playing = true; music.play(show.mood); return }
        playing.toggle()
        if playing { music.resume() } else { music.pause() }
    }
    private func step(_ d: Int) {
        let n = show.assets.count
        guard n > 0 else { return }
        index = max(0, min(n - 1, min(index, n - 1) + d))
    }
    private func setMood(_ m: MemoryMood) {
        show.mood = m
        if let id = show.myID { MyMemories.shared.update(id) { $0.mood = m.rawValue } }
        if playing { music.play(m) } else { music.stop() }
    }
    private func close() { music.stop(); lib.playing = nil }

    /// aktuelles und nächstes Foto in Bildschirmgröße holen
    private func preload() async {
        for i in index...min(index + 2, max(0, show.assets.count - 1)) where show.assets.indices.contains(i) {
            let id = show.assets[i].id
            if images[id] == nil, let img = await ImageCache.shared.load(id, .preview) { images[id] = img }
        }
        if images.count > 12 {
            let keep = Set(show.assets[max(0, index - 1)..<min(show.assets.count, index + 3)].map(\.id))
            images = images.filter { keep.contains($0.key) }
        }
    }
}

/// Ein Foto mit langsamer Kamerafahrt (Ken Burns), Richtung wechselt je Foto.
private struct Slide: View {
    let image: CGImage?
    let index: Int
    let duration: Double
    @State private var moved = false

    var body: some View {
        GeometryReader { geo in
            if let image {
                let dir: CGFloat = index.isMultiple(of: 2) ? 1 : -1
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(moved ? 1.12 : 1.02)
                    .offset(x: moved ? dir * geo.size.width * 0.025 : -dir * geo.size.width * 0.02,
                            y: moved ? -dir * geo.size.height * 0.015 : 0)
                    .clipped()
                    .onAppear { withAnimation(.linear(duration: duration)) { moved = true } }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Musik (gleicher Synthesizer wie in der iPhone-App: keine Musikdateien, keine Lizenzen)

enum MemoryMood: Int, CaseIterable, Identifiable {
    case none, gentle, happy, thoughtful, epic
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: "No Music"; case .gentle: "Gentle"; case .happy: "Happy"
        case .thoughtful: "Thoughtful"; case .epic: "Epic"
        }
    }
    var icon: String {
        switch self {
        case .none: "speaker.slash"; case .gentle: "leaf"; case .happy: "sun.max"
        case .thoughtful: "cloud.drizzle"; case .epic: "mountain.2"
        }
    }
}

final class MemoryMusic: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let synth = Synth()

    func play(_ mood: MemoryMood) {
        stop()
        guard mood != .none else { return }
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        synth.configure(mood, sampleRate: sr > 0 ? sr : 44100)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: synth.sr, channels: 2)!
        let s = synth
        let n = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            s.render(Int(frames), UnsafeMutableAudioBufferListPointer(abl)); return noErr
        }
        node = n
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.9
        try? engine.start()
    }
    func pause() { synth.paused = true }
    func resume() { synth.paused = false }
    func stop() {
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
    }
}

final class Synth: @unchecked Sendable {
    var sr: Double = 44100
    var paused = false
    private var t: Int = 0
    private var gain: Double = 0
    private var lp: Double = 0
    private var bpm: Double = 72
    private var chords: [[Double]] = []
    private var pattern: [Int] = [0, 1, 2, 1]
    private var stepsPerBeat: Double = 1
    private var padLevel = 0.05, bellLevel = 0.11, bassLevel = 0.07, bright = 0.25

    func configure(_ mood: MemoryMood, sampleRate: Double) {
        sr = sampleRate; t = 0; gain = 0; lp = 0; paused = false
        padLevel = 0.05; bellLevel = 0.11; bassLevel = 0.07; bright = 0.25
        switch mood {
        case .gentle:
            bpm = 72; stepsPerBeat = 1; pattern = [0, 1, 2, 1]
            chords = [[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]]
        case .happy:
            bpm = 112; stepsPerBeat = 2; pattern = [0, 1, 2, 1, 0, 2, 1, 2]; padLevel = 0.035; bellLevel = 0.09; bright = 0.45
            chords = [[55, 59, 62], [52, 55, 59], [48, 52, 55], [50, 54, 57]]
        case .thoughtful:
            bpm = 64; stepsPerBeat = 1; pattern = [0, 2, 1, 2]; bright = 0.18
            chords = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
        case .epic:
            bpm = 80; stepsPerBeat = 2; pattern = [0, 1, 2, 1, 0, 1, 2, 1]; padLevel = 0.07; bassLevel = 0.11; bright = 0.3
            chords = [[50, 53, 57], [46, 50, 53], [48, 52, 55], [45, 49, 52]]
        case .none: chords = [[60, 64, 67]]
        }
    }

    private func hz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

    func render(_ frames: Int, _ abl: UnsafeMutableAudioBufferListPointer) {
        let twoPi = 2 * Double.pi
        let beatLen = 60 / bpm, segLen = beatLen * 8          // Akkordwechsel alle 2 Takte
        let stepLen = beatLen / stepsPerBeat
        for f in 0..<frames {
            var v = 0.0
            if !paused {
                let time = Double(t) / sr
                let seg = Int(time / segLen), inSeg = time - Double(seg) * segLen
                let chord = chords[seg % chords.count]
                // Fläche: weich ein-/ausblenden je Akkord, leicht verstimmte Sinus-Paare
                let padEnv = min(1, inSeg / 0.8) * min(1, (segLen - inSeg) / 0.6)
                for m in chord {
                    let fr = hz(m)
                    v += padLevel * padEnv * (sin(twoPi * fr * time) + 0.6 * sin(twoPi * fr * 1.003 * time)) * 0.6
                }
                // Glocken-Arpeggio
                let step = Int(time / stepLen), inStep = time - Double(step) * stepLen
                let note = chord[pattern[step % pattern.count] % chord.count] + 12
                let env = min(1, inStep / 0.006) * exp(-inStep * 3.2)
                let bf = hz(note)
                v += bellLevel * env * (sin(twoPi * bf * inStep) + bright * sin(twoPi * bf * 2 * inStep))
                // Bass auf jedem Takt
                let bar = Int(time / (beatLen * 4)), inBar = time - Double(bar) * beatLen * 4
                let benv = min(1, inBar / 0.02) * exp(-inBar * 0.9)
                v += bassLevel * benv * sin(twoPi * hz(chord[0] - 12) * time)
                t += 1
            }
            // sanft starten/anhalten, dann leichter Tiefpass gegen Härte
            gain += ((paused ? 0 : 1) - gain) * 0.00005
            lp += (v * gain - lp) * 0.35
            let out = Float(max(-1, min(1, lp)))
            for b in 0..<abl.count { abl[b].mData?.assumingMemoryBound(to: Float.self)[f] = out }
        }
    }
}
