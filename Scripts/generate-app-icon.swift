#!/usr/bin/swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-app-icon.swift <output.png>\n", stderr)
    exit(2)
}

let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)

image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Unable to create drawing context")
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let tileRect = NSRect(x: 42, y: 42, width: 940, height: 940)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 225, yRadius: 225)

context.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor.black.withAlphaComponent(0.2).setFill()
tile.fill()
context.restoreGState()

context.saveGState()
tile.addClip()
let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.19, green: 0.12, blue: 0.72, alpha: 1),
    NSColor(calibratedRed: 0.50, green: 0.16, blue: 0.82, alpha: 1),
    NSColor(calibratedRed: 0.89, green: 0.24, blue: 0.64, alpha: 1)
])!
background.draw(in: tileRect, angle: -42)

let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0.34),
                      ending: NSColor.white.withAlphaComponent(0))!
glow.draw(in: NSRect(x: 70, y: 475, width: 700, height: 500), relativeCenterPosition: NSPoint(x: -0.25, y: 0.35))
context.restoreGState()

let envelopeRect = NSRect(x: 205, y: 335, width: 565, height: 390)
let envelope = NSBezierPath(roundedRect: envelopeRect, xRadius: 58, yRadius: 58)
NSColor.white.withAlphaComponent(0.96).setFill()
envelope.fill()

let fold = NSBezierPath()
fold.move(to: NSPoint(x: 235, y: 675))
fold.line(to: NSPoint(x: 487, y: 485))
fold.curve(to: NSPoint(x: 740, y: 675),
           controlPoint1: NSPoint(x: 505, y: 472),
           controlPoint2: NSPoint(x: 565, y: 525))
fold.lineWidth = 34
fold.lineCapStyle = .round
fold.lineJoinStyle = .round
NSColor(calibratedRed: 0.53, green: 0.19, blue: 0.78, alpha: 0.86).setStroke()
fold.stroke()

let lowerFold = NSBezierPath()
lowerFold.move(to: NSPoint(x: 230, y: 375))
lowerFold.line(to: NSPoint(x: 418, y: 535))
lowerFold.move(to: NSPoint(x: 755, y: 375))
lowerFold.line(to: NSPoint(x: 565, y: 535))
lowerFold.lineWidth = 24
lowerFold.lineCapStyle = .round
NSColor(calibratedRed: 0.53, green: 0.19, blue: 0.78, alpha: 0.34).setStroke()
lowerFold.stroke()

let lensCenter = NSPoint(x: 690, y: 370)
let lensRadius: CGFloat = 142
let lens = NSBezierPath(ovalIn: NSRect(
    x: lensCenter.x - lensRadius,
    y: lensCenter.y - lensRadius,
    width: lensRadius * 2,
    height: lensRadius * 2
))
lens.lineWidth = 64
NSColor(calibratedRed: 0.15, green: 0.87, blue: 0.98, alpha: 1).setStroke()
lens.stroke()

let handle = NSBezierPath()
handle.move(to: NSPoint(x: 795, y: 265))
handle.line(to: NSPoint(x: 880, y: 180))
handle.lineWidth = 72
handle.lineCapStyle = .round
NSColor(calibratedRed: 0.15, green: 0.87, blue: 0.98, alpha: 1).setStroke()
handle.stroke()

let sparkle = NSBezierPath()
sparkle.move(to: NSPoint(x: 790, y: 785))
sparkle.curve(to: NSPoint(x: 850, y: 845), controlPoint1: NSPoint(x: 830, y: 800), controlPoint2: NSPoint(x: 835, y: 810))
sparkle.curve(to: NSPoint(x: 910, y: 785), controlPoint1: NSPoint(x: 865, y: 810), controlPoint2: NSPoint(x: 875, y: 800))
sparkle.curve(to: NSPoint(x: 850, y: 725), controlPoint1: NSPoint(x: 875, y: 770), controlPoint2: NSPoint(x: 865, y: 760))
sparkle.curve(to: NSPoint(x: 790, y: 785), controlPoint1: NSPoint(x: 835, y: 760), controlPoint2: NSPoint(x: 830, y: 770))
sparkle.close()
NSColor.white.setFill()
sparkle.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1]) else {
    fatalError("Unable to encode app icon")
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
