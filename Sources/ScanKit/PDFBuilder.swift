import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A page ready for the PDF: cropped, checked for blankness, and OCR'd.
public struct ProcessedPage: Sendable {
    public var image: CGImage
    public var dpi: Int
    public var lines: [RecognizedLine]

    public init(image: CGImage, dpi: Int, lines: [RecognizedLine]) {
        self.image = image
        self.dpi = dpi
        self.lines = lines
    }
}

public enum PDFBuilder {
    public enum Failure: Error {
        case cannotCreate(URL)
        case cannotEncode
    }

    /// Quartz embeds a JPEG-backed CGImage's bytes as-is, so each page keeps the size PageEncoder chose.
    public static func write(_ pages: [StoredPage], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw Failure.cannotCreate(url) }
        for page in pages {
            guard let provider = CGDataProvider(data: page.jpeg as CFData),
                  let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw Failure.cannotEncode }
            var mediaBox = CGRect(origin: .zero, size: page.pointSize)
            context.beginPage(mediaBox: &mediaBox)
            context.draw(image, in: mediaBox)
            drawInvisibleText(page.lines, in: mediaBox, context: context)
            context.endPage()
        }
        context.closePDF()
    }

    /// Draws each OCR line as invisible text stretched over its box, so the PDF is searchable and
    /// selection in Preview lines up with the scanned words.
    private static func drawInvisibleText(_ lines: [RecognizedLine], in page: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let box = CGRect(x: line.normalizedBox.minX * page.width, y: line.normalizedBox.minY * page.height,
                             width: line.normalizedBox.width * page.width, height: line.normalizedBox.height * page.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.9, nil)
            let text = CTLineCreateWithAttributedString(
                NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font])
            )
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(text, nil, &descent, nil)
            guard width > 0 else { continue }
            context.textMatrix = CGAffineTransform(scaleX: box.width / width, y: 1)
            context.textPosition = CGPoint(x: box.minX, y: box.minY + descent)
            CTLineDraw(text, context)
        }
        context.restoreGState()
    }
}
