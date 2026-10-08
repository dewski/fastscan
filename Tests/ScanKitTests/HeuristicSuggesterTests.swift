import Foundation
import Testing
@testable import ScanKit

@Suite struct HeuristicSuggesterTests {
    let today = CalendarDate(year: 2026, month: 10, day: 7)!

    func suggest(_ text: String, in paths: [String]) throws -> FilingSuggestion {
        let tree = try TemporaryTree(paths)
        let index = try FolderIndex.build(root: tree.root)
        let evidence = DocumentEvidence(text: text, today: today)
        return HeuristicSuggester.suggest(evidence, candidates: CandidateRanker.rank(evidence, in: index), index: index)
    }

    @Test func servicedVehicleGetsANewDatedEventFolderNamedLikeItsSiblings() throws {
        let suggestion = try suggest(sampleInvoiceText, in: sampleCabinet)

        #expect(suggestion.folderPath == "Vehicles/2021 Subaru Outback/Services")
        #expect(suggestion.newSubfolder == "2026-10-07 30,000 Mile Service")
        #expect(suggestion.fileName == "Invoice")
        #expect(suggestion.reason == "Same pattern as your 10,000 and 20,000 mile service folders.")
        #expect(suggestion.confidence == .high)
        #expect(suggestion.destinationPath == "Vehicles/2021 Subaru Outback/Services/2026-10-07 30,000 Mile Service")
    }

    @Test func aSecondPaperFromTheSameEventGoesIntoTheExistingFolder() throws {
        let cabinet = sampleCabinet + ["Vehicles/2021 Subaru Outback/Services/2026-10-07 30,000 Mile Service/Receipt.pdf"]

        let suggestion = try suggest(sampleInvoiceText, in: cabinet)

        #expect(suggestion.folderPath == "Vehicles/2021 Subaru Outback/Services/2026-10-07 30,000 Mile Service")
        #expect(suggestion.newSubfolder == nil)
        #expect(suggestion.fileName == "Invoice")
    }

    @Test func aPlainFolderGetsADescriptiveDatedName() throws {
        let text = "VITALYN\nvitalyn.com\nRECEIPT\nOrder date Nov 1, 2025\nBlood panel"
        let cabinet = ["Medical/Vitalyn/Vitalyn 11-1-25 receipt.pdf", "Taxes/Taxes 2025/W2.pdf"]

        let suggestion = try suggest(text, in: cabinet)

        #expect(suggestion.folderPath == "Medical/Vitalyn")
        #expect(suggestion.newSubfolder == nil)
        #expect(suggestion.fileName == "Vitalyn Receipt 2025-11-01")
    }

    @Test func nothingMatchingSuggestsTheInbox() throws {
        let suggestion = try suggest("zzzz qqqq", in: sampleCabinet)

        #expect(suggestion.folderPath == "Inbox")
        #expect(suggestion.confidence == .low)
    }
}
