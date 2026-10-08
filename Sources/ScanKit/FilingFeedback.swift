import Foundation

/// A suggestion the family changed before filing. Kept locally and shown to the model as examples.
public struct FilingFeedback: Codable, Sendable, Equatable {
    public var date: Date
    public var title: String
    public var documentType: String?
    public var vendor: String?
    public var suggestedPath: String
    public var chosenPath: String
    public var suggestedName: String
    public var chosenName: String

    public init(date: Date = .now, title: String, documentType: String?, vendor: String?,
                suggestedPath: String, chosenPath: String, suggestedName: String, chosenName: String) {
        self.date = date
        self.title = title
        self.documentType = documentType
        self.vendor = vendor
        self.suggestedPath = suggestedPath
        self.chosenPath = chosenPath
        self.suggestedName = suggestedName
        self.chosenName = chosenName
    }

    var promptLine: String {
        var parts: [String] = []
        if chosenPath != suggestedPath { parts.append("filed in '\(chosenPath)' instead of '\(suggestedPath)'") }
        if chosenName != suggestedName { parts.append("named '\(chosenName)' instead of '\(suggestedName)'") }
        return "\(title): " + parts.joined(separator: ", ")
    }

    static func relevant(_ all: [FilingFeedback], to evidence: DocumentEvidence, limit: Int) -> [FilingFeedback] {
        func affinity(_ item: FilingFeedback) -> Int {
            (item.vendor != nil && item.vendor == evidence.vendor ? 2 : 0)
                + (item.documentType != nil && item.documentType == evidence.documentType ? 1 : 0)
        }
        return Array(all.sorted { (affinity($0), $0.date) > (affinity($1), $1.date) }.prefix(limit))
    }
}

public struct FilingFeedbackStore: Sendable {
    public var url: URL
    public static let capacity = 100

    public init(url: URL = URL.applicationSupportDirectory.appending(path: "FastScan/feedback.json")) {
        self.url = url
    }

    public func load() -> [FilingFeedback] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FilingFeedback].self, from: data)) ?? []
    }

    public func record(_ item: FilingFeedback) throws {
        guard item.chosenPath != item.suggestedPath || item.chosenName != item.suggestedName else { return }
        let all = Array((load() + [item]).suffix(Self.capacity))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(all).write(to: url, options: .atomic)
    }
}
