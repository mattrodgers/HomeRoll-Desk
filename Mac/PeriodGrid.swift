import SwiftUI

/// „Jahre“ und „Monate“ der Mediathek wie in Fotos: große Kacheln mit einem Foto des Zeitraums;
/// Klick springt in „Alle Fotos“ an diese Stelle.
struct PeriodGrid: View {
    @Bindable var lib: Library
    let years: Bool

    struct Period: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let section: Int          // Monat, dessen Foto gezeigt und angesprungen wird
    }

    private var periods: [Period] {
        let secs = lib.sections
        if !years {
            return secs.indices.reversed().map { i in
                Period(id: secs[i].id, title: secs[i].title, subtitle: itemsText(secs[i].count), section: i)
            }
        }
        var byYear: [String: [Int]] = [:]
        for i in secs.indices { byYear[String(secs[i].id.prefix(4)), default: []].append(i) }
        return byYear.keys.sorted(by: >).map { y in
            let idx = byYear[y]!
            let n = idx.reduce(0) { $0 + secs[$1].count }
            // Foto aus dem Monat mit den meisten Objekten (meist das Ereignis des Jahres)
            let best = idx.max { secs[$0].count < secs[$1].count } ?? idx[0]
            return Period(id: y, title: y, subtitle: itemsText(n), section: best)
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: years ? 300 : 220), spacing: 16)], spacing: 16) {
                ForEach(periods) { p in
                    Button { lib.jump(to: p.section) } label: { card(p) }.buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private func card(_ p: Period) -> some View {
        PeriodThumb(lib: lib, section: p.section)
            .frame(height: years ? 220 : 160)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(years ? .largeTitle.bold() : .title2.bold())
                    Text(p.subtitle).font(.callout)
                }
                .foregroundStyle(.white).shadow(radius: 4)
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Lädt den Monat erst, wenn die Kachel sichtbar wird, und zeigt ein Foto aus seiner Mitte.
private struct PeriodThumb: View {
    @Bindable var lib: Library
    let section: Int
    @State private var img: CGImage?

    var body: some View {
        Rectangle().fill(Color(white: 0.2))
            .overlay { if let img { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill) } }
            .overlay(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
            .clipped()
            .onAppear { lib.ensureLoaded(section) }
            .task(id: assetID) {
                guard let id = assetID else { return }
                img = ImageCache.shared.placeholder(id)
                if let i = await ImageCache.shared.load(id, .preview) { img = i }
            }
    }

    private var assetID: String? {
        guard lib.sections.indices.contains(section), let a = lib.sections[section].assets, !a.isEmpty else { return nil }
        let photos = a.filter(\.isImage)
        let pool = photos.isEmpty ? a : photos
        return pool[pool.count / 2].id
    }
}
