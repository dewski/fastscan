// Usage: swift script/render-icon.swift <output-dir>
// Draws the FastScan icon and writes <output-dir>/Assets.xcassets with a complete AppIcon.appiconset.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Slot {
    let points: Int
    let scale: Int
    var pixels: Int { points * scale }
    var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
}

let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

// Superellipse corners approximate Apple's continuous-curvature squircle without a hand-tuned Bezier table.
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let extent = radius * 1.3
    let exponent: CGFloat = 4.6
    let steps = 48
    let path = CGMutablePath()
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: rect.maxX - extent, y: rect.maxY - extent), 0),
        (CGPoint(x: rect.minX + extent, y: rect.maxY - extent), .pi / 2),
        (CGPoint(x: rect.minX + extent, y: rect.minY + extent), .pi),
        (CGPoint(x: rect.maxX - extent, y: rect.minY + extent), 3 * .pi / 2),
    ]
    for (center, start) in corners {
        for step in 0...steps {
            let t = start + CGFloat(step) / CGFloat(steps) * .pi / 2
            let c = cos(t), s = sin(t)
            let point = CGPoint(
                x: center.x + extent * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent),
                y: center.y + extent * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent))
            path.isEmpty ? path.move(to: point) : path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ context: CGContext, _ colors: [CGColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Artwork is laid out on the 1024pt macOS icon grid (y up); `pixels` only sets the raster and the
// minimum stroke sizes, so the scan line stays at least a pixel wide at 16px.
func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let unit = CGFloat(pixels) / 1024
    context.scaleBy(x: unit, y: unit)
    context.interpolationQuality = .high
    let pixel = 1 / unit
    let small = pixels <= 64
    // Shadow offset and blur ignore the CTM, so they are scaled by hand.
    func shadow(y: CGFloat, blur: CGFloat, _ shadowColor: CGColor) {
        context.setShadow(offset: CGSize(width: 0, height: y * unit), blur: blur * unit, color: shadowColor)
    }

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(tile, radius: 185)

    context.saveGState()
    shadow(y: -10, blur: 28, color(0x000000, 0.32))
    context.addPath(tilePath)
    context.setFillColor(color(0x26246E))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    linearGradient(context, [color(0x5B6CF5), color(0x3A3DC4), color(0x1C1A5E)], [0, 0.5, 1],
                   from: CGPoint(x: 512, y: tile.maxY), to: CGPoint(x: 512, y: tile.minY))
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 960), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 960), endRadius: 620, options: [])
    context.restoreGState()

    let sheet = CGRect(x: 262, y: 196, width: 500, height: 632)
    let sheetPath = CGPath(roundedRect: sheet, cornerWidth: 34, cornerHeight: 34, transform: nil)
    let scanY: CGFloat = 470

    context.saveGState()
    shadow(y: -14, blur: 36, color(0x0A0830, 0.45))
    context.addPath(sheetPath)
    context.setFillColor(color(0xFBF8F1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(sheetPath)
    context.clip()
    linearGradient(context, [color(0xFFFDF8), color(0xF3EEE4)], [0, 1],
                   from: CGPoint(x: 512, y: sheet.maxY), to: CGPoint(x: 512, y: sheet.minY))
    // The unscanned part of the sheet sits in the scanner's shadow, which makes the line read as moving down.
    context.setFillColor(color(0x1C1A5E, 0.1))
    context.fill(CGRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: scanY - sheet.minY))

    if !small {
        let ink = color(0x23264F, 0.62)
        let faint = color(0x23264F, 0.16)
        let left = sheet.minX + 64
        let lines: [(CGFloat, CGFloat, CGFloat)] = [
            (720, 210, 28), (654, 372, 18), (614, 340, 18), (574, 372, 18), (534, 250, 18),
            (430, 372, 18), (390, 300, 18), (350, 372, 18), (310, 210, 18),
        ]
        for (y, width, height) in lines {
            context.setFillColor(y > scanY ? ink : faint)
            context.addPath(CGPath(roundedRect: CGRect(x: left, y: y, width: width, height: height),
                                   cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
            context.fillPath()
        }
    }
    let wash = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x7DF9FF, 0.55), color(0x7DF9FF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(wash, start: CGPoint(x: 512, y: scanY), end: CGPoint(x: 512, y: scanY + 150), options: [])
    context.restoreGState()

    let beamHeight = max(26, 1.6 * pixel)
    let beam = CGRect(x: sheet.minX - 58, y: scanY - beamHeight / 2, width: sheet.width + 116, height: beamHeight)
    context.saveGState()
    shadow(y: 0, blur: small ? 0 : 40, color(0x52F2FF, 0.95))
    context.addPath(CGPath(roundedRect: beam, cornerWidth: beamHeight / 2, cornerHeight: beamHeight / 2, transform: nil))
    context.setFillColor(color(0x6FF4FF))
    context.fillPath()
    context.restoreGState()
    let core = beam.insetBy(dx: 30, dy: beamHeight * 0.32)
    context.addPath(CGPath(roundedRect: core, cornerWidth: core.height / 2, cornerHeight: core.height / 2, transform: nil))
    context.setFillColor(color(0xFFFFFF, small ? 0 : 0.9))
    context.fillPath()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.addPath(tilePath)
    context.setLineWidth(max(5, pixel) * 2)
    context.replacePathWithStrokedPath()
    context.clip()
    linearGradient(context, [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0), color(0xFFFFFF, 0.06)], [0, 0.45, 1],
                   from: CGPoint(x: 512, y: tile.maxY), to: CGPoint(x: 512, y: tile.minY))
    context.restoreGState()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("cannot write \(url.path)\n".utf8))
        exit(1)
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard let outputDir = arguments.first else {
    FileHandle.standardError.write(Data("usage: swift script/render-icon.swift <output-dir>\n".utf8))
    exit(1)
}

let catalog = URL(filePath: outputDir).appending(path: "Assets.xcassets")
let iconSet = catalog.appending(path: "AppIcon.appiconset")
try? FileManager.default.removeItem(at: iconSet)
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var cache: [Int: CGImage] = [:]
for slot in slots {
    let image = cache[slot.pixels] ?? render(pixels: slot.pixels)
    cache[slot.pixels] = image
    writePNG(image, to: iconSet.appending(path: slot.filename))
}

let entries = slots.map {
    """
        {
          "filename" : "\($0.filename)",
          "idiom" : "mac",
          "scale" : "\($0.scale)x",
          "size" : "\($0.points)x\($0.points)"
        }
    """
}
let info = """
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
"""
try Data("{\n  \"images\" : [\n\(entries.joined(separator: ",\n"))\n  ],\n\(info)\n}\n".utf8)
    .write(to: iconSet.appending(path: "Contents.json"))
try Data("{\n\(info)\n}\n".utf8).write(to: catalog.appending(path: "Contents.json"))
print("wrote \(iconSet.path)")
