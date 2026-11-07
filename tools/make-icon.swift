// Erzeugt das App-Symbol (HomeRoll-Motiv auf einem Bildschirm) in allen Größen:
//   swift tools/make-icon.swift Mac/Assets.xcassets/AppIcon.appiconset
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    // macOS-Raster: Form 824×824 mit Rand 100, abgerundet
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0x1B2233)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x2A3550), rgb(0x141A28)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    // Standfuß
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 462, y: 312)); neck.addLine(to: CGPoint(x: 562, y: 312))
    neck.addLine(to: CGPoint(x: 590, y: 220)); neck.addLine(to: CGPoint(x: 434, y: 220)); neck.closeSubpath()
    ctx.addPath(neck); ctx.setFillColor(rgb(0xC9D2E3)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 372, y: 196, width: 280, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
    ctx.setFillColor(rgb(0xE4EAF4)); ctx.fillPath()
    // Bildschirm: Rahmen + HomeRoll-Motiv
    let frame = CGRect(x: 196, y: 300, width: 632, height: 470)
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setFillColor(rgb(0xE4EAF4)); ctx.fillPath()
    let screen = frame.insetBy(dx: 22, dy: 22)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 26, cornerHeight: 26, transform: nil)
    ctx.saveGState()
    ctx.addPath(screenPath); ctx.clip()
    let sky = CGGradient(colorsSpace: nil, colors: [rgb(0x2F6FEB), rgb(0x1FB6E8)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: screen.maxY), end: CGPoint(x: 0, y: screen.minY), options: [])
    ctx.addEllipse(in: CGRect(x: screen.minX + 375, y: screen.minY + 255, width: 110, height: 110))
    ctx.setFillColor(rgb(0xFFD86B)); ctx.fillPath()
    let back = CGMutablePath()
    back.move(to: CGPoint(x: screen.minX + 230, y: screen.minY)); back.addLine(to: CGPoint(x: screen.minX + 440, y: screen.minY + 215))
    back.addLine(to: CGPoint(x: screen.maxX + 20, y: screen.minY + 120)); back.addLine(to: CGPoint(x: screen.maxX + 20, y: screen.minY)); back.closeSubpath()
    ctx.addPath(back); ctx.setFillColor(rgb(0x9FD8F7)); ctx.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: screen.minX - 20, y: screen.minY)); front.addLine(to: CGPoint(x: screen.minX - 20, y: screen.minY + 40))
    front.addLine(to: CGPoint(x: screen.minX + 185, y: screen.minY + 230)); front.addLine(to: CGPoint(x: screen.minX + 330, y: screen.minY + 110))
    front.addLine(to: CGPoint(x: screen.minX + 420, y: screen.minY + 165)); front.addLine(to: CGPoint(x: screen.maxX + 20, y: screen.minY - 10)); front.closeSubpath()
    ctx.addPath(front); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = render(CGFloat(pt * scale))
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(pt)x\(pt)@\(scale)x.png"))
}
print("Symbol geschrieben nach \(out.path)")
