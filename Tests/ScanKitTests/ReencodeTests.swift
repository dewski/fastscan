import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import ScanKit

@MainActor
@Suite struct ReencodeTests {
    let scanner = ScannerEndpoint(name: "EPSON FF-680W", host: "EPSONDEMO01.local.", ipv4: "192.0.2.10", port: 1865)
    let tree: TemporaryTree

    init() throws { tree = try TemporaryTree(["Inbox/"]) }

    var reader: BatchReader {
        BatchReader(root: tree.root, indexStore: FolderIndexStore(cacheURL: tree.root.appending(path: ".index.json")),
                    suggester: FilingSuggester(useModel: false),
                    feedbackStore: FilingFeedbackStore(url: tree.root.appending(path: ".feedback.json")),
                    stagingDirectory: tree.root.appending(path: ".staging"))
    }

    /// A stamped paper side whose OCR text is `text`, so its page can be told apart from the others.
    static func stampedSide(_ text: String? = nil) -> ScannedSide {
        ScannedSide(image: PageEncoderTests.stampedPage.image, dpi: 300,
                    lines: text.map { [RecognizedLine(text: $0, normalizedBox: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.04))] } ?? [],
                    features: SideFeatures(widthInches: 8.5, heightInches: 11, textCoverage: 0.3, documentConfidence: 0.8,
                                           sceneConfidence: 0.1, colorfulFraction: 0.01))
    }

    static let twoSheets = [ScannedSheet(id: 0, front: stampedSide("f1"), back: stampedSide("b1")),
                            ScannedSheet(id: 1, front: stampedSide("f2"), back: stampedSide("b2"))]

    /// A job reviewing `sheets`, encoded automatically, so stamped pages start in color.
    func reviewingJob(_ sheets: [ScannedSheet] = [ScannedSheet(id: 0, front: stampedSide(), back: stampedSide())]) async throws -> ScanJob {
        let job = ScanJob(reader: reader, photoWriter: DryRunPhotoWriter(directory: tree.root.appending(path: ".photos")))
        var batch = Batch(sheets: sheets)
        batch.setDocument(try await job.reader.document(for: batch))
        for event: ScanState.Event in [.found(scanner), .start, .read(done: 2, total: 3), .review(batch)] { job.send(event) }
        let document = try #require(job.state.batch?.document)
        #expect(document.pages.allSatisfy { !$0.isGray })
        return job
    }

    func stagingLeftovers(_ job: ScanJob) throws -> [String] {
        let folder = try #require(job.state.batch?.document?.stagedURL.deletingLastPathComponent())
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".reencode") }
    }

    /// Checks each page's text in the draft and in the staged PDF's text layer.
    func expectPages(_ job: ScanJob, _ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let document = try #require(job.state.batch?.document, sourceLocation: sourceLocation)
        let pdf = try #require(PDFDocument(url: document.stagedURL), sourceLocation: sourceLocation)
        let pdfTexts = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        #expect(document.pages.map { $0.lines.map(\.text).joined() } == expected, sourceLocation: sourceLocation)
        #expect(pdfTexts == expected, "staged PDF", sourceLocation: sourceLocation)
    }

    @Test func choosingAColorModeReencodesThePagesAndTheStagedPDF() async throws {
        let job = try await reviewingJob()
        let before = try Data(contentsOf: try #require(job.state.batch?.document?.stagedURL))

        let task = try #require(job.chooseColor(.grayscale))
        #expect(job.state.batch?.document?.isReencoding == true, "the wait shows before the pages are ready")
        await task.value

        let document = try #require(job.state.batch?.document)
        #expect(document.encoding.color == .grayscale && !document.isReencoding)
        #expect(document.pages.count == 2 && document.pages.allSatisfy { $0.isGray })
        let after = try Data(contentsOf: document.stagedURL)
        #expect(after != before && after.count < before.count, "\(before.count) -> \(after.count) bytes")
        #expect(try stagingLeftovers(job).isEmpty)
    }

    @Test func theLatestColorChoiceWinsUnderRapidChanges() async throws {
        let job = try await reviewingJob()

        let tasks = [ColorMode.grayscale, .color, .automatic, .grayscale, .color, .grayscale].compactMap { job.chooseColor($0) }
        for task in tasks { await task.value }

        let document = try #require(job.state.batch?.document)
        #expect(document.encoding.color == .grayscale && document.pagesEncoding.color == .grayscale)
        #expect(document.pages.allSatisfy { $0.isGray })
        #expect(try stagingLeftovers(job).isEmpty)
    }

    @Test func choosingBackTheModeThePagesHoldCancelsTheWait() async throws {
        let job = try await reviewingJob()

        let pending = job.chooseColor(.grayscale)
        #expect(job.chooseColor(.automatic) == nil)
        await pending?.value

        let document = try #require(job.state.batch?.document)
        #expect(document.encoding.color == .automatic && !document.isReencoding)
        #expect(document.pages.allSatisfy { !$0.isGray })
    }

    @Test func aSupersededReencodeIsDropped() async throws {
        let job = try await reviewingJob()
        var document = try #require(job.state.batch?.document)
        let batchID = try #require(job.state.batch?.id)
        func reencoded(_ encoding: PageEncoding, sheets: [Int] = [0]) -> ReencodedPages {
            ReencodedPages(batchID: batchID, sheetIDs: sheets, encoding: encoding, pages: [], pdf: URL(filePath: "/dev/null"))
        }
        let gray = PageEncoding(color: .grayscale)

        document.encoding = gray

        #expect(document.accepts(reencoded(gray)))
        #expect(!document.accepts(reencoded(PageEncoding(color: .color))), "an earlier color")
        #expect(!document.accepts(reencoded(PageEncoding(color: .grayscale, selection: .frontsOnly))), "an earlier page selection")
        #expect(!document.accepts(reencoded(gray, sheets: [0, 1])), "pages for sheets since flipped")
        document.setPages([], encodedAs: gray)
        #expect(!document.accepts(reencoded(gray)), "already applied")
    }

    @Test func frontsOnlyRemovesExactlyTheBacksAndAllSidesBringsThemBack() async throws {
        let job = try await reviewingJob(Self.twoSheets)
        try expectPages(job, ["f1", "b1", "f2", "b2"])

        let task = try #require(job.choosePages(.frontsOnly))
        #expect(job.state.batch?.document?.isReencoding == true, "the wait shows, and filing waits, until the pages land")
        await task.value
        try expectPages(job, ["f1", "f2"])
        #expect(job.state.batch?.document?.isReencoding == false)

        await job.choosePages(.allSides)?.value
        try expectPages(job, ["f1", "b1", "f2", "b2"])
        #expect(try stagingLeftovers(job).isEmpty)
    }

    @Test func blankBacksNeverReturnAndAFaceDownSheetKeepsItsPrintedSide() async throws {
        let job = try await reviewingJob([ScannedSheet(id: 0, front: Self.stampedSide("f1"), back: Self.stampedSide("b1")),
                                          ScannedSheet(id: 1, front: Self.stampedSide("f2"), back: nil),
                                          ScannedSheet(id: 2, front: nil, back: Self.stampedSide("b3"))])
        try expectPages(job, ["f1", "b1", "f2", "b3"])

        await job.choosePages(.frontsOnly)?.value
        try expectPages(job, ["f1", "f2", "b3"])

        await job.choosePages(.allSides)?.value
        try expectPages(job, ["f1", "b1", "f2", "b3"])
    }

    @Test func rapidPageAndColorChoicesSettleOnTheLatestOfBoth() async throws {
        let job = try await reviewingJob(Self.twoSheets)

        let tasks = [
            job.choosePages(.frontsOnly), job.chooseColor(.grayscale), job.choosePages(.allSides), job.chooseColor(.color),
            job.choosePages(.frontsOnly), job.chooseColor(.automatic), job.chooseColor(.grayscale),
        ].compactMap { $0 }
        for task in tasks { await task.value }

        let document = try #require(job.state.batch?.document)
        let latest = PageEncoding(color: .grayscale, selection: .frontsOnly)
        #expect(document.encoding == latest && document.pagesEncoding == latest)
        try expectPages(job, ["f1", "f2"])
        #expect(document.pages.allSatisfy { $0.isGray })
        #expect(try stagingLeftovers(job).isEmpty)
    }

    @Test func frontsOnlyLeavesTheSuggestionAlone() async throws {
        let job = try await reviewingJob(Self.twoSheets)
        let before = try #require(job.state.batch?.document)

        await job.choosePages(.frontsOnly)?.value

        let after = try #require(job.state.batch?.document)
        #expect(after.pages.count == 2)
        #expect(after.evidence == before.evidence && after.suggestion == before.suggestion)
        #expect(after.fileName == before.fileName && after.destinationPath == before.destinationPath)
    }

    @Test func frontsOnlyIsOfferedOnlyWhenAPaperSheetHasABack() {
        let paper = ScannedSheet(id: 0, front: Self.stampedSide(), back: nil)
        let faceDown = ScannedSheet(id: 1, front: nil, back: Self.stampedSide())
        let photoWithCaption = ScannedSheet(id: 2, front: samplePhotoSide(), back: Self.stampedSide("Tahoe"))
        let twoSided = ScannedSheet(id: 3, front: Self.stampedSide(), back: Self.stampedSide())

        #expect(!Batch(sheets: [paper, faceDown, photoWithCaption]).documentHasBacks, "no paper back to leave out")
        #expect(Batch(sheets: [paper, twoSided]).documentHasBacks)
    }
}
