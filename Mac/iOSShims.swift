import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Kleine Übersetzungen der iPhone-Bausteine, die der geteilte Editor-Kern (App/Editor/EditModel.swift) benutzt.
// So rechnet der Mac exakt wie das iPhone und speichert denselben Bearbeitungsstand („fotos.edit“).

/// Nur das, was EditModel braucht: Bild halten, Größe, JPEG/PNG.
final class UIImage: @unchecked Sendable {
    let cgImage: CGImage?
    init(cgImage: CGImage) { self.cgImage = cgImage }
    var size: CGSize { CGSize(width: cgImage?.width ?? 0, height: cgImage?.height ?? 0) }

    func jpegData(compressionQuality q: CGFloat) -> Data? { encode(.jpeg, quality: q) }
    func pngData() -> Data? { encode(.png, quality: nil) }

    private func encode(_ t: UTType, quality: CGFloat?) -> Data? {
        guard let cgImage else { return nil }
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, t.identifier as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }
}

struct UIColor {
    let cgColor: CGColor
    static let black = UIColor(cgColor: CGColor(gray: 0, alpha: 1))
    static let white = UIColor(cgColor: CGColor(gray: 1, alpha: 1))
    func setFill() { UIGraphicsImageRendererContext.current?.cgContext.setFillColor(cgColor) }
}

final class UIGraphicsImageRendererFormat {
    var scale: CGFloat = 1
    var opaque = false
}

final class UIGraphicsImageRendererContext {
    nonisolated(unsafe) static var current: UIGraphicsImageRendererContext?
    let cgContext: CGContext
    init(_ c: CGContext) { cgContext = c }
    func fill(_ r: CGRect) { cgContext.fill(r) }
}

/// Zeichnet wie UIKit mit Ursprung oben links.
final class UIGraphicsImageRenderer {
    let size: CGSize
    init(size: CGSize, format: UIGraphicsImageRendererFormat) { self.size = size }

    func image(_ actions: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        let c = UIGraphicsImageRendererContext(ctx)
        UIGraphicsImageRendererContext.current = c
        actions(c)
        UIGraphicsImageRendererContext.current = nil
        return UIImage(cgImage: ctx.makeImage()!)
    }
}

/// Live-Video eines Live Photos als lokale Datei (Schlüsselbild wählen im Editor).
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
}

/// Nur damit EditClipboard.paste/copy (iPhone-Wege) übersetzt; der Mac nutzt eigene Abläufe (Library.pasteEdits).
@MainActor final class AppModel {
    var busy: String?
    func toast(_ s: String) {}
}
@MainActor final class TimelineStore {
    func reload() async {}
}
