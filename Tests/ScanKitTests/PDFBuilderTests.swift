import CoreGraphics
import CoreText
import Foundation
import PDFKit
import ImageIO
import Testing
@testable import ScanKit

@Suite struct PDFBuilderTests {
    @Test func invisibleTextMakesThePDFSearchable() throws {
        var blank = SyntheticPage(width: 2550)
        blank.rows(3300, level: 250)
        let page = try PageEncoder.encode(ProcessedPage(image: blank.image, dpi: 300, lines: [
            RecognizedLine(text: "SIERRA RIDGE AUTO CARE", normalizedBox: CGRect(x: 0.6, y: 0.9, width: 0.3, height: 0.02)),
        ]), mode: .automatic)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFBuilder.write([page, page], to: url)

        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        let matches = document.findString("SIERRA RIDGE AUTO CARE", withOptions: [])
        #expect(matches.count == 2)
        let match = try #require(matches.first)
        let bounds = match.bounds(for: try #require(match.pages.first))
        #expect(bounds.minX > 612 * 0.55 && bounds.minY > 792 * 0.85, "text lands near its OCR box, got \(bounds)")
    }

    @Test func recognizesRenderedText() async throws {
        let lines = try await TextRecognizer.recognize(Self.render("INVOICE 48213"))
        #expect(lines.contains { $0.text.contains("48213") }, "got \(lines.map(\.text))")
    }

    private static func render(_ text: String) -> CGImage {
        let context = CGContext(data: nil, width: 1200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        let font = CTFontCreateWithName("Courier" as CFString, 80, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        context.setFillColor(gray: 0, alpha: 1)
        context.textPosition = CGPoint(x: 40, y: 120)
        CTLineDraw(line, context)
        return context.makeImage()!
    }
}
