// Generates light + dark iconsets in the macOS 26 minimal style:
// quiet full-bleed background, one glass-treated music note.
// Run: swift tools/gen_icon.swift <light.iconset> <dark.iconset>
//
// Full-bleed with square corners on purpose: macOS 26 masks every app icon
// into its own squircle; baking rounded corners causes a double-frame look.
import AppKit

let canvas: CGFloat = 1024

func gradientImage(size: NSSize, colors: [NSColor], angle: CGFloat) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    NSGradient(colors: colors)!.draw(in: NSRect(origin: .zero, size: size), angle: angle)
    img.unlockFocus()
    return img
}

func makeIcon(dark: Bool) -> NSImage {
    let rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
    let image = NSImage(size: rect.size)
    image.lockFocus()

    // Quiet Tahoe-style background
    let bg = dark
        ? [NSColor(calibratedRed: 0.21, green: 0.21, blue: 0.24, alpha: 1),
           NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)]
        : [NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.99, alpha: 1),
           NSColor(calibratedRed: 0.86, green: 0.87, blue: 0.92, alpha: 1)]
    NSGradient(colors: bg)!.draw(in: rect, angle: -90)

    // Music note glyph, white
    let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .medium)
    let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let glyphSize = symbol.size
    let glyphRect = NSRect(origin: .zero, size: glyphSize)

    let note = NSImage(size: glyphSize)
    note.lockFocus()
    symbol.draw(in: glyphRect)
    NSColor.white.set()
    glyphRect.fill(using: .sourceAtop)

    // Accent gradient inside the glyph
    let accent = dark
        ? [NSColor(calibratedRed: 0.55, green: 0.48, blue: 1.00, alpha: 1),
           NSColor(calibratedRed: 0.80, green: 0.45, blue: 1.00, alpha: 1),
           NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.75, alpha: 1)]
        : [NSColor(calibratedRed: 0.40, green: 0.33, blue: 0.96, alpha: 1),
           NSColor(calibratedRed: 0.66, green: 0.35, blue: 0.95, alpha: 1),
           NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.65, alpha: 1)]
    gradientImage(size: glyphSize, colors: accent, angle: 55)
        .draw(in: glyphRect, from: glyphRect, operation: .sourceIn, fraction: 1)

    // Glass treatment: specular sheen on the upper part of the glyph,
    // soft light pooling at the bottom edge.
    let sheen = gradientImage(size: NSSize(width: glyphSize.width, height: glyphSize.height * 0.5),
                              colors: [NSColor.white.withAlphaComponent(0.85),
                                       NSColor.white.withAlphaComponent(0.0)],
                              angle: -90)
    sheen.draw(in: NSRect(x: 0, y: glyphSize.height * 0.5,
                          width: glyphSize.width, height: glyphSize.height * 0.5),
               from: NSRect(origin: .zero, size: sheen.size),
               operation: .sourceAtop, fraction: 0.55)
    let pool = gradientImage(size: NSSize(width: glyphSize.width, height: glyphSize.height * 0.22),
                             colors: [NSColor.white.withAlphaComponent(0.0),
                                      NSColor.white.withAlphaComponent(0.6)],
                             angle: -90)
    pool.draw(in: NSRect(x: 0, y: 0, width: glyphSize.width, height: glyphSize.height * 0.22),
              from: NSRect(origin: .zero, size: pool.size),
              operation: .sourceAtop, fraction: 0.35)
    note.unlockFocus()

    // Drop the glass note onto the background with a soft shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    note.draw(in: NSRect(x: (canvas - glyphSize.width) / 2,
                         y: (canvas - glyphSize.height) / 2,
                         width: glyphSize.width, height: glyphSize.height))

    image.unlockFocus()
    return image
}

func writeIconset(_ image: NSImage, to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (pts, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let px = pts * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(pts)x\(pts).png" : "icon_\(pts)x\(pts)@2x.png"
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: dir + "/" + name))
    }
}

let lightOut = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Light.iconset"
let darkOut = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Dark.iconset"
writeIconset(makeIcon(dark: false), to: lightOut)
writeIconset(makeIcon(dark: true), to: darkOut)
print("iconsets written: \(lightOut), \(darkOut)")
