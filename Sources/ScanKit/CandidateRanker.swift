import Foundation

public struct Candidate: Sendable, Equatable {
    public var folder: FolderIndex.Folder
    public var score: Double
    public var matchedTerms: [String]
    /// Subfolders named `YYYY-MM-DD Event`, which is where a new event folder would go.
    public var eventSubfolders: [String]
    /// Event subfolders whose names share words with the document, such as `10,000 Mile Service`.
    public var matchedEvents: [String]

    public var path: String { folder.path }
    public var holdsEvents: Bool { eventSubfolders.count >= 2 && eventSubfolders.count * 2 >= folder.subfolders.count }
}

/// Scores every folder against a document so only the best few dozen reach the on-device model,
/// whose context holds a few thousand tokens. Pure: the same index and evidence give the same list.
public enum CandidateRanker {
    public static let inboxName = "Inbox"

    public static func rank(_ evidence: DocumentEvidence, in index: FolderIndex, limit: Int = 30) -> [Candidate] {
        let idf = inverseFrequencies(index)
        let byPath = Dictionary(uniqueKeysWithValues: index.folders.map { ($0.path, $0) })
        let vehicleTerms = evidence.vehicles.map { [String($0.year), $0.make.lowercased()] }

        let candidates = index.folders.compactMap { folder -> Candidate? in
            // `_files` folders hold a saved web page's resources, not filed papers.
            guard !folder.path.isEmpty, folder.components.first != inboxName, !folder.name.hasSuffix("_files") else { return nil }
            var score = 0.0
            var matched: [String] = []

            // Words in the folder's own name count most, its parents' less. A word counts once, at the
            // depth nearest the folder, so deep folders don't win by accumulating incidental matches.
            let components = folder.components
            var weights: [String: Double] = [:]
            for (depth, component) in components.reversed().enumerated() {
                let weight = depth == 0 ? 1 : max(0.3, 0.7 - 0.15 * Double(depth - 1))
                for term in DocumentEvidence.normalizedTerms(component) where weights[term] == nil { weights[term] = weight }
            }
            for (term, weight) in weights {
                guard let count = evidence.terms[term] else { continue }
                score += (idf[term] ?? 1) * weight * min(2, 1 + log(Double(count)))
                matched.append(term)
            }

            // A VIN pins the subject: the folder named for that year and make, and everything in it.
            let pathTerms = Set(components.flatMap(DocumentEvidence.normalizedTerms))
            if vehicleTerms.contains(where: { $0.allSatisfy(pathTerms.contains) }) { score += 8 }

            // Sibling events with the document's own pattern (`10,000 Mile Service` for a paper that says
            // `30,000 MILE SERVICE`) are the strongest sign; events whose words all appear somewhere are weaker.
            let events = folder.subfolders.filter { eventDate(of: $0) != nil }
            let patterned = events.filter { EventPattern(eventName(of: $0))?.firstMatch(in: evidence.text) != nil }
            let worded = events.filter { event in
                let words = Set(DocumentEvidence.normalizedTerms(eventName(of: event)))
                return !words.isEmpty && words.allSatisfy { evidence.terms[$0] != nil }
            }
            let matchedEvents = patterned.isEmpty ? worded : patterned
            score += patterned.isEmpty ? min(2, Double(worded.count)) : 8

            // An existing event folder is the right place only for a paper from that same day.
            if let date = eventDate(of: folder.name) {
                score = date == evidence.date ? score + 6 : score * 0.4
            }

            let fileTerms = Set(folder.exampleFiles.flatMap { DocumentEvidence.normalizedTerms(($0 as NSString).deletingPathExtension) })
            let eventFileTerms = Set(events.compactMap { byPath[folder.path + "/" + $0] }.flatMap(\.exampleFiles)
                .flatMap { DocumentEvidence.normalizedTerms(($0 as NSString).deletingPathExtension) })
            if let type = evidence.documentType?.lowercased(), fileTerms.contains(type) || eventFileTerms.contains(type) {
                score += 1.5
            }

            guard score > 0 else { return nil }
            return Candidate(folder: folder, score: score, matchedTerms: Array(Set(matched)).sorted(),
                             eventSubfolders: events, matchedEvents: matchedEvents)
        }
        return Array(candidates.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }.prefix(limit))
    }

    /// Rare folder words (`outback`) say more than common ones (`receipts`).
    static func inverseFrequencies(_ index: FolderIndex) -> [String: Double] {
        var counts: [String: Int] = [:]
        for folder in index.folders {
            for term in Set(DocumentEvidence.normalizedTerms(folder.name)) { counts[term, default: 0] += 1 }
        }
        let total = Double(index.folders.count)
        return counts.mapValues { log(1 + total / Double($0)) }
    }

    public static func eventDate(of name: String) -> CalendarDate? {
        let parts = name.prefix(10).split(separator: "-")
        guard name.count > 11, parts.count == 3, name[name.index(name.startIndex, offsetBy: 10)] == " ",
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return CalendarDate(year: year, month: month, day: day)
    }

    public static func eventName(of name: String) -> String {
        eventDate(of: name) == nil ? name : String(name.dropFirst(11))
    }
}

/// An event folder's name with its numbers generalized, so `10,000 Mile Service` finds
/// `30,000 MILE SERVICE` or `30, 000 Mile Service` in OCR text and can name the new folder in kind.
public struct EventPattern {
    private let regex: NSRegularExpression

    /// Nil when the name has no number: a pattern of plain words would match too loosely.
    public init?(_ eventName: String) {
        guard eventName.contains(where: \.isNumber) else { return nil }
        var pattern = ""
        var inNumber = false
        for character in eventName {
            if character.isNumber || (inNumber && (character == "," || character == ".")) {
                if !inNumber { pattern += "\\d[\\d,. ]*" }
                inNumber = true
            } else {
                inNumber = false
                pattern += character == " " ? "\\s+" : NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])" + pattern + "(?![A-Za-z])", options: .caseInsensitive)
        else { return nil }
        self.regex = regex
    }

    public func firstMatch(in text: String) -> String? {
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else { return nil }
        let words = nsText.substring(with: match.range).replacingOccurrences(of: ", ", with: ",")
            .split(whereSeparator: \.isWhitespace)
        return words.map { word in word.first!.isNumber ? String(word) : word.capitalized }.joined(separator: " ")
    }
}
