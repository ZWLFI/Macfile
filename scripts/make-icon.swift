import AppKit

let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let outer = NSBezierPath(
  roundedRect: NSRect(x: 46, y: 46, width: 932, height: 932), xRadius: 204, yRadius: 204)
NSColor(srgbRed: 0.13, green: 0.22, blue: 0.43, alpha: 1).setFill()
outer.fill()
NSGradient(
  starting: NSColor(srgbRed: 0.28, green: 0.51, blue: 0.99, alpha: 1),
  ending: NSColor(srgbRed: 0.11, green: 0.29, blue: 0.75, alpha: 1))!.draw(
    in: NSBezierPath(
      roundedRect: NSRect(x: 81, y: 81, width: 862, height: 862), xRadius: 174, yRadius: 174),
    angle: -65)
NSColor.white.withAlphaComponent(0.95).setFill()
NSBezierPath(roundedRect: NSRect(x: 220, y: 250, width: 270, height: 530), xRadius: 38, yRadius: 38)
  .fill()
NSColor.white.withAlphaComponent(0.73).setFill()
NSBezierPath(roundedRect: NSRect(x: 526, y: 250, width: 278, height: 325), xRadius: 38, yRadius: 38)
  .fill()
NSColor.white.withAlphaComponent(0.88).setFill()
NSBezierPath(roundedRect: NSRect(x: 526, y: 612, width: 278, height: 168), xRadius: 38, yRadius: 38)
  .fill()
NSColor(srgbRed: 0.19, green: 0.4, blue: 0.87, alpha: 0.45).setFill()
for y in [650, 586, 522] {
  NSBezierPath(roundedRect: NSRect(x: 262, y: y, width: 180, height: 17), xRadius: 8, yRadius: 8)
    .fill()
}
image.unlockFocus()
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
    try rep.representation(using: .png, properties: [:])!.write(
      to: URL(fileURLWithPath: destination).appendingPathComponent(name))
  }
}
