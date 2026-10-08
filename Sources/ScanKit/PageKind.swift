import CoreGraphics
import Vision

public enum PageKind: String, Codable, Sendable, CaseIterable {
    case paper, photo

    public var flipped: PageKind { self == .paper ? .photo : .paper }
}

/// What the classifier knows about one side of a sheet. Measured once, so the decision itself is
/// a pure function that tests can drive with plain numbers.
public struct SideFeatures: Equatable, Sendable {
    public var widthInches: Double
    public var heightInches: Double
    public var textCoverage: Double
    /// Vision's confidence in labels such as `document` and `printed_page`.
    public var documentConfidence: Double
    /// Vision's highest confidence in any other label (`outdoor`, `people`, `sky`, ...).
    public var sceneConfidence: Double
    public var colorfulFraction: Double

    public init(widthInches: Double, heightInches: Double, textCoverage: Double,
                documentConfidence: Double, sceneConfidence: Double, colorfulFraction: Double) {
        self.widthInches = widthInches
        self.heightInches = heightInches
        self.textCoverage = textCoverage
        self.documentConfidence = documentConfidence
        self.sceneConfidence = sceneConfidence
        self.colorfulFraction = colorfulFraction
    }
}

public enum PageKindClassifier {
    /// Print sizes, short side first. 8x10 is left out because it is as likely to be paper.
    static let photoSizes: [(Double, Double)] = [(2.5, 3.5), (3.5, 5), (4, 4), (4, 6), (5, 5), (5, 7), (4, 12)]
    static let paperSizes: [(Double, Double)] = [(8.5, 11), (8.5, 14), (8.27, 11.69), (5.5, 8.5)]
    static let sizeTolerance = 0.45

    /// Each signal votes; size is the strongest because the FastFoto feeds prints and paper at their
    /// true size. The back of a sheet is not considered: writing on a photo's back is still a photo.
    public static func classify(_ front: SideFeatures) -> PageKind {
        var vote = 0.0
        if matches(front, photoSizes) { vote += 2 }
        if matches(front, paperSizes) || isReceiptShaped(front) { vote -= 2 }
        if front.textCoverage > 0.06 { vote -= 2 } else if front.textCoverage < 0.01 { vote += 1 }
        if front.documentConfidence > 0.4 { vote -= 1.5 }
        if front.sceneConfidence > 0.4 { vote += 1.5 }
        if front.colorfulFraction > 0.2 { vote += 1 }
        return vote > 0 ? .photo : .paper
    }

    private static func matches(_ side: SideFeatures, _ sizes: [(Double, Double)]) -> Bool {
        let short = min(side.widthInches, side.heightInches), long = max(side.widthInches, side.heightInches)
        return sizes.contains { abs($0.0 - short) <= sizeTolerance && abs($0.1 - long) <= sizeTolerance }
    }

    private static func isReceiptShaped(_ side: SideFeatures) -> Bool {
        min(side.widthInches, side.heightInches) <= 3.6 && max(side.widthInches, side.heightInches) >= 7
    }
}

extension SideFeatures {
    static let documentLabels: Set<String> = ["document", "printed_page", "screenshot", "receipt", "text", "handwriting", "paper"]

    /// Measures a cropped side. Vision runs on a small copy: labels don't need 300 dpi.
    public static func measure(_ image: CGImage, dpi: Int, lines: [RecognizedLine]) async throws -> SideFeatures {
        let observations = try await ClassifyImageRequest().perform(on: thumbnail(image, maxPixels: 512))
        let document = observations.filter { documentLabels.contains($0.identifier) }.map { Double($0.confidence) }.max() ?? 0
        let scene = observations.filter { !documentLabels.contains($0.identifier) }.map { Double($0.confidence) }.max() ?? 0
        let coverage = lines.reduce(0.0) { $0 + Double($1.normalizedBox.width * $1.normalizedBox.height) }
        return SideFeatures(widthInches: Double(image.width) / Double(dpi), heightInches: Double(image.height) / Double(dpi),
                            textCoverage: min(1, coverage), documentConfidence: document, sceneConfidence: scene,
                            colorfulFraction: ColorAnalysis(image).colorfulFraction)
    }
}

func thumbnail(_ image: CGImage, maxPixels: Int) -> CGImage {
    let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}
