import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: make-rounded-icon.swift INPUT.png OUTPUT.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let imageSource = NSImage(contentsOf: inputURL),
      let source = imageSource.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Could not read source icon\n", stderr)
    exit(1)
}

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create icon context\n", stderr)
    exit(1)
}

context.clear(CGRect(x: 0, y: 0, width: size, height: size))
let maskRect = CGRect(x: 30, y: 30, width: 964, height: 964)
let maskPath = CGPath(
    roundedRect: maskRect,
    cornerWidth: 205,
    cornerHeight: 205,
    transform: nil
)
context.addPath(maskPath)
context.clip()
context.interpolationQuality = .high
context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))

guard let outputImage = context.makeImage() else {
    fputs("Could not render icon\n", stderr)
    exit(1)
}

let bitmap = NSBitmapImageRep(cgImage: outputImage)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode icon PNG\n", stderr)
    exit(1)
}

try data.write(to: outputURL, options: .atomic)
