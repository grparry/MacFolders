// Renders the Folders app icon — a classic Mac blue folder — into an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}

// Classic Aqua folder blues.
let backTop = color(0.35, 0.60, 0.89)
let backBottom = color(0.24, 0.46, 0.78)
let frontTop = color(0.55, 0.78, 0.98)
let frontBottom = color(0.30, 0.55, 0.90)

func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: [top, bottom] as CFArray, locations: [0, 1])!
}

func drawFolder(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024.0
    ctx.saveGState()

    // Soft drop shadow under the whole folder.
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 28 * s,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))

    // Back panel with the classic top-left tab, one path so the shadow is unified.
    let back = CGMutablePath()
    back.addRoundedRect(in: CGRect(x: 96 * s, y: 160 * s, width: 832 * s, height: 600 * s),
                        cornerWidth: 44 * s, cornerHeight: 44 * s)
    back.addRoundedRect(in: CGRect(x: 96 * s, y: 700 * s, width: 340 * s, height: 150 * s),
                        cornerWidth: 36 * s, cornerHeight: 36 * s)
    ctx.addPath(back)
    ctx.setFillColor(backBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Back-panel gradient (no shadow).
    ctx.saveGState()
    ctx.addPath(back)
    ctx.clip()
    ctx.drawLinearGradient(gradient(backTop, backBottom),
                           start: CGPoint(x: 0, y: 850 * s),
                           end: CGPoint(x: 0, y: 160 * s), options: [])
    ctx.restoreGState()

    // Front panel.
    let front = CGPath(roundedRect: CGRect(x: 96 * s, y: 160 * s,
                                           width: 832 * s, height: 540 * s),
                       cornerWidth: 44 * s, cornerHeight: 44 * s, transform: nil)
    ctx.saveGState()
    ctx.addPath(front)
    ctx.clip()
    ctx.drawLinearGradient(gradient(frontTop, frontBottom),
                           start: CGPoint(x: 0, y: 700 * s),
                           end: CGPoint(x: 0, y: 160 * s), options: [])
    // Aqua-style highlight along the front panel's top edge.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
    ctx.fill(CGRect(x: 110 * s, y: 686 * s, width: 804 * s, height: 8 * s))
    ctx.restoreGState()
}

func writePNG(size: Int, scale: Int, to url: URL) {
    let pixels = size * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawFolder(into: ctx.cgContext, size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    writePNG(size: size, scale: 1, to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    writePNG(size: size, scale: 2, to: outDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("iconset written to \(outDir.path)")
