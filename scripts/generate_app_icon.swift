#!/usr/bin/swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let canvasSize = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvasSize)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("unable to create graphics context\n", stderr)
    exit(3)
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.clear(CGRect(origin: .zero, size: canvasSize))

let tileRect = NSRect(x: 56, y: 56, width: 912, height: 912)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 218, yRadius: 218)
NSColor(srgbRed: 0.055, green: 0.105, blue: 0.205, alpha: 1).setFill()
tile.fill()

NSColor(srgbRed: 0.30, green: 0.57, blue: 1.0, alpha: 0.42).setStroke()
tile.lineWidth = 18
tile.stroke()

let monitorRect = NSRect(x: 196, y: 214, width: 632, height: 596)
let monitor = NSBezierPath(roundedRect: monitorRect, xRadius: 116, yRadius: 116)
NSColor.white.withAlphaComponent(0.09).setFill()
monitor.fill()
NSColor.white.withAlphaComponent(0.16).setStroke()
monitor.lineWidth = 10
monitor.stroke()

let lanes: [(x: CGFloat, top: CGFloat, color: NSColor)] = [
    (326, 600, NSColor(srgbRed: 0.29, green: 0.70, blue: 1.0, alpha: 1)),
    (512, 704, NSColor(srgbRed: 0.66, green: 0.48, blue: 1.0, alpha: 1)),
    (698, 646, NSColor(srgbRed: 0.26, green: 0.87, blue: 0.67, alpha: 1)),
]

for lane in lanes {
    let trackRect = NSRect(x: lane.x - 34, y: 326, width: 68, height: 328)
    let track = NSBezierPath(roundedRect: trackRect, xRadius: 34, yRadius: 34)
    NSColor.white.withAlphaComponent(0.18).setFill()
    track.fill()

    let fillHeight = max(88, lane.top - 326)
    let fillRect = NSRect(x: lane.x - 34, y: 326, width: 68, height: fillHeight)
    let fill = NSBezierPath(roundedRect: fillRect, xRadius: 34, yRadius: 34)
    NSColor.white.withAlphaComponent(0.94).setFill()
    fill.fill()

    let dotRect = NSRect(x: lane.x - 48, y: lane.top - 48, width: 96, height: 96)
    lane.color.setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    NSColor.white.withAlphaComponent(0.82).setStroke()
    let dotBorder = NSBezierPath(ovalIn: dotRect.insetBy(dx: 7, dy: 7))
    dotBorder.lineWidth = 8
    dotBorder.stroke()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("unable to encode icon\n", stderr)
    exit(4)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
