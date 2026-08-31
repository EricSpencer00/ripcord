#!/usr/bin/env swift
// Renders the link preview card for the landing page, so a posted link carries the masthead
// instead of nothing. Usage: swift Tools/makeog.swift <output.png>

import AppKit
import Foundation

let paper = NSColor(srgbRed: 0.929, green: 0.914, blue: 0.878, alpha: 1)
let ink = NSColor(srgbRed: 0.110, green: 0.106, blue: 0.090, alpha: 1)
let accent = NSColor(srgbRed: 0.831, green: 0.322, blue: 0.106, alpha: 1)

// The size every card reader crops to: 1.91:1.
let width = 1200.0, height = 630.0
let margin = 84.0

func compressed(_ size: CGFloat, weight: NSFont.Weight, width: CGFloat) -> NSFont {
    let descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: width]])
    return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

paper.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Masthead, ruled off in the one colour, the way the page is.
let title = NSAttributedString(string: "RIPCORD", attributes: [
    .font: compressed(196, weight: .black, width: -0.35),
    .foregroundColor: ink,
    .kern: -4,
])
title.draw(at: NSPoint(x: margin, y: height - margin - 176))

accent.setFill()
NSRect(x: margin, y: height - margin - 206, width: width - 2 * margin, height: 10).fill()

let standfirst = NSAttributedString(string: "Drop a track on it, get a mastered WAV back.", attributes: [
    .font: NSFont.systemFont(ofSize: 46, weight: .medium),
    .foregroundColor: ink,
])
standfirst.draw(at: NSPoint(x: margin, y: height - margin - 300))

let body = NSAttributedString(string: "Everything happens on your Mac. No account, no upload,\nand no network code in the app at all.", attributes: [
    .font: NSFont.systemFont(ofSize: 34, weight: .regular),
    .foregroundColor: ink.withAlphaComponent(0.72),
])
body.draw(at: NSPoint(x: margin, y: height - margin - 400))

// The dek from the page, in the same mono small caps.
let dek = NSAttributedString(string: "OFFLINE MASTERING  ·  macOS 14+  ·  UNIVERSAL  ·  MIT", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .semibold),
    .foregroundColor: ink.withAlphaComponent(0.75),
    .kern: 2,
])
dek.draw(at: NSPoint(x: margin, y: margin))

NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "og.png"
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("makeog: the card did not encode\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try data.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
