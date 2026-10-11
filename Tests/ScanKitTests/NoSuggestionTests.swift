import Foundation
import Testing
@testable import ScanKit

@MainActor
@Suite struct NoSuggestionTests {
    let tree: TemporaryTree

    init() throws { tree = try TemporaryTree(["Inbox/", "Taxes/2025/"]) }

    func reader(suggests: Bool) -> BatchReader {
        var reader = BatchReader(root: tree.root, indexStore: FolderIndexStore(cacheURL: tree.root.appending(path: ".index.json")),
                                 suggester: FilingSuggester(useModel: false),
                                 feedbackStore: FilingFeedbackStore(url: tree.root.appending(path: ".feedback.json")),
                                 stagingDirectory: tree.root.appending(path: ".staging"))
        reader.suggests = suggests
        return reader
    }

    static let batch = Batch(sheets: [ScannedSheet(id: 0, front: ReencodeTests.stampedSide("2025 tax return"), back: nil)])

    @Test func withoutSuggestionsTheDocumentIsNamedForWhenItWasScanned() async throws {
        let document = try #require(try await reader(suggests: false).document(for: Self.batch))
        #expect(document.folderPath == CandidateRanker.inboxName)
        #expect(document.newSubfolder == nil)
        #expect(document.fileName.wholeMatch(of: /Scan \d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d/) != nil)
        #expect(document.result.candidates.isEmpty)
        #expect(document.pages.count == 1)
        #expect(FileManager.default.fileExists(atPath: document.stagedURL.path))
        // The folder index was never built.
        #expect(!FileManager.default.fileExists(atPath: tree.root.appending(path: ".index.json").path))
    }

    @Test func suggestionsStillLookAtTheCabinetByDefault() async throws {
        let document = try #require(try await reader(suggests: true).document(for: Self.batch))
        #expect(!document.result.candidates.isEmpty)
        #expect(FileManager.default.fileExists(atPath: tree.root.appending(path: ".index.json").path))
    }
}
