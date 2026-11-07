import AppKit
import MapKit
import SwiftUI

/// Schwebendes Info-Fenster wie in Fotos (⌘I): folgt der Auswahl, auch für mehrere Objekte.
@MainActor
enum InfoWindow {
    private static var panel: NSPanel?

    static func show() {
        if let p = panel { p.isVisible ? p.orderOut(nil) : p.orderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "Info"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: InfoView(lib: Library.shared))
        p.setFrameAutosaveName("FotosInfo")
        if p.frame.origin == .zero, let main = NSApp.mainWindow {
            p.setFrameTopLeftPoint(NSPoint(x: main.frame.maxX - 320, y: main.frame.maxY - 80))
        }
        panel = p
        p.orderFront(nil)
    }
}

struct InfoView: View {
    @Bindable var lib: Library
    @State private var dto: AssetDTO?
    @State private var albums: [AlbumDTO] = []
    @State private var caption = ""
    @State private var loadedID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let sel = lib.targets
                if sel.count > 1 { multi(sel) }
                else if let a = lib.focused ?? sel.first { single(a) }
                else { Text("No Selection").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40) }
            }
            .padding(14)
        }
        .frame(minWidth: 260, minHeight: 300)
        .task(id: lib.focused?.id) { await load() }
    }

    @ViewBuilder private func single(_ a: Asset) -> some View {
        let w = AccountStore.shared.canWrite
        TextField("Add a Caption", text: $caption, axis: .vertical)
            .textFieldStyle(.plain).font(.title3).lineLimit(1...4)
            .disabled(!w)
            .onSubmit { Task { await saveCaption(a) } }
        HStack {
            Text(Fmt.fullDate.string(from: a.date) + "  " + Fmt.time.string(from: a.date))
            Spacer()
            Button { Task { await lib.toggleFavorite() } } label: { Image(systemName: a.isFavorite ? "heart.fill" : "heart") }
                .buttonStyle(.borderless).disabled(!w).help("Favorite")
        }.font(.callout)
        if let d = dto {
            Divider()
            row("doc", d.originalFileName ?? "–")
            if let e = d.exifInfo {
                let cam = [e.make, e.model].compactMap { $0 }.joined(separator: " ")
                if !cam.isEmpty { row("camera", cam) }
                if let l = e.lensModel { row("camera.aperture", l) }
                let exp = [e.fNumber.map { String(format: "ƒ%.1f", $0) }, e.exposureTime.map { "\($0) s" },
                           e.focalLength.map { String(format: "%.0f mm", $0) }, e.iso.map { "ISO \(Int($0))" }].compactMap { $0 }
                if !exp.isEmpty { row("dial.low", exp.joined(separator: "   ")) }
                if let size = sizeText(d, e) { row("aspectratio", size) }
                if let lat = e.latitude, let lon = e.longitude {
                    Divider()
                    let place = [e.city, e.state, e.country].compactMap { $0 }.joined(separator: ", ")
                    if !place.isEmpty { row("mappin.and.ellipse", place) }
                    Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                                                    latitudinalMeters: 4000, longitudinalMeters: 4000))) {
                        Marker("", coordinate: .init(latitude: lat, longitude: lon))
                    }
                    .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            if let p = d.people?.filter({ !$0.name.isEmpty }), !p.isEmpty {
                Divider()
                row("person.2", p.map(\.name).joined(separator: ", "))
            }
            if !albums.isEmpty {
                Divider()
                row("rectangle.stack", albums.map(\.albumName).joined(separator: ", "))
            }
        } else { ProgressView().frame(maxWidth: .infinity) }
    }

    @ViewBuilder private func multi(_ sel: [Asset]) -> some View {
        Text(itemsText(sel.count)).font(.title3)
        if let f = sel.first?.date, let l = sel.last?.date {
            Text(Fmt.dayLongMonthYear.string(from: f) + (Calendar.wall.isDate(f, inSameDayAs: l) ? "" : " – " + Fmt.dayLongMonthYear.string(from: l)))
                .font(.callout)
        }
        let v = sel.filter(\.isVideo).count
        row("photo.on.rectangle", "\(sel.count - v == 1 ? "1 photo" : "\(sel.count - v) photos"), \(v == 1 ? "1 video" : "\(v) videos")")
        row("heart", { let f = sel.filter(\.isFavorite).count; return f == 1 ? "1 favorite" : "\(f) favorites" }())
    }

    private func sizeText(_ d: AssetDTO, _ e: AssetDTO.ExifDTO) -> String? {
        var parts: [String] = []
        if let w = d.width ?? e.exifImageWidth, let h = d.height ?? e.exifImageHeight { parts.append("\(Int(w)) × \(Int(h))") }
        if let b = e.fileSizeInByte { parts.append(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.font(.callout)
    }

    private func load() async {
        guard let a = lib.focused else { dto = nil; return }
        if loadedID != a.id { dto = nil; albums = [] }
        loadedID = a.id
        let api = ImmichClient.shared
        guard let d = try? await api.asset(a.id), lib.focused?.id == a.id else { return }
        dto = d
        caption = d.exifInfo?.description ?? d.description ?? ""
        if let n = d.originalFileName { lib.fileNames[a.id] = n }
        albums = (try? await api.albums(containing: a.id)) ?? []
    }

    private func saveCaption(_ a: Asset) async {
        guard AccountStore.shared.canWrite else { return }
        do { try await ImmichClient.shared.raw("assets/\(a.id)", method: "PUT", body: ImmichClient.shared.json(["description": caption])) }
        catch { lib.error = error.localizedDescription }
    }
}
