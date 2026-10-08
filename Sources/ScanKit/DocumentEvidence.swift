import Foundation

/// What a document's OCR text says that could tell where it belongs. Pure: built from text alone.
public struct DocumentEvidence: Sendable, Equatable {
    public var text: String
    public var terms: [String: Int]
    public var date: CalendarDate?
    public var vehicles: [Vehicle]
    /// `Invoice`, `Receipt`, ... the kind of paper, as the family names files.
    public var documentType: String?
    public var vendor: String?

    public struct Vehicle: Sendable, Equatable {
        public var vin: String
        public var year: Int
        public var make: String
    }

    public init(text: String, today: CalendarDate) {
        self.text = text
        terms = Self.terms(in: text)
        date = DateExtractor.documentDate(in: text, today: today)
        vehicles = Self.vehicles(in: text)
        documentType = Self.documentType(in: text)
        vendor = Self.vendor(in: text)
    }

    public var title: String {
        switch (vendor, documentType) {
        case let (vendor?, type?): "\(vendor) \(type.lowercased())"
        case let (vendor?, nil): vendor
        case let (nil, type?): type
        case (nil, nil): "Scanned document"
        }
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "are", "was", "you", "your", "from", "any", "all", "not",
        "have", "has", "will", "but", "our", "its", "per", "may", "other", "than", "then", "under", "into",
        "date", "page", "total", "amount", "new", "inc", "llc", "com", "www", "http", "https",
        "of", "off", "on", "in", "to", "at", "by", "or", "an", "as", "be", "is", "it", "no", "so", "up", "we", "if", "do",
    ]

    /// Lowercased words of two or more letters, plausible years, and a trailing plural `s` dropped
    /// so `Services` on a folder meets `SERVICE` on paper.
    public static func normalizedTerms(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap { word -> String? in
                let word = String(word)
                if word.allSatisfy(\.isNumber) {
                    guard word.count == 4, let year = Int(word), (1950...2049).contains(year) else { return nil }
                    return word
                }
                guard word.count >= 2, word.contains(where: \.isLetter), !stopwords.contains(word) else { return nil }
                return word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
            }
    }

    static func terms(in text: String) -> [String: Int] {
        normalizedTerms(text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    static let makes: [String: String] = [
        "WP0": "Porsche", "WP1": "Porsche", "5YJ": "Tesla", "7SA": "Tesla", "XP7": "Tesla", "LRW": "Tesla",
        "WAU": "Audi", "WA1": "Audi", "WUA": "Audi", "WDD": "Mercedes", "WDC": "Mercedes", "W1K": "Mercedes",
        "W1N": "Mercedes", "WMX": "AMG", "1FT": "Ford", "1FA": "Ford", "1FM": "Ford", "7FC": "Rivian",
        "7PD": "Rivian", "WBA": "BMW", "WBS": "BMW", "5UX": "BMW", "JTD": "Toyota", "4T1": "Toyota", "5TD": "Toyota",
        "JTH": "Lexus", "JHM": "Honda", "1HG": "Honda", "5FN": "Honda", "WVW": "Volkswagen", "WVG": "Volkswagen",
        "JF1": "Subaru", "4S4": "Subaru", "1G1": "Chevrolet", "1GC": "Chevrolet", "1C4": "Jeep", "SAL": "Land Rover",
    ]

    /// The 10th VIN character encodes the model year; letters cycle every 30 years, read as 2010 on.
    static let yearCodes: [Character: Int] = {
        var codes: [Character: Int] = [:]
        for (offset, letter) in "ABCDEFGHJKLMNPRSTVWXY".enumerated() { codes[letter] = 2010 + offset }
        for digit in 1...9 { codes[Character(String(digit))] = 2000 + digit }
        return codes
    }()

    static func vehicles(in text: String) -> [Vehicle] {
        let pattern = try! NSRegularExpression(pattern: "(?<![A-Z0-9])[A-HJ-NPR-Z0-9]{17}(?![A-Z0-9])")
        let nsText = text.uppercased() as NSString
        var seen: Set<String> = []
        return pattern.matches(in: nsText as String, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            let vin = nsText.substring(with: match.range)
            let characters = Array(vin)
            guard vin.contains(where: \.isNumber), vin.contains(where: \.isLetter),
                  let make = makes[String(characters[0..<3])], let year = yearCodes[characters[9]],
                  seen.insert(vin).inserted
            else { return nil }
            return Vehicle(vin: vin, year: year, make: make)
        }
    }

    static let documentTypes = [
        "Invoice", "Receipt", "Statement", "Estimate", "Quote", "Bill", "Policy", "Contract", "Agreement",
        "Report", "Certificate", "Notice", "Prescription", "Results", "Registration", "Title", "Warranty", "Letter",
    ]

    static func documentType(in text: String) -> String? {
        let upper = text.uppercased()
        return documentTypes
            .compactMap { type in upper.range(of: type.uppercased()).map { (type, $0.lowerBound) } }
            .min { $0.1 < $1.1 }?.0
    }

    /// A business usually prints its name and a matching web domain: `SIERRA RIDGE AUTO CARE`
    /// and `sierraridgeautocare.com`. The line whose letters spell the domain is the vendor.
    static func vendor(in text: String) -> String? {
        let domains = try! NSRegularExpression(pattern: "([a-z0-9-]+)\\.(com|net|org|us|biz)\\b", options: .caseInsensitive)
        let nsText = text as NSString
        let stems = domains.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range(at: 1)).lowercased().filter(\.isLetter) }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for stem in stems where stem.count >= 4 {
            if let line = lines.first(where: { $0.count < 40 && $0.lowercased().filter(\.isLetter) == stem }) {
                return line.capitalized
            }
        }
        return nil
    }
}
