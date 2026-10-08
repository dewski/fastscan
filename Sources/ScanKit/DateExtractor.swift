import Foundation

/// A day with no time or zone, which is what a printed date on paper means.
public struct CalendarDate: Hashable, Comparable, Codable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year!
        month = parts.month!
        day = parts.day!
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public var display: String { "\(DateExtractor.monthAbbreviations[month - 1].capitalized) \(day), \(year)" }

    public static func < (a: CalendarDate, b: CalendarDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

/// Finds printed dates in OCR text. Dealer and receipt printers use compact forms like `07OCT26`
/// alongside `10/07/2026` and `Oct 7, 2026`; numeric dates are read month-first, as printed in the US.
public enum DateExtractor {
    static let monthAbbreviations = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// Each printed form, with which capture group holds the year, month, and day. ICU regexes,
    /// because Swift's own don't support the lookbehind that keeps the VIN `4S4BTAFC1MJ2MAR21`
    /// from reading as March 2, 2021.
    private static let forms: [(pattern: NSRegularExpression, year: Int, month: Int, day: Int)] = {
        // OCR reads the O of a compact OCT or NOV as a zero often enough to matter.
        let month = "(jan|feb|mar|apr|may|jun|jul|aug|sep|[o0]ct|n[o0]v|dec)[a-z]*\\.?"
        let table: [(String, Int, Int, Int)] = [
            ("(?<![0-9a-z])(\\d{1,2})[ -]?\(month)[ ,-]*(\\d{4}|\\d{2})(?![0-9a-z])", 3, 2, 1),
            ("(?<![0-9a-z])\(month)\\s*(\\d{1,2})(?:st|nd|rd|th)?,?\\s*(\\d{4})(?![0-9])", 3, 1, 2),
            ("(?<![0-9/])(\\d{1,2})([/-])(\\d{1,2})\\2(\\d{4}|\\d{2})(?![0-9/])", 4, 1, 3),
            ("(?<![0-9])(\\d{4})-(\\d{2})-(\\d{2})(?![0-9])", 1, 2, 3),
        ]
        return table.map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1, $0.2, $0.3) }
    }()

    public static func dates(in text: String) -> [CalendarDate] {
        let nsText = text as NSString
        var found: [(location: Int, date: CalendarDate)] = []
        for form in forms {
            for match in form.pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                func group(_ index: Int) -> String { nsText.substring(with: match.range(at: index)) }
                let monthText = group(form.month)
                let month = Int(monthText) ?? monthAbbreviations.firstIndex(of: monthText.prefix(3).uppercased().replacingOccurrences(of: "0", with: "O")).map { $0 + 1 }
                if let date = make(year: group(form.year), month: month, day: group(form.day)) {
                    found.append((match.range.location, date))
                }
            }
        }
        return found.sorted { $0.location < $1.location }.map(\.date)
    }

    /// The date a receipt or invoice is "for": the latest printed date that isn't in the future.
    /// Earlier dates on such papers are delivery, order, or warranty dates.
    public static func documentDate(in text: String, today: CalendarDate) -> CalendarDate? {
        dates(in: text).filter { $0 <= today }.max()
    }

    private static func make(year: String, month: Int?, day: String) -> CalendarDate? {
        guard let month, let day = Int(day), var year = Int(year) else { return nil }
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        guard (1900...2100).contains(year) else { return nil }
        return CalendarDate(year: year, month: month, day: day)
    }
}
