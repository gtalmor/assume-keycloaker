// Renders AppIcon.iconset: `swift packaging/make-icon.swift build/AppIcon.iconset`
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.47, blue: 0.52, alpha: 1),
                        NSColor(srgbRed: 0.12, green: 0.17, blue: 0.40, alpha: 1)])!
        .draw(in: squircle, angle: -70)

    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 0.11, green: 0.30, blue: 0.45, alpha: 1), .white]))
    if let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    // The "connected" light.
    let d = rect.width * 0.22
    let dot = NSRect(x: rect.maxX - d * 1.2, y: rect.minY + d * 0.2, width: d, height: d)
    NSColor(srgbRed: 0.12, green: 0.17, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot.insetBy(dx: -d * 0.1, dy: -d * 0.1)).fill()
    NSColor.systemGreen.setFill()
    NSBezierPath(ovalIn: dot).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                   ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
