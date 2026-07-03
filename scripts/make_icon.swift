// Generates LocalFlow's app icon as a full .iconset of PNGs.
// Draws a rounded-square (macOS "squircle") with a blue→indigo gradient, a
// soft contact shadow, a gentle top sheen, and a centered white waveform glyph.
// Run: swift scripts/make_icon.swift <output.iconset-dir>
// Then: iconutil -c icns <dir> -o Resources/AppIcon.icns
import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dist/LocalFlow.iconset"

let topColor = NSColor(srgbRed: 0.18, green: 0.42, blue: 0.90, alpha: 1.0)      // blue
let bottomColor = NSColor(srgbRed: 0.42, green: 0.25, blue: 0.84, alpha: 1.0)   // indigo

func tintedWhite(_ image: NSImage) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func drawIcon(px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let W = CGFloat(px)
    let inset = W * 0.098
    let body = NSRect(x: inset, y: inset, width: W - 2 * inset, height: W - 2 * inset)
    let radius = body.width * 0.2237
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Soft contact shadow cast by the squircle.
    NSGraphicsContext.saveGraphicsState()
    let contact = NSShadow()
    contact.shadowColor = NSColor.black.withAlphaComponent(0.28)
    contact.shadowBlurRadius = W * 0.03
    contact.shadowOffset = NSSize(width: 0, height: -W * 0.012)
    contact.set()
    NSColor.black.setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gradient body.
    if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
        gradient.draw(in: bodyPath, angle: -90)
    }

    // Gentle top sheen for a bit of gloss.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    let sheenRect = NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2)
    if let sheen = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.18),
        ending: NSColor.white.withAlphaComponent(0.0)
    ) {
        sheen.draw(in: sheenRect, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Centered white waveform glyph with a soft shadow.
    let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.5, weight: .semibold)
    if let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let glyphImage = tintedWhite(base)
        let glyphH = body.height * 0.5
        let aspect = base.size.width / max(base.size.height, 1)
        let glyphW = glyphH * aspect
        let glyphRect = NSRect(
            x: body.midX - glyphW / 2,
            y: body.midY - glyphH / 2,
            width: glyphW, height: glyphH
        )
        NSGraphicsContext.saveGraphicsState()
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        glyphShadow.shadowBlurRadius = W * 0.015
        glyphShadow.shadowOffset = NSSize(width: 0, height: -W * 0.006)
        glyphShadow.set()
        glyphImage.draw(in: glyphRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for entry in sizes {
    guard let data = drawIcon(px: entry.px) else {
        FileHandle.standardError.write("failed to render \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let path = (outDir as NSString).appendingPathComponent(entry.name)
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(entry.name) (\(entry.px)px)")
}
print("iconset ready: \(outDir)")
