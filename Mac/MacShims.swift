import AppKit
import Foundation
import ImageIO

/// Mac-Gegenstück zu `ImageCache` aus RemoteImage.swift (iOS): gleiche Schnittstelle, die ImmichClient/Models nutzen
/// (`setHash`, `version`), dazu ein Speicher für fertig entpackte Bilder.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, CGImageBox>()
    private var hashes: [String: String] = [:]
    private var versions = (UserDefaults.standard.dictionary(forKey: "thumbVersions") as? [String: String]) ?? [:]
    private let lock = NSLock()
    init() { cache.totalCostLimit = 400 << 20 }

    func setHash(_ id: String, _ h: String?) {
        guard let h else { return }
        let old = lock.withLock { () -> String? in let o = hashes[id]; hashes[id] = h; return o }
        if let old, old != h { drop(id) }
    }

    /// Fingerabdruck der Server-Vorschau + eigene Fassung nach dem Drehen → neue Adresse, Zwischenspeicher umgangen.
    func version(_ id: String) -> String? {
        let (h, v) = lock.withLock { (hashes[id], versions[id]) }
        let parts = [v, h.map { String($0.prefix(10)) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    func bump(_ id: String) {
        let d = lock.withLock { versions[id] = String(Int(Date().timeIntervalSince1970)); return versions }
        UserDefaults.standard.set(d, forKey: "thumbVersions")
        drop(id)
    }

    private func drop(_ id: String) {
        for s in ["thumbnail", "preview", "fullsize"] { cache.removeObject(forKey: "\(id)-\(s)" as NSString) }
    }

    func hash(_ id: String) -> String? { lock.withLock { hashes[id] } }

    /// Unscharfes Sofortbild aus dem ThumbHash (wie Fotos vor dem echten Bild); fehlt der Hash, rechnet der
    /// Server die Vorschau noch.
    func placeholder(_ id: String) -> CGImage? {
        let key = "ph-\(id)" as NSString
        if let i = cache.object(forKey: key) { return i.image }
        guard var h = hash(id) else { return nil }
        while h.count % 4 != 0 { h += "=" }          // Immich liefert base64 ohne Auffüllung
        guard let img = ThumbHash.cgImage(base64: h) else { return nil }
        cache.setObject(CGImageBox(img), forKey: key, cost: 32 * 32 * 4)
        return img
    }

    func get(_ id: String, _ size: ImmichClient.Size) -> CGImage? { cache.object(forKey: "\(id)-\(size.rawValue)" as NSString)?.image }

    /// Speicher → Server (URLCache des Clients hält die Dateien auf der Platte). Entpacken außerhalb des Hauptthreads.
    func load(_ id: String, _ size: ImmichClient.Size) async -> CGImage? {
        if let i = get(id, size) { return i }
        guard let url = ImmichClient.shared.thumbnailURL(id, size),
              let data = try? await ImmichClient.shared.data(url) else { return nil }
        guard let img = Self.decode(data) else { return nil }
        cache.setObject(CGImageBox(img), forKey: "\(id)-\(size.rawValue)" as NSString, cost: img.bytesPerRow * img.height)
        return img
    }

    /// WebP/JPEG → fertiges Bitmap (sonst entpackt AppKit erst beim Zeichnen auf dem Hauptthread).
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 8192]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Zählwort für die Oberfläche: „1 item“ / „1,234 items“.
func itemsText(_ n: Int) -> String { n == 1 ? "1 item" : "\(n.formatted()) items" }

/// „1 extra item“ / „5 extra items“ (Duplikate).
func extraText(_ n: Int) -> String { n == 1 ? "1 extra item" : "\(n.formatted()) extra items" }

final class CGImageBox: NSObject {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}

/// Mac-Gegenstück zu `Connectivity` (iOS: OfflineStore.swift) – merkt sich nur, ob der Server zuletzt erreichbar war.
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()
    private(set) var serverOffline = false

    nonisolated static func report(_ error: Error?) {
        let offline: Bool
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
                 .dnsLookupFailed, .secureConnectionFailed: offline = true
            default: return
            }
        } else if error == nil { offline = false } else { return }
        Task { @MainActor in
            if Connectivity.shared.serverOffline != offline { Connectivity.shared.serverOffline = offline }
        }
    }
}
