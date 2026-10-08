import Foundation
import FoundationModels

/// What the on-device model fills in. `destination` is constrained at run time to the candidate
/// paths, which a static `@Guide` can't express, so `schema(candidates:)` rebuilds the schema
/// with an `anyOf` guide while this type still decodes the result.
@Generable
struct ModelFilingSuggestion {
    @Guide(description: "A short plain-English title for the document, like 'Sierra Ridge Auto Care service invoice'.")
    var title: String
    var destination: String
    var newSubfolder: String?
    var fileName: String
    var reason: String
    var confidence: String
}

public struct SuggestionResult: Sendable {
    public enum Source: Sendable, Equatable {
        case model
        case heuristic(why: String)
    }

    public var suggestion: FilingSuggestion
    public var source: Source
    public var candidates: [Candidate]
    public var promptTokens: Int?
    public var elapsed: Duration
}

/// Suggests a folder and file name with Apple's on-device model, falling back to the heuristic
/// when the model is unavailable, slow, or refuses. Never touches the file system.
public struct FilingSuggester: Sendable {
    public var timeout: Duration
    public var candidateLimit: Int
    public var useModel: Bool

    public init(timeout: Duration = .seconds(40), candidateLimit: Int = 25, useModel: Bool = true) {
        self.timeout = timeout
        self.candidateLimit = candidateLimit
        self.useModel = useModel
    }

    public static var modelAvailability: String {
        switch SystemLanguageModel.default.availability {
        case .available: "available (context \(SystemLanguageModel.default.contextSize) tokens)"
        case .unavailable(let reason): "unavailable: \(reason)"
        }
    }

    public func suggest(_ evidence: DocumentEvidence, index: FolderIndex, feedback: [FilingFeedback]) async -> SuggestionResult {
        let started = ContinuousClock.now
        let candidates = CandidateRanker.rank(evidence, in: index, limit: candidateLimit)
        let heuristic = HeuristicSuggester.suggest(evidence, candidates: candidates, index: index)
        func fallback(_ why: String, tokens: Int? = nil) -> SuggestionResult {
            SuggestionResult(suggestion: heuristic, source: .heuristic(why: why), candidates: candidates,
                             promptTokens: tokens, elapsed: ContinuousClock.now - started)
        }

        guard useModel else { return fallback("the model was turned off") }
        guard !candidates.isEmpty else { return fallback("no folder matched, so there was nothing to choose from") }
        guard case .available = SystemLanguageModel.default.availability else {
            return fallback("the on-device model is \(Self.modelAvailability)")
        }
        guard #available(macOS 26.4, *) else { return fallback("candidate-constrained output needs macOS 26.4") }

        let prompt = FilingPrompt(evidence: evidence, candidates: candidates, index: index, feedback: feedback)
        let tokens = try? await SystemLanguageModel.default.tokenCount(for: prompt.text)
            + SystemLanguageModel.default.tokenCount(for: Instructions(FilingPrompt.instructions))
        do {
            let schema = Self.schema(candidates: candidates.map(\.path))
            let generated = try await withTimeout(timeout) {
                let session = LanguageModelSession(instructions: FilingPrompt.instructions)
                return try await session.respond(to: prompt.text, schema: schema,
                                                 options: GenerationOptions(samplingMode: .greedy)).content
            }
            let output = try ModelFilingSuggestion(generated)
            let suggestion = Self.accept(output, candidates: candidates, evidence: evidence, heuristic: heuristic)
            return SuggestionResult(suggestion: suggestion, source: .model, candidates: candidates,
                                    promptTokens: tokens, elapsed: ContinuousClock.now - started)
        } catch is TimeoutError {
            return fallback("the model took longer than \(timeout.formatted(.units(allowed: [.seconds])))", tokens: tokens)
        } catch {
            return fallback("the model failed: \(error.localizedDescription)", tokens: tokens)
        }
    }

    @available(macOS 26.4, *)
    static func schema(candidates: [String]) -> GenerationSchema {
        GenerationSchema(type: ModelFilingSuggestion.self, description: "Where to file a scanned document",
                             representNilExplicitlyInGeneratedContent: false, properties: [
            .init(name: "title", description: "Three to five words saying who it's from and what it is, like 'Sierra Ridge Auto Care service invoice'. No dates or years.",
                  type: String.self),
            .init(name: "destination", description: "The existing folder to file into, exactly as listed.",
                  type: String.self, guides: [.anyOf(candidates)]),
            .init(name: "newSubfolder", description: "Only when the destination holds dated event folders: a new one for this document, 'YYYY-MM-DD Event Name' using the document's date and the siblings' naming style. Otherwise omit.",
                  type: String?.self),
            .init(name: "fileName", description: "The file name without extension, following how files near the destination are named.",
                  type: String.self),
            .init(name: "reason", description: "One short sentence for the family naming the folders or files this follows.",
                  type: String.self),
            .init(name: "confidence", type: String.self, guides: [.anyOf(["high", "medium", "low"])]),
        ])
    }

    /// The model picks among candidates; this keeps its new folder and name to the family's rules.
    static func accept(_ output: ModelFilingSuggestion, candidates: [Candidate], evidence: DocumentEvidence,
                       heuristic: FilingSuggestion) -> FilingSuggestion {
        guard let candidate = candidates.first(where: { $0.path == output.destination }) else { return heuristic }
        var folderPath = candidate.path
        var newSubfolder = output.newSubfolder.map(sanitized).flatMap { $0.isEmpty ? nil : $0 }
        if !candidate.holdsEvents { newSubfolder = nil }
        // When a sibling's pattern is printed on the page, that text names the event: the model
        // sometimes copies a sibling's number ("20,000") instead of reading the paper's ("30,000").
        if newSubfolder != nil, let printed = HeuristicSuggester.patternedEventName(evidence, candidate) {
            newSubfolder = printed
        }
        if let date = evidence.date, let name = newSubfolder, CandidateRanker.eventDate(of: name) != date {
            newSubfolder = "\(date.iso) \(CandidateRanker.eventName(of: name))"
        }
        if let name = newSubfolder, candidate.folder.subfolders.contains(name) {
            folderPath += "/\(name)"
            newSubfolder = nil
        }
        var fileName = sanitized(output.fileName)
        if fileName.lowercased().hasSuffix(".pdf") { fileName = String(fileName.dropLast(4)) }
        // The reason shown is the grounded one, naming the sibling folders that actually matched;
        // the model's own sentence is used only when there's nothing specific to name.
        let grounded = HeuristicSuggester.reason(candidate)
        let modelReason = output.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = grounded == HeuristicSuggester.genericReason && !modelReason.isEmpty ? modelReason : grounded
        return FilingSuggestion(
            folderPath: folderPath, newSubfolder: newSubfolder,
            fileName: fileName.isEmpty ? heuristic.fileName : fileName,
            title: output.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? heuristic.title : output.title,
            reason: reason,
            confidence: FilingSuggestion.Confidence(rawValue: output.confidence) ?? .medium)
    }

    static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }
}

/// The prompt as plain data in, string out, so its size and content can be checked without the model.
struct FilingPrompt {
    static let instructions = """
        You file a family's scanned paper documents into their shared folders. Pick the destination \
        only from the numbered candidate folders. Some folders hold dated event folders named \
        'YYYY-MM-DD Event Name'; when the destination does, name a new event folder for this document \
        with its date and wording like its siblings (a paper that says '30,000 MILE SERVICE' next to \
        '2025-11-12 20,000 Mile Service' gets '2026-10-07 30,000 Mile Service'). Inside event folders \
        files are named by type, like 'Invoice' or 'Receipt'. Follow the family's past corrections.
        """
    static let textBudget = 2400

    var text: String

    init(evidence: DocumentEvidence, candidates: [Candidate], index: FolderIndex, feedback: [FilingFeedback]) {
        var lines: [String] = []
        lines.append("Document date: \(evidence.date?.iso ?? "unknown")")
        if let vendor = evidence.vendor { lines.append("From: \(vendor)") }
        if let type = evidence.documentType { lines.append("Looks like: \(type)") }
        for vehicle in evidence.vehicles { lines.append("VIN \(vehicle.vin): \(vehicle.year) \(vehicle.make)") }
        lines.append("")
        lines.append("Text (OCR, first part):")
        lines.append(String(evidence.text.prefix(Self.textBudget)))
        lines.append("")
        lines.append("Candidate folders, best match first:")
        for (number, candidate) in candidates.enumerated() {
            var line = "\(number + 1). \(candidate.path)"
            let events = candidate.eventSubfolders.suffix(4)
            if !events.isEmpty { line += "\n   event folders: \(events.joined(separator: "; "))" }
            let files = candidate.folder.exampleFiles.prefix(3)
            if !files.isEmpty { line += "\n   files: \(files.joined(separator: "; "))" }
            if let sample = candidate.eventSubfolders.last.flatMap({ index.folder(at: "\(candidate.path)/\($0)") }), !sample.exampleFiles.isEmpty {
                line += "\n   files in '\(sample.name)': \(sample.exampleFiles.prefix(3).joined(separator: "; "))"
            }
            lines.append(line)
        }
        let corrections = FilingFeedback.relevant(feedback, to: evidence, limit: 5)
        if !corrections.isEmpty {
            lines.append("")
            lines.append("Past corrections by the family:")
            for correction in corrections { lines.append("- \(correction.promptLine)") }
        }
        text = lines.joined(separator: "\n")
    }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
