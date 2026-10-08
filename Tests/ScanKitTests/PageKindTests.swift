import CoreGraphics
import Foundation
import Testing
@testable import ScanKit

@Suite struct PageKindTests {
    static func features(_ width: Double, _ height: Double, text: Double, document: Double, scene: Double, color: Double) -> SideFeatures {
        SideFeatures(widthInches: width, heightInches: height, textCoverage: text,
                     documentConfidence: document, sceneConfidence: scene, colorfulFraction: color)
    }

    @Test(arguments: [
        // The fixture invoice's front, as measured.
        ("invoice", features(8.48, 11.0, text: 0.25, document: 0.71, scene: 0.26, color: 0.001), PageKind.paper),
        ("4x6 color print, landscape", features(6.0, 4.0, text: 0, document: 0.05, scene: 0.8, color: 0.4), .photo),
        ("4x6 black and white print", features(3.9, 5.9, text: 0, document: 0.2, scene: 0.5, color: 0), .photo),
        ("5x7 print with a caption on the front", features(5, 7, text: 0.02, document: 0.3, scene: 0.6, color: 0.3), .photo),
        ("5x7 greeting card", features(5, 7, text: 0.1, document: 0.5, scene: 0.2, color: 0.1), .paper),
        ("register receipt", features(3.1, 9.4, text: 0.2, document: 0.6, scene: 0.1, color: 0), .paper),
        ("letter-size photo print", features(8.5, 11, text: 0, document: 0.1, scene: 0.8, color: 0.5), .photo),
        ("letter with a color letterhead", features(8.5, 11, text: 0.15, document: 0.6, scene: 0.3, color: 0.02), .paper),
    ])
    func classifiesBySizeTextAndScene(_ name: String, _ features: SideFeatures, _ expected: PageKind) {
        #expect(PageKindClassifier.classify(features) == expected, "\(name)")
    }

    /// A synthetic stand-in for a print: no real-photo fixtures exist, so accuracy on actual
    /// photographs is unverified.
    @Test func measuredSyntheticFourBySixIsAPhoto() async throws {
        let image = Self.syntheticPhoto(width: 1800, height: 1200)

        let features = try await SideFeatures.measure(image, dpi: 300, lines: [])

        #expect(abs(features.widthInches - 6) < 0.01 && abs(features.heightInches - 4) < 0.01)
        #expect(PageKindClassifier.classify(features) == .photo, "\(features)")
    }

    @Test func measuredSyntheticLetterPageIsPaper() async throws {
        var page = SyntheticPage(width: 2550)
        page.paper(3300, textLines: 40)
        let lines = (0..<40).map { RecognizedLine(text: "line", normalizedBox: CGRect(x: 0.06, y: Double($0) * 0.02, width: 0.88, height: 0.009)) }

        let features = try await SideFeatures.measure(page.image, dpi: 300, lines: lines)

        #expect(PageKindClassifier.classify(features) == .paper, "\(features)")
    }

    /// Sky-to-ground gradients with sensor-like noise and a dark subject, at 300 dpi.
    static func syntheticPhoto(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var rng = SplitMix(seed: 3)
        for y in 0..<height {
            let t = Double(y) / Double(height)
            for x in 0..<width {
                let noise = Double(Int(rng.next() % 21) - 10)
                var (r, g, b) = t < 0.55 ? (90 + 120 * t, 150 + 80 * t, 230.0) : (70 + 60 * t, 120 - 40 * t, 50.0)
                let dx = Double(x - width / 2), dy = Double(y - height * 6 / 10)
                if dx * dx / 40000 + dy * dy / 90000 < 1 { (r, g, b) = (180, 120, 90) }
                let i = (y * width + x) * 4
                pixels[i] = UInt8(clamping: Int(r + noise))
                pixels[i + 1] = UInt8(clamping: Int(g + noise))
                pixels[i + 2] = UInt8(clamping: Int(b + noise))
                pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
