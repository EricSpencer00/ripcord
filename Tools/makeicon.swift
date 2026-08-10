#!/usr/bin/env swift
// Renders AppIcon.icns from code so the repository carries no binary assets.
// Usage: swift Tools/makeicon.swift <output-directory>

import AppKit
import Foundation

let paper = NSColor(srgbRed: 0.929, green: 0.914, blue: 0.878, alpha: 1)
let ink = NSColor(srgbRed: 0.110, green: 0.106, blue: 0.090, alpha: 1)
let accent = NSColor(srgbRed: 0.831, green: 0.322, blue: 0.106, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let scale = size / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons are inset inside their canvas; the squircle sits in the middle ~82%.
    let inset = 100.0 * scale
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185 * scale, yRadius: 185 * scale)
    paper.setFill()
    squircle.fill()

    // Masthead rule across the top, the way a printed page is ruled off.
    ink.setFill()
    NSRect(x: rect.minX + 90 * scale, y: rect.maxY - 190 * scale,
           width: rect.width - 180 * scale, height: 26 * scale).fill()

    // The signal bar: the one piece of colour.
    accent.setFill()
    NSRect(x: rect.minX + 90 * scale, y: rect.minY + 150 * scale,
           width: rect.width - 180 * scale, height: 60 * scale).fill()

    // "R" in a compressed grotesque, matching the app's masthead.
    let pointSize = 540 * scale
    let descriptor = NSFont.systemFont(ofSize: pointSize, weight: .black).fontDescriptor
        .withDesign(.default)?
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: -0.4]])
    let font = descriptor.flatMap { NSFont(descriptor: $0, size: pointSize) }
        ?? NSFont.systemFont(ofSize: pointSize, weight: .black)

    let glyph = NSAttributedString(string: "R", attributes: [.font: font, .foregroundColor: ink])
    let bounds = glyph.size()
    glyph.draw(at: NSPoint(x: rect.midX - bounds.width / 2,
                           y: rect.minY + 250 * scale))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (pixels, name) in variants {
    let rep = drawIcon(size: CGFloat(pixels))
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}
print("wrote \(iconset.path)")
