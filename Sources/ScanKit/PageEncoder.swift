import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct StoredPage: Sendable {
    public var jpeg: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var dpi: Int
    public var isGray: Bool
    public var lines: [RecognizedLine]

    public var pointSize: CGSize {
        CGSize(width: CGFloat(pixelWidth) * 72 / CGFloat(dpi), height: CGFloat(pixelHeight) * 72 / CGFloat(dpi))
    }
}

/// Whether paper is stored in color. Photos are always kept in color.
public enum ColorMode: String, Sendable, CaseIterable {
    /// Color only for pages with color worth keeping, such as a stamp or a color logo.
    case automatic
    case color
    case grayscale
}

/// Scans arrive at 300 dpi color so OCR and photo detection see everything. Paper is stored smaller:
/// 200 dpi keeps 6 pt fine print legible, and most paper has no color worth keeping, so it is
/// stored as one gray channel with the paper tone lifted to white.
public enum PageEncoder {
    public static let storageDPI = 200
    static let jpegQuality = 0.5
    /// Paper grain at 200 dpi spans about this many levels below the paper's average tone.
    static let paperGrainMargin = 16.0

    public static func encode(_ page: ProcessedPage, mode: ColorMode) throws -> StoredPage {
        let paperLevel = grayPaperLevel(page.image, mode: mode)
        let isGray = paperLevel != nil
        let scale = min(1, Double(storageDPI) / Double(page.dpi))
        let width = Int((Double(page.image.width) * scale).rounded())
        let height = Int((Double(page.image.height) * scale).rounded())
        let resized = try render(page.image, width: width, height: height, gray: isGray)
        let stored = paperLevel.map { whitened(resized, paperLevel: $0) } ?? resized
        return StoredPage(jpeg: try jpeg(stored), pixelWidth: width, pixelHeight: height,
                          dpi: min(page.dpi, storageDPI),
                          isGray: isGray, lines: page.lines)
    }

    /// The paper's tone to lift to white when the page is stored gray, or nil to keep it in color.
    static func grayPaperLevel(_ image: CGImage, mode: ColorMode) -> Double? {
        switch mode {
        case .color:
            return nil
        case .grayscale:
            return ColorAnalysis(image).paperLuminance
        case .automatic:
            let analysis = ColorAnalysis(image)
            return analysis.hasMeaningfulColor ? nil : analysis.paperLuminance
        }
    }

    private static func render(_ image: CGImage, width: Int, height: Int, gray: Bool) throws -> CGImage {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info)
        else { throw PDFBuilder.Failure.cannotEncode }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw PDFBuilder.Failure.cannotEncode }
        return result
    }

    /// Maps the paper's own tone (pink carbon copies, yellowed receipts) and its grain to flat
    /// white. The grain is most of what JPEG would otherwise spend bytes on, and flattening it
    /// makes the text read crisper against the page.
    private static func whitened(_ gray: CGImage, paperLevel: Double) -> CGImage {
        guard let data = gray.dataProvider?.data as Data? else { return gray }
        let whitePoint = max(128, paperLevel - paperGrainMargin)
        let table = (0...255).map { UInt8(min(255, (Double($0) * 255 / whitePoint).rounded())) }
        let mapped = Data(data.map { table[Int($0)] })
        guard let provider = CGDataProvider(data: mapped as CFData),
              let image = CGImage(width: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: gray.bytesPerRow, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return gray }
        return image
    }

    static func jpeg(_ image: CGImage, quality: Double = jpegQuality) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PDFBuilder.Failure.cannotEncode }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PDFBuilder.Failure.cannotEncode }
        return data as Data
    }
}

/// Measures how much of a page carries color beyond the paper's own tint.
///
/// Analysed at 1/6 scale: scanner fringing (red and blue halos one or two pixels wide along black
/// text) averages back to neutral in a 6x6 box, while a stamp, highlighter, or photo keeps its hue.
/// Chroma is measured after white-balancing to the paper, so tinted paper counts as neutral.
public struct ColorAnalysis: Sendable {
    public var colorfulFraction: Double
    public var paperLuminance: Double

    /// Chroma (max - min channel, 0...255) above which a pixel is "in color". Fringing that
    /// survives the downsample stays under ~35; pink paper sits at 20-35 before balancing.
    static let chromaThreshold = 48.0
    /// 0.3% of the page is roughly a 1 in square on letter paper: a stamp or a color logo.
    static let meaningfulFraction = 0.003

    public var hasMeaningfulColor: Bool { colorfulFraction >= Self.meaningfulFraction }

    public init(_ image: CGImage, downsample factor: Int = 6) {
        let width = max(1, image.width / factor), height = max(1, image.height / factor)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.interpolationQuality = .medium
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let count = width * height

        // The paper is the brightest half of the page; its average color is the white point.
        var luminance = [Int](repeating: 0, count: 766)
        for i in 0..<count { luminance[Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2])] += 1 }
        var cutoff = 765, seen = 0
        while cutoff > 0, seen + luminance[cutoff] < count / 2 { seen += luminance[cutoff]; cutoff -= 1 }
        var sum = (r: 0.0, g: 0.0, b: 0.0), paperCount = 0.0
        for i in 0..<count where Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2]) >= cutoff {
            sum.r += Double(pixels[i * 4]); sum.g += Double(pixels[i * 4 + 1]); sum.b += Double(pixels[i * 4 + 2])
            paperCount += 1
        }
        let paper = (r: max(1, sum.r / paperCount), g: max(1, sum.g / paperCount), b: max(1, sum.b / paperCount))
        let peak = max(paper.r, paper.g, paper.b)
        let gain = (r: peak / paper.r, g: peak / paper.g, b: peak / paper.b)

        var colorful = 0
        for i in 0..<count {
            let r = Double(pixels[i * 4]) * gain.r, g = Double(pixels[i * 4 + 1]) * gain.g, b = Double(pixels[i * 4 + 2]) * gain.b
            if max(r, g, b) - min(r, g, b) > Self.chromaThreshold { colorful += 1 }
        }
        colorfulFraction = Double(colorful) / Double(count)
        paperLuminance = 0.299 * paper.r + 0.587 * paper.g + 0.114 * paper.b
    }
}
