import Testing
@testable import ScanKit

@Suite struct PageProcessorTests {
    /// 8.5 x 11 in at 300 dpi, laid out like a real FF-680W frame: leading edge, paper, trailing
    /// shadow, gray backing band, then white fill to 15.5 in.
    @Test func cropsFeedPaddingToThePaperEdge() {
        var frame = SyntheticPage(width: 2544)
        frame.rows(12, level: 210, noise: 2)
        frame.paper(3300, textLines: 20)
        frame.rows(24, level: 150, noise: 60)
        frame.rows(105, level: 210, noise: 2)
        frame.rows(4642 - frame.height, level: 255)

        let cropped = PageProcessor.crop(frame.image, dpi: 300)

        #expect(cropped.width == 2544)
        #expect(abs(cropped.height - 3300) <= 12, "height \(cropped.height)")
    }

    /// Gray-mode scans can go straight from the trailing shadow to fill with no backing band.
    @Test func cropsAFrameWithoutABackingBand() {
        var frame = SyntheticPage(width: 2544)
        frame.rows(12, level: 210, noise: 2)
        frame.paper(3300, textLines: 20)
        frame.rows(20, level: 150, noise: 60)
        frame.rows(4642 - frame.height, level: 255)

        let cropped = PageProcessor.crop(frame.image, dpi: 300)

        #expect(abs(cropped.height - 3300) <= 12, "height \(cropped.height)")
    }

    @Test func trimsBackingBesideANarrowDocument() {
        var frame = SyntheticPage(width: 1200)
        frame.rows(1200, level: 210, noise: 2)
        frame.fill(columns: 300..<900, rows: 100..<1000, level: 250)
        frame.fill(columns: 360..<840, rows: 180..<210, level: 20)

        let cropped = PageProcessor.crop(frame.image, dpi: 300)

        #expect(abs(cropped.width - 600) <= 12, "width \(cropped.width)")
        #expect(abs(cropped.height - 900) <= 12, "height \(cropped.height)")
    }

    @Test func leavesAFullLengthPageUncut() {
        var frame = SyntheticPage(width: 2544)
        frame.paper(4642, textLines: 40)

        let cropped = PageProcessor.crop(frame.image, dpi: 300)

        #expect(cropped.height == 4642, "\(cropped.width)x\(cropped.height)")
    }

    /// Some paper scans light gray, close to the backing. An FF-680W page it had already cropped:
    /// 8.39 x 11.06 in, paper ~230, a table in the top half, a note in the right margin, then blank.
    @Test func keepsBlankGrayPaperBelowTheContent() {
        var page = SyntheticPage(width: 2517)
        page.paper(3318, textLines: 15, level: 230, noise: 4)
        page.fill(columns: 2400..<2480, rows: 1900..<1980, level: 40)

        let cropped = PageProcessor.crop(page.image, dpi: 300)

        #expect(cropped.width >= 2517 - 24, "width \(cropped.width)")
        #expect(cropped.height >= 3318 - 24, "height \(cropped.height)")
    }

    /// Gray paper still loses the backing band below it: backing sits ~20 levels under the paper.
    @Test func cropsBackingBelowGrayPaper() {
        var frame = SyntheticPage(width: 2544)
        frame.rows(12, level: 210, noise: 2)
        frame.paper(3300, textLines: 20, level: 230, noise: 4)
        frame.rows(24, level: 150, noise: 60)
        frame.rows(105, level: 210, noise: 2)
        frame.rows(4642 - frame.height, level: 255)

        let cropped = PageProcessor.crop(frame.image, dpi: 300)

        #expect(cropped.width == 2544)
        #expect(abs(cropped.height - 3300) <= 12, "height \(cropped.height)")
    }

    @Test func blankPageWithNoiseSpecksAndBleedThroughIsBlank() {
        var page = SyntheticPage(width: 2544)
        page.rows(3300, level: 248, noise: 8)
        page.speckle(400, level: 0)
        page.bleedThrough(rows: 600..<1400, level: 190)

        #expect(PageProcessor.isBlank(page.image, dpi: 300))
    }

    @Test func lowContrastPhotoIsNotBlank() {
        var photo = SyntheticPage(width: 1800)
        for band in 0..<12 { photo.rows(100, level: UInt8(150 + band * 6), noise: 4) }

        #expect(!PageProcessor.isBlank(photo.image, dpi: 300))
    }

    @Test func pageWithOneLineOfTextIsNotBlank() {
        var page = SyntheticPage(width: 2544)
        page.paper(3300, textLines: 1)

        #expect(!PageProcessor.isBlank(page.image, dpi: 300))
    }
}
