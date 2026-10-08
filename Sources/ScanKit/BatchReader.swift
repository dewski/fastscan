import CoreGraphics
import Foundation

/// Turns scanned pages into a reviewable batch: reads each side as it arrives, then builds the
/// document's PDF and filing suggestion. Shared by the app and the CLI.
public struct BatchReader: Sendable {
    public enum WhenUnsure: String, Sendable, CaseIterable {
        case inbox, bestGuess
    }

    public var root: URL
    public var indexStore: FolderIndexStore
    public var suggester: FilingSuggester
    public var feedbackStore: FilingFeedbackStore
    public var stagingDirectory: URL
    public var whenUnsure: WhenUnsure
    /// The color mode a new document starts with.
    public var colorMode: ColorMode

    public init(root: URL, indexStore: FolderIndexStore = FolderIndexStore(), suggester: FilingSuggester = FilingSuggester(),
                feedbackStore: FilingFeedbackStore = FilingFeedbackStore(),
                stagingDirectory: URL = URL.applicationSupportDirectory.appending(path: "FastScan/Staging", directoryHint: .isDirectory),
                whenUnsure: WhenUnsure = .inbox, colorMode: ColorMode = .automatic) {
        self.root = root
        self.indexStore = indexStore
        self.suggester = suggester
        self.feedbackStore = feedbackStore
        self.stagingDirectory = stagingDirectory
        self.whenUnsure = whenUnsure
        self.colorMode = colorMode
    }

    @concurrent
    public static func read(_ raw: RawPage) async throws -> ScannedSide? {
        let cropped = PageProcessor.crop(raw.image, dpi: raw.dpi)
        if PageProcessor.isBlank(cropped, dpi: raw.dpi) { return nil }
        let lines = try await TextRecognizer.recognize(cropped)
        let features = try await SideFeatures.measure(cropped, dpi: raw.dpi, lines: lines)
        return ScannedSide(image: cropped, dpi: raw.dpi, lines: lines, features: features)
    }

    /// Pairs sides into sheets. The feeder scans front then back, so raw page 2n is sheet n's front.
    /// A sheet with both sides blank isn't a sheet anyone wants back.
    public static func sheets(from sides: [Int: ScannedSide], pageCount: Int, firstSheetID: Int = 0) -> [ScannedSheet] {
        stride(from: 0, to: pageCount, by: 2).compactMap { index in
            let sheet = ScannedSheet(id: firstSheetID + index / 2, front: sides[index], back: sides[index + 1])
            return sheet.front == nil && sheet.back == nil ? nil : sheet
        }
    }

    /// The batch's document for its current paper sheets. An existing draft keeps the family's
    /// edits and suggestion; only its pages and PDF are rebuilt.
    public func document(for batch: Batch, today: CalendarDate = CalendarDate(.now)) async throws -> DocumentDraft? {
        let paper = batch.paperSheets
        guard !paper.isEmpty else { return nil }
        let encoding = batch.document?.encoding ?? PageEncoding(color: colorMode)
        let pages = try await Self.encode(paper, as: encoding)
        // Every side, whatever the selection, so choosing Fronts only never moves the document.
        let text = paper.flatMap(\.sides).map(\.text).joined(separator: "\n")

        var draft: DocumentDraft
        if let existing = batch.document {
            draft = existing
            draft.sheetIDs = paper.map(\.id)
            draft.setPages(pages, encodedAs: encoding)
        } else {
            let evidence = DocumentEvidence(text: text, today: today)
            let index = try await indexStore.current(root: root)
            let result = await suggester.suggest(evidence, index: index, feedback: feedbackStore.load())
            var suggestion = result.suggestion
            if suggestion.confidence == .low, whenUnsure == .inbox {
                suggestion.folderPath = CandidateRanker.inboxName
                suggestion.newSubfolder = nil
            }
            draft = DocumentDraft(sheetIDs: paper.map(\.id), pages: pages, encoding: encoding, stagedURL: URL(filePath: "/"), evidence: evidence,
                                  result: SuggestionResult(suggestion: suggestion, source: result.source, candidates: result.candidates,
                                                           promptTokens: result.promptTokens, elapsed: result.elapsed),
                                  fileName: suggestion.fileName, folderPath: suggestion.folderPath, newSubfolder: suggestion.newSubfolder)
        }
        draft.stagedURL = try stage(pages, named: draft.fileName, batch: batch.id)
        return draft
    }

    /// Writes the PDF under the staging folder with its current name, so a drag carries that name.
    public func stage(_ pages: [StoredPage], named name: String, batch: UUID) throws -> URL {
        let folder = stagingDirectory.appending(path: batch.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(Filer.safeFileName(name)).pdf")
        try PDFBuilder.write(pages, to: url)
        return url
    }

    /// Encodes the document's pages again from the retained 300 dpi scans, without rescanning.
    /// The PDF goes to its own file beside the staged one, so re-encodes that overlap never write
    /// the same file.
    @concurrent
    public func reencode(_ batch: Batch, as encoding: PageEncoding) async throws -> ReencodedPages {
        let paper = batch.paperSheets
        let pages = try await Self.encode(paper, as: encoding)
        try Task.checkCancellation()
        let folder = stagingDirectory.appending(path: batch.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appending(path: ".reencode-\(UUID().uuidString).pdf")
        try PDFBuilder.write(pages, to: pdf)
        return ReencodedPages(batchID: batch.id, sheetIDs: paper.map(\.id), encoding: encoding, pages: pages, pdf: pdf)
    }

    static func encode(_ sheets: [ScannedSheet], as encoding: PageEncoding) async throws -> [StoredPage] {
        let sides = sheets.flatMap { $0.sides(encoding.selection) }
        return try await withThrowingTaskGroup(of: (Int, StoredPage).self) { group in
            for (offset, side) in sides.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    return (offset, try PageEncoder.encode(side.processed, mode: encoding.color))
                }
            }
            var pages: [(Int, StoredPage)] = []
            for try await page in group { pages.append(page) }
            return pages.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
