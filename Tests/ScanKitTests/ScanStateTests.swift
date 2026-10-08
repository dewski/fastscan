import CoreGraphics
import Foundation
import Testing
@testable import ScanKit

func sampleSide(width: Double = 8.5, height: Double = 11, text: Double = 0.3, scene: Double = 0.1) -> ScannedSide {
    var page = SyntheticPage(width: 85)
    page.rows(110, level: 250)
    return ScannedSide(image: page.image, dpi: 10, lines: [],
                       features: SideFeatures(widthInches: width, heightInches: height, textCoverage: text,
                                              documentConfidence: text > 0 ? 0.8 : 0, sceneConfidence: scene, colorfulFraction: 0))
}

func samplePhotoSide() -> ScannedSide { sampleSide(width: 6, height: 4, text: 0, scene: 0.9) }

@Suite struct ScanStateTests {
    let scanner = ScannerEndpoint(name: "EPSON FF-680W", host: "EPSONDEMO01.local.", ipv4: "192.0.2.10", port: 1865)

    func run(_ events: [ScanState.Event], from state: ScanState = .looking) -> ScanState {
        events.reduce(state) { $0.on($1) }
    }

    let paperBatch = Batch(sheets: [ScannedSheet(id: 0, front: sampleSide(), back: nil)])
    let mixedBatch = Batch(sheets: [ScannedSheet(id: 0, front: sampleSide(), back: nil), ScannedSheet(id: 1, front: samplePhotoSide(), back: nil)])

    @Test func happyPathFromLookingToFiled() {
        let batch = paperBatch
        var filed = batch
        filed.recordFiling(document: FilingReceipt(fileURL: URL(filePath: "/c/Invoice.pdf"), createdFolders: [],
                                                   stagedURL: URL(filePath: "/s/Invoice.pdf"), relativePath: "Invoice.pdf"))
        let events: [ScanState.Event] = [.found(scanner), .start, .connected, .pageScanned, .pageScanned, .read(done: 2, total: 3),
                                         .review(batch), .file, .filedPart(filed)]
        let states = events.reduce(into: [ScanState.looking]) { $0.append($0.last!.on($1)) }

        #expect(states == [
            .looking, .ready(scanner), .starting(scanner, keptPages: 0), .scanning(scanner, pages: 0), .scanning(scanner, pages: 1),
            .scanning(scanner, pages: 2),
            .reading(scanner, done: 2, total: 3), .reviewing(scanner, batch, .document), .filing(scanner, batch, .document),
            .filed(scanner, filed),
        ])
    }

    @Test func aMixedBatchOpensTheMixedReviewAndOneAtATimeFocusesTheDocument() {
        let reviewing = run([.review(mixedBatch)], from: .reading(scanner, done: 1, total: 2))

        #expect(reviewing == .reviewing(scanner, mixedBatch, .mixed))
        #expect(reviewing.on(.focus(.document)) == .reviewing(scanner, mixedBatch, .document))
        #expect(run([.review(paperBatch), .focus(.mixed)], from: .reading(scanner, done: 1, total: 2)) == .reviewing(scanner, paperBatch, .document))
    }

    @Test func filingPartOfAMixedBatchReturnsToTheMixedReview() {
        var partly = mixedBatch
        partly.recordFiling(document: FilingReceipt(fileURL: URL(filePath: "/c/a.pdf"), createdFolders: [],
                                                    stagedURL: URL(filePath: "/s/a.pdf"), relativePath: "a.pdf"))

        let state = run([.file, .filedPart(partly)], from: .reviewing(scanner, mixedBatch, .document))

        #expect(state == .reviewing(scanner, partly, .mixed))
    }

    @Test func aJamKeepsSheetsAndCanResumeOrFinish() {
        let jammed = run([.start, .pageScanned, .pageScanned, .jammed(keptPages: 2)], from: .ready(scanner))

        #expect(jammed == .jammed(scanner, pages: 2))
        #expect(jammed.on(.resume(keptPages: 2)) == .starting(scanner, keptPages: 2))
        #expect(jammed.on(.resume(keptPages: 2)).on(.connected) == .scanning(scanner, pages: 2))
        #expect(jammed.on(.read(done: 2, total: 3)) == .reading(scanner, done: 2, total: 3))
        #expect(jammed.on(.start) == jammed)
    }

    @Test func undoReturnsToReviewWithTheRestoredBatch() {
        let restored = paperBatch

        #expect(run([.undone(restored)], from: .filed(scanner, paperBatch)) == .reviewing(scanner, restored, .document))
    }

    @Test func notFoundExplainsLocalNetworkDenialAndCanRetry() {
        let denied = run([.notFound(.localNetworkDenied)])

        #expect(denied == .notFound(.localNetworkDenied))
        #expect(denied.on(.discover) == .looking)
        #expect(denied.on(.start) == denied)
    }

    @Test func failureKeepsTheScannerForTheNextAttempt() {
        let failed = run([.failed("The feeder is empty.")], from: .scanning(scanner, pages: 0))

        #expect(failed == .failed(scanner, message: "The feeder is empty."))
        #expect(failed.on(.start) == .starting(scanner, keptPages: 0))
        #expect(!failed.isBusy)
    }

    @Test func busyStatesIgnoreAnotherStart() {
        let scanning = ScanState.scanning(scanner, pages: 3)

        #expect(scanning.on(.start) == scanning)
        #expect(scanning.on(.discover) == scanning)
        #expect(scanning.isBusy)
    }

    @Test func startingTheScannerIsBusyAndCanStopJamOrFail() {
        let starting = ScanState.starting(scanner, keptPages: 0)

        #expect(starting.isBusy)
        #expect(starting.on(.start) == starting)
        #expect(starting.on(.pageScanned) == .scanning(scanner, pages: 1), "a page that lands first still counts")
        #expect(starting.on(.cancelled) == .ready(scanner))
        #expect(starting.on(.jammed(keptPages: 0)) == .jammed(scanner, pages: 0))
        #expect(starting.on(.failed("Lost contact.")) == .failed(scanner, message: "Lost contact."))
    }

    @Test func aFlipThatEmptiesThePhotosStaysInTheMixedReviewUntilTheDocumentIsRebuilt() {
        var flipped = mixedBatch
        flipped.flip(1)
        var rebuilt = flipped
        rebuilt.setDocument(nil)

        let reviewing = ScanState.reviewing(scanner, mixedBatch, .mixed)

        #expect(reviewing.on(.revise(flipped)) == .reviewing(scanner, flipped, .mixed))
        #expect(reviewing.on(.revise(flipped)).on(.revise(rebuilt)) == .reviewing(scanner, rebuilt, .document))
    }

    @Test func cancellingReturnsToReady() {
        #expect(run([.cancelled], from: .scanning(scanner, pages: 2)) == .ready(scanner))
        #expect(run([.done], from: .reviewing(scanner, paperBatch, .document)) == .ready(scanner))
    }
}

@Suite struct BatchTests {
    @Test func itemsAreOneDocumentForThePaperAndOnePhotoPerPrint() {
        let batch = Batch(sheets: [
            ScannedSheet(id: 0, front: sampleSide(), back: sampleSide()),
            ScannedSheet(id: 1, front: samplePhotoSide(), back: sampleSide(width: 6, height: 4, text: 0.02)),
            ScannedSheet(id: 2, front: samplePhotoSide(), back: nil),
        ])

        #expect(batch.paperSheets.map(\.id) == [0])
        #expect(batch.photos.map(\.id) == [1, 2])
        #expect(batch.isMixed)
    }

    @Test func flippingASheetMovesItBetweenPaperAndPhotosAndBack() {
        var batch = Batch(sheets: [ScannedSheet(id: 0, front: sampleSide(), back: nil), ScannedSheet(id: 1, front: samplePhotoSide(), back: nil)])
        let before = batch

        batch.flip(1)

        #expect(batch.paperSheets.map(\.id) == [0, 1])
        #expect(batch.photos.isEmpty)
        #expect(batch != before, "a flip is a new revision")
        #expect(batch.isRebuildingDocument, "the document no longer matches the paper sheets")
        batch.flip(1)
        #expect(batch.photos.map(\.id) == [1])
        #expect(batch.kindOverrides.isEmpty, "flipping back to the detected kind leaves no override")
    }

    @Test func sidesPairIntoSheetsAndBlankSheetsDisappear() {
        let sides: [Int: ScannedSide] = [0: sampleSide(), 2: sampleSide(), 3: sampleSide()]

        let sheets = BatchReader.sheets(from: sides, pageCount: 6, firstSheetID: 4)

        #expect(sheets.map(\.id) == [4, 5])
        #expect(sheets[0].back == nil)
        #expect(sheets[1].back != nil)
    }
}
