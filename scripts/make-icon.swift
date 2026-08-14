import AppKit
import Foundation

// Renders the app icon into an iconset directory (PNGs at every required
// size). Usage: `swift scripts/make-icon.swift <iconset-dir>`
// The build script then runs `iconutil -c icns` over the result.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/DSHAppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Rounded-square background with a deep-blue gradient.
let inset: CGFloat = 80
let bgRect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 200, yRadius: 200)
let gradient = NSGradient(colors: [
  NSColor(calibratedRed: 0.10, green: 0.19, blue: 0.52, alpha: 1),
  NSColor(calibratedRed: 0.19, green: 0.42, blue: 0.88, alpha: 1),
  NSColor(calibratedRed: 0.27, green: 0.60, blue: 0.85, alpha: 1),
])!
NSGraphicsContext.saveGraphicsState()
bgPath.addClip()
gradient.draw(from: NSPoint(x: canvas / 2, y: 0), to: NSPoint(x: canvas / 2, y: canvas), options: [])
NSGraphicsContext.restoreGraphicsState()

// White SF Symbol sparkles, tinted from its template form.
if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) {
  let symbolSize: CGFloat = 470
  let symbolRect = NSRect(
    x: (canvas - symbolSize) / 2,
    y: (canvas - symbolSize) / 2 + 30,
    width: symbolSize,
    height: symbolSize)
  let tinted = NSImage(size: symbolRect.size)
  tinted.lockFocus()
  symbol.draw(in: NSRect(origin: .zero, size: symbolRect.size))
  NSColor.white.set()
  NSRect(origin: .zero, size: symbolRect.size).fill(using: .sourceAtop)
  tinted.unlockFocus()
  tinted.draw(in: symbolRect)
}
image.unlockFocus()

let sizes: [(name: String, px: Int)] = [
  ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for entry in sizes {
  let px = CGFloat(entry.px)
  let scaled = NSImage(size: NSSize(width: px, height: px))
  scaled.lockFocus()
  image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
  scaled.unlockFocus()
  guard let tiff = scaled.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:]) else { continue }
  try? png.write(to: URL(fileURLWithPath: outDir + "/" + entry.name))
}
print("icon iconset written to \(outDir)")
