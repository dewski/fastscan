import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ScanKit

/// A whole scan through ScanJob, against a scripted scanner, stopped by the scanner's Stop button.
@MainActor
@Suite struct ScanJobStopTests {
    let scanner = ScannerEndpoint(name: "EPSON FF-680W", host: "EPSONDEMO01.local.", ipv4: "192.0.2.10", port: 1865)
    let tree: TemporaryTree

    init() throws { tree = try TemporaryTree(["Inbox/"]) }

    func job(_ script: ScriptedScanner) -> ScanJob {
        let job = ScanJob(reader: BatchReader(root: tree.root, indexStore: FolderIndexStore(cacheURL: tree.root.appending(path: ".index.json")),
                                              suggester: FilingSuggester(useModel: false),
                                              feedbackStore: FilingFeedbackStore(url: tree.root.appending(path: ".feedback.json")),
                                              stagingDirectory: tree.root.appending(path: ".staging")),
                          photoWriter: DryRunPhotoWriter(directory: tree.root.appending(path: ".photos")))
        job.transport = { _ in script }
        job.send(.found(scanner))
        return job
    }

    /// The app's scan (two-sided, 300 dpi), these IMG replies, then the Stop button.
    static func stoppedScan(_ replies: [ScriptedScanner.Step]) -> ScriptedScanner {
        ScriptedScanner(
            ScriptedScanner.opening()
                + ScriptedScanner.startingScan(sides: .duplex, dpi: 300, length: 3600)
                + replies
                + ScriptedScanner.command("IMG", tokens: "#typIMGA#atnCAN ")
                + ScriptedScanner.command("CAN")
                + ScriptedScanner.command("FIN")
                + [ScriptedScanner.unlock]
        )
    }

    @Test func stoppingBeforeAnyPageGoesBackToReady() async {
        let script = Self.stoppedScan(ScriptedScanner.command("IMG") + ScriptedScanner.command("IMG"))
        let job = job(script)
        await job.scan()
        #expect(job.state == .ready(scanner))
        #expect(await script.unmatched == [])
        #expect(await script.finished)
    }

    @Test func stoppingAfterAPageStillReviewsIt() async throws {
        let image = PageEncoderTests.stampedPage.image
        let page = try Self.jpeg(image)
        let size = "i\(ESCI2.decimalDigits(image.width, count: 7))"
        let script = Self.stoppedScan(
            ScriptedScanner.command("IMG", tokens: "#pst\(size)d000i\(ESCI2.decimalDigits(image.height, count: 7))#typIMGA", data: page)
                + ScriptedScanner.command("IMG", tokens: "#pen\(size)i\(ESCI2.decimalDigits(image.height, count: 7))#typIMGA")
        )
        let job = job(script)
        await job.scan()
        guard case .reviewing(_, let batch, _) = job.state else {
            Issue.record("expected review, got \(job.state)")
            return
        }
        // The front is kept even though its back never arrived.
        #expect(batch.sheets.count == 1)
        #expect(batch.sheets.first?.front != nil)
        #expect(batch.sheets.first?.back == nil)
        #expect(await script.unmatched == [])
    }

    static func jpeg(_ image: CGImage) throws -> [UInt8] {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return [UInt8](data as Data)
    }
}
