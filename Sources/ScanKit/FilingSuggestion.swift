import Foundation

/// Where a document should go and what to call it. Paths are relative to the filing cabinet root.
public struct FilingSuggestion: Sendable, Equatable, Codable {
    public enum Confidence: String, Sendable, Codable, Comparable {
        case low, medium, high

        public static func < (a: Confidence, b: Confidence) -> Bool {
            [Confidence.low, .medium, .high].firstIndex(of: a)! < [Confidence.low, .medium, .high].firstIndex(of: b)!
        }
    }

    public var folderPath: String
    /// A folder to create inside `folderPath`, such as `2026-10-07 30,000 Mile Service`.
    public var newSubfolder: String?
    public var fileName: String
    public var title: String
    public var reason: String
    public var confidence: Confidence

    public init(folderPath: String, newSubfolder: String?, fileName: String, title: String, reason: String, confidence: Confidence) {
        self.folderPath = folderPath
        self.newSubfolder = newSubfolder
        self.fileName = fileName
        self.title = title
        self.reason = reason
        self.confidence = confidence
    }

    public var destinationPath: String {
        guard let newSubfolder else { return folderPath }
        return folderPath.isEmpty ? newSubfolder : "\(folderPath)/\(newSubfolder)"
    }

    public static func inbox(title: String, fileName: String, reason: String) -> FilingSuggestion {
        FilingSuggestion(folderPath: CandidateRanker.inboxName, newSubfolder: nil, fileName: fileName,
                         title: title, reason: reason, confidence: .low)
    }
}

/// The deterministic suggestion: the best-ranked folder and a name in the family's own patterns.
/// Used when the on-device model is unavailable or slow, and as the model's fallback.
public enum HeuristicSuggester {
    public static func suggest(_ evidence: DocumentEvidence, candidates: [Candidate], index: FolderIndex) -> FilingSuggestion {
        let title = evidence.title
        guard let top = candidates.first else {
            return .inbox(title: title, fileName: fallbackFileName(evidence), reason: "No folder looked like a match.")
        }
        var folderPath = top.path
        var newSubfolder: String?
        var inEventFolder = CandidateRanker.eventDate(of: top.folder.name) != nil

        if top.holdsEvents, let date = evidence.date {
            let name = "\(date.iso) \(eventName(evidence, top))"
            if top.folder.subfolders.contains(name) {
                folderPath += "/\(name)"
            } else {
                newSubfolder = name
            }
            inEventFolder = true
        }

        let fileName = inEventFolder ? eventFileName(evidence, top, index) : fallbackFileName(evidence)
        return FilingSuggestion(folderPath: folderPath, newSubfolder: newSubfolder, fileName: fileName, title: title,
                                reason: reason(top), confidence: confidence(candidates))
    }

    /// The name a sibling event's pattern finds in the text (`30,000 Mile Service`), else the title.
    static func eventName(_ evidence: DocumentEvidence, _ candidate: Candidate) -> String {
        patternedEventName(evidence, candidate) ?? evidence.title.capitalized
    }

    /// The text a sibling event's pattern finds on the page, such as `30,000 Mile Service`.
    static func patternedEventName(_ evidence: DocumentEvidence, _ candidate: Candidate) -> String? {
        for event in candidate.matchedEvents + candidate.eventSubfolders {
            if let name = EventPattern(CandidateRanker.eventName(of: event))?.firstMatch(in: evidence.text) { return name }
        }
        return nil
    }

    /// Inside event folders the family names files by type alone: `Invoice.pdf`, `Receipt.pdf`.
    static func eventFileName(_ evidence: DocumentEvidence, _ candidate: Candidate, _ index: FolderIndex) -> String {
        let siblingFiles = candidate.eventSubfolders
            .compactMap { index.folder(at: "\(candidate.path)/\($0)") }
            .flatMap(\.exampleFiles)
            .map { ($0 as NSString).deletingPathExtension }
        if let type = evidence.documentType,
           let match = siblingFiles.first(where: { $0.caseInsensitiveCompare(type) == .orderedSame }) {
            return match
        }
        return evidence.documentType ?? "Document"
    }

    static func fallbackFileName(_ evidence: DocumentEvidence) -> String {
        let base = evidence.title.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return evidence.date.map { "\(base) \($0.iso)" } ?? base
    }

    static func reason(_ candidate: Candidate) -> String {
        let names = candidate.matchedEvents.map(CandidateRanker.eventName(of:))
        if names.count >= 2 {
            let suffixes = Set(names.map { $0.drop { !$0.isLetter }.lowercased() })
            if suffixes.count == 1, let suffix = suffixes.first, !suffix.isEmpty {
                let numbers = names.map { $0.prefix { !$0.isLetter }.trimmingCharacters(in: .whitespaces) }
                return "Same pattern as your \(list(numbers)) \(suffix) folders."
            }
            return "Next to your \(list(names.prefix(3).map { "“\($0)”" })) folders."
        }
        if let only = names.first { return "Next to your “\(only)” folder." }
        if !candidate.matchedTerms.isEmpty {
            return "The folder’s name matches \(list(candidate.matchedTerms.prefix(3).map { "“\($0)”" })) on the page."
        }
        return genericReason
    }

    static let genericReason = "The closest match among your folders."

    static func confidence(_ candidates: [Candidate]) -> FilingSuggestion.Confidence {
        guard let top = candidates.first else { return .low }
        let runnerUp = candidates.dropFirst().first?.score ?? 0
        let margin = runnerUp > 0 ? (top.score - runnerUp) / top.score : 1
        if top.score < 12 || margin < 0.03 { return .low }
        if margin >= 0.2 || (top.holdsEvents && !top.matchedEvents.isEmpty) { return .high }
        return .medium
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
