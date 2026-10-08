import Foundation
import FoundationModels
import Testing
@testable import ScanKit

@Suite struct FilingSuggesterTests {
    let today = CalendarDate(year: 2026, month: 10, day: 7)!

    func context() throws -> (TemporaryTree, FolderIndex, DocumentEvidence, [Candidate]) {
        let tree = try TemporaryTree(sampleCabinet)
        let index = try FolderIndex.build(root: tree.root)
        let evidence = DocumentEvidence(text: sampleInvoiceText, today: today)
        return (tree, index, evidence, CandidateRanker.rank(evidence, in: index))
    }

    @Test func modelOutputIsHeldToTheFamilysRules() throws {
        let (_, index, evidence, candidates) = try context()
        let heuristic = HeuristicSuggester.suggest(evidence, candidates: candidates, index: index)
        let output = ModelFilingSuggestion(title: "Sierra Ridge service invoice", destination: "Vehicles/2021 Subaru Outback/Services",
                                           newSubfolder: "2026-10-08 30,000 Mile Service", fileName: "Invoice.pdf",
                                           reason: "Looks like the others.", confidence: "high")

        let accepted = FilingSuggester.accept(output, candidates: candidates, evidence: evidence, heuristic: heuristic)

        #expect(accepted.newSubfolder == "2026-10-07 30,000 Mile Service", "the event date is the document's")
        let copied = ModelFilingSuggestion(title: "t", destination: output.destination, newSubfolder: "2026-10-07 20,000 Mile Service",
                                           fileName: "Invoice", reason: "r", confidence: "high")
        #expect(FilingSuggester.accept(copied, candidates: candidates, evidence: evidence, heuristic: heuristic).newSubfolder
                == "2026-10-07 30,000 Mile Service", "the printed mileage wins over a sibling's")
        #expect(accepted.fileName == "Invoice", "the extension is added by the app")
        #expect(accepted.reason == "Same pattern as your 10,000 and 20,000 mile service folders.", "the shown reason is grounded")
    }

    @Test func aNewFolderIsDroppedWhereTheDestinationHoldsNoEvents() throws {
        let (_, index, evidence, candidates) = try context()
        let heuristic = HeuristicSuggester.suggest(evidence, candidates: candidates, index: index)
        let output = ModelFilingSuggestion(title: "t", destination: "Vehicles/2021 Subaru Outback/Parts",
                                           newSubfolder: "2026-10-07 Parts", fileName: "Invoice", reason: "r", confidence: "medium")

        let accepted = FilingSuggester.accept(output, candidates: candidates, evidence: evidence, heuristic: heuristic)

        #expect(accepted.folderPath == "Vehicles/2021 Subaru Outback/Parts")
        #expect(accepted.newSubfolder == nil)
    }

    @Test func thePromptFitsWellInsideTheContextWindow() throws {
        let (_, index, evidence, candidates) = try context()
        let longEvidence = DocumentEvidence(text: evidence.text + String(repeating: " fine print", count: 2000), today: today)

        let prompt = FilingPrompt(evidence: longEvidence, candidates: candidates, index: index, feedback: [])

        // ~3 characters per token for English is the documented conservative estimate.
        #expect(prompt.text.count / 3 < 4000, "\(prompt.text.count) characters")
        #expect(prompt.text.contains("1. Vehicles/2021 Subaru Outback/Services"))
    }

    @Test func feedbackIsStoredOnlyForChangesAndShownForTheSameVendorFirst() throws {
        let tree = try TemporaryTree([])
        let store = FilingFeedbackStore(url: tree.root.appending(path: "feedback.json"))
        let unchanged = FilingFeedback(title: "a", documentType: nil, vendor: nil, suggestedPath: "A", chosenPath: "A", suggestedName: "x", chosenName: "x")
        let other = FilingFeedback(date: .now, title: "Ring", documentType: "Receipt", vendor: "Jeweler", suggestedPath: "Receipts",
                                   chosenPath: "Wedding", suggestedName: "Receipt", chosenName: "Ring")
        let subaru = FilingFeedback(date: .distantPast, title: "Subaru", documentType: "Invoice", vendor: "Sierra Ridge Auto Care",
                                     suggestedPath: "Vehicles", chosenPath: "Vehicles/2021 Subaru Outback/Services",
                                     suggestedName: "Invoice", chosenName: "Invoice")

        try store.record(unchanged)
        try store.record(subaru)
        try store.record(other)

        #expect(store.load().map(\.title) == ["Subaru", "Ring"])
        let relevant = FilingFeedback.relevant(store.load(), to: DocumentEvidence(text: sampleInvoiceText, today: today), limit: 1)
        #expect(relevant.map(\.title) == ["Subaru"])
    }

    /// Runs the real on-device model. Opt in with FASTSCAN_MODEL_TESTS=1 on a Mac with Apple Intelligence.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FASTSCAN_MODEL_TESTS"] != nil && SystemLanguageModel.default.isAvailable))
    func theOnDeviceModelChoosesTheServicesFolder() async throws {
        let (_, index, evidence, _) = try context()

        let result = await FilingSuggester().suggest(evidence, index: index, feedback: [])

        #expect(result.source == .model)
        #expect(result.suggestion.destinationPath == "Vehicles/2021 Subaru Outback/Services/2026-10-07 30,000 Mile Service",
                "\(result.suggestion)")
    }
}
