import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScanKit

@Suite struct PageEncoderTests {
    /// Letter paper at 300 dpi in a given tint, with rows of black "text" whose left and right edges
    /// carry one-pixel red and blue halos, the way the FF-680W's sensor fringes black on paper.
    static func paper(tint: (UInt8, UInt8, UInt8), stamp: Bool = false) -> CGImage {
        let width = 2550, height = 3300
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var rng = SplitMix(seed: 7)
        for i in 0..<(width * height) {
            let grain = Int(rng.next() % 9) - 4
            pixels[i * 4] = UInt8(clamping: Int(tint.0) + grain)
            pixels[i * 4 + 1] = UInt8(clamping: Int(tint.1) + grain)
            pixels[i * 4 + 2] = UInt8(clamping: Int(tint.2) + grain)
            pixels[i * 4 + 3] = 255
        }
        func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let i = (y * width + x) * 4
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b
        }
        for line in 0..<40 {
            let top = 200 + line * 70
            for y in top..<(top + 24) {
                var x = 150
                while x < width - 150 {
                    for dx in 0..<8 { set(x + dx, y, 15, 15, 15) }
                    set(x - 1, y, 200, 40, 40)
                    set(x + 8, y, 40, 60, 220)
                    x += 14
                }
            }
        }
        if stamp {
            for y in 2800..<3100 { for x in 1900..<2200 { set(x, y, 200, 30, 40) } }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func fringedTextOnWhitePaperHasNoMeaningfulColor() {
        #expect(!ColorAnalysis(Self.paper(tint: (250, 250, 248))).hasMeaningfulColor)
    }

    @Test func pinkCarbonCopyCountsAsGray() {
        let analysis = ColorAnalysis(Self.paper(tint: (250, 222, 232)))
        #expect(!analysis.hasMeaningfulColor, "colorful fraction \(analysis.colorfulFraction)")
    }

    /// Chroma ~60 before balancing, so only balancing to the paper keeps it gray.
    @Test func yellowedReceiptCountsAsGray() {
        let analysis = ColorAnalysis(Self.paper(tint: (245, 232, 185)))
        #expect(!analysis.hasMeaningfulColor, "colorful fraction \(analysis.colorfulFraction)")
    }

    @Test func aRedStampIsMeaningfulColor() {
        let analysis = ColorAnalysis(Self.paper(tint: (250, 250, 248), stamp: true))
        #expect(analysis.hasMeaningfulColor, "colorful fraction \(analysis.colorfulFraction)")
    }

    @Test func grayPaperIsStoredAsOneChannelAt200DPIAtTheSamePhysicalSize() throws {
        let page = ProcessedPage(image: Self.paper(tint: (250, 222, 232)), dpi: 300, lines: [])

        let stored = try PageEncoder.encode(page, mode: .automatic)

        #expect(stored.isGray)
        #expect(stored.dpi == 200)
        #expect(stored.pixelWidth == 1700 && stored.pixelHeight == 2200)
        #expect(stored.pointSize == CGSize(width: 612, height: 792))
        let decoded = try #require(CGImageSourceCreateWithData(stored.jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.colorSpace?.model == .monochrome)
        #expect(stored.jpeg.count < 1_000_000, "\(stored.jpeg.count) bytes")
    }

    @Test func colorPaperKeepsItsColor() throws {
        let page = ProcessedPage(image: Self.paper(tint: (250, 250, 248), stamp: true), dpi: 300, lines: [])

        let stored = try PageEncoder.encode(page, mode: .automatic)

        #expect(!stored.isGray)
        let decoded = try #require(CGImageSourceCreateWithData(stored.jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.colorSpace?.model == .rgb)
    }

    static let stampedPage = ProcessedPage(image: paper(tint: (250, 250, 248), stamp: true), dpi: 300, lines: [])
    static let pinkPage = ProcessedPage(image: paper(tint: (250, 222, 232)), dpi: 300, lines: [])

    static func storedColorModel(_ page: StoredPage) throws -> CGColorSpaceModel? {
        let decoded = try #require(CGImageSourceCreateWithData(page.jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        return decoded.colorSpace?.model
    }

    @Test(arguments: [(ColorMode.automatic, false, true), (.color, false, false), (.grayscale, true, true)])
    func colorModeDecidesHowPaperIsStored(mode: ColorMode, stampedIsGray: Bool, pinkIsGray: Bool) throws {
        let stamped = try PageEncoder.encode(Self.stampedPage, mode: mode)
        let pink = try PageEncoder.encode(Self.pinkPage, mode: mode)

        #expect(stamped.isGray == stampedIsGray)
        #expect(pink.isGray == pinkIsGray)
        #expect(try Self.storedColorModel(stamped) == (stampedIsGray ? .monochrome : .rgb))
        #expect(try Self.storedColorModel(pink) == (pinkIsGray ? .monochrome : .rgb))
    }

    @Test func automaticFollowsTheChromaCheck() throws {
        for page in [Self.stampedPage, Self.pinkPage] {
            let stored = try PageEncoder.encode(page, mode: .automatic)
            #expect(stored.isGray == !ColorAnalysis(page.image).hasMeaningfulColor)
        }
    }
}
