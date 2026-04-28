import AppKit
import CoreGraphics
import Foundation

private struct IconSize {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String {
        scale == 1
            ? "icon_\(points)x\(points).png"
            : "icon_\(points)x\(points)@\(scale)x.png"
    }
}

private let outputRoot = URL(fileURLWithPath: "Resources", isDirectory: true)
private let docsIconURL = URL(fileURLWithPath: "docs/icon.png")
private let sourceURL = outputRoot.appendingPathComponent("AppIconSource.png")
private let iconsetURL = outputRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
private let icnsURL = outputRoot.appendingPathComponent("AppIcon.icns")
private let readmeIconURL = outputRoot.appendingPathComponent("icon-256.png")

private let iconSizes = [
    IconSize(points: 16, scale: 1),
    IconSize(points: 16, scale: 2),
    IconSize(points: 32, scale: 1),
    IconSize(points: 32, scale: 2),
    IconSize(points: 128, scale: 1),
    IconSize(points: 128, scale: 2),
    IconSize(points: 256, scale: 1),
    IconSize(points: 256, scale: 2),
    IconSize(points: 512, scale: 1),
    IconSize(points: 512, scale: 2)
]

private func loadProvidedSourceImage() throws -> CGImage? {
    guard FileManager.default.fileExists(atPath: docsIconURL.path) else { return nil }
    guard
        let image = NSImage(contentsOf: docsIconURL),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        throw CocoaError(.fileReadCorruptFile)
    }

    try writePNG(cgImage, size: 1024, destination: sourceURL)
    return cgImage
}

private func renderGeneratedSourceImage() throws -> CGImage {
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size)

    image.lockFocus()

    let bounds = NSRect(origin: .zero, size: size)
    NSColor(red: 0.08, green: 0.10, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 210, yRadius: 210).fill()

    let inset: CGFloat = 146
    let screenRect = bounds.insetBy(dx: inset, dy: inset + 24)
    NSColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: screenRect, xRadius: 72, yRadius: 72).fill()

    let titleRect = NSRect(x: screenRect.minX, y: screenRect.maxY - 140, width: screenRect.width, height: 140)
    NSColor(red: 0.16, green: 0.21, blue: 0.26, alpha: 1).setFill()
    NSBezierPath(roundedRect: titleRect, xRadius: 72, yRadius: 72).fill()

    let contentRect = NSRect(x: screenRect.minX + 74, y: screenRect.minY + 96, width: screenRect.width - 148, height: screenRect.height - 264)
    NSColor(red: 0.18, green: 0.53, blue: 0.80, alpha: 1).setFill()
    NSBezierPath(roundedRect: contentRect, xRadius: 40, yRadius: 40).fill()

    let glyph = "W" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 320, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    let glyphSize = glyph.size(withAttributes: attributes)
    glyph.draw(
        at: NSPoint(x: bounds.midX - glyphSize.width / 2, y: bounds.midY - glyphSize.height / 2 - 14),
        withAttributes: attributes
    )

    image.unlockFocus()

    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    try writePNG(cgImage, size: 1024, destination: sourceURL)
    return cgImage
}

private func writePNG(_ source: CGImage, size: Int, destination: URL) throws {
    guard
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(canvas)
    context.interpolationQuality = .high
    context.draw(source, in: canvas)

    guard let icon = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }

    let bitmap = NSBitmapImageRep(cgImage: icon)
    bitmap.size = CGSize(width: size, height: size)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try pngData.write(to: destination)
}

private func appendFourCC(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func writeICNS(renditions: [(type: String, file: String)], destination: URL) throws {
    var chunks = Data()

    for rendition in renditions {
        let pngURL = iconsetURL.appendingPathComponent(rendition.file)
        let pngData = try Data(contentsOf: pngURL)
        appendFourCC(rendition.type, to: &chunks)
        appendUInt32BE(UInt32(pngData.count + 8), to: &chunks)
        chunks.append(pngData)
    }

    var icns = Data()
    appendFourCC("icns", to: &icns)
    appendUInt32BE(UInt32(chunks.count + 8), to: &icns)
    icns.append(chunks)
    try icns.write(to: destination)
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sourceImage = try loadProvidedSourceImage() ?? renderGeneratedSourceImage()

for iconSize in iconSizes {
    try writePNG(
        sourceImage,
        size: iconSize.pixels,
        destination: iconsetURL.appendingPathComponent(iconSize.filename)
    )
}

try writePNG(sourceImage, size: 256, destination: readmeIconURL)

try writeICNS(
    renditions: [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png")
    ],
    destination: icnsURL
)
