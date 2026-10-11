import Foundation

/// What the scanner says it can do: its `CAPA` list ("`CAPA`, capabilities" in
/// docs/esci2-protocol.md) and the page lengths from `EXI`. Readings follow the spec; where it
/// marks one as a guess, so does the comment here.
public struct ScannerCapabilities: Equatable, Sendable {
    /// `#RSMLIST`: every resolution the scanner accepts, in dpi.
    public var resolutions: [Int] = []
    /// `#ADFRSMSLIST`: probably the resolutions the feeder is tuned for.
    public var feederResolutions: [Int] = []
    /// `#COLLIST`: `C024` is 24-bit color; `M008`, `R008`, `G008` and `B008` are probably 8-bit gray
    /// and single color channels.
    public var colorModes: [String] = []
    /// `#FMTLIST`: image formats, such as `JPG`.
    public var formats: [String] = []
    /// `#JPGRANG`: the JPEG quality range.
    public var jpegQuality: ClosedRange<Int>?
    /// The feeder options, from the `#ADF` entries: `DPLX` (two-sided), `CRP` (crop to the paper),
    /// `SKEW` (probably straighten), `DFL1` (probably double-feed detection), and others.
    public var feederOptions: [String] = []
    /// From `EXI`: the page length the scanner feeds at normal speed, and the longest it takes,
    /// per resolution, in 1/100 inch.
    public var normalSpeedLength: [Int: Int] = [:]
    public var maximumLength: [Int: Int] = [:]
    /// Every token, as sent, for anything not modeled above.
    public var tokens: [String] = []

    public init() {}

    /// Reads a `CAPA` data block and an `EXI` data block.
    init(capa: [UInt8], exi: [UInt8]) throws {
        let parsed = try ESCI2.parseTokens(capa[...])
        tokens = parsed.map { ESCI2.printable($0.encoded) }
        for token in parsed {
            let words = token.words.map { $0.trimmingCharacters(in: .whitespaces) }
            switch (token.name, words.first) {
            case ("ADF", "RSMS"): feederResolutions = token.numbers
            case ("ADF", _): feederOptions += words
            case ("RSM", "LIST"): resolutions = token.numbers
            case ("COL", "LIST"): colorModes = Array(words.dropFirst())
            case ("FMT", "LIST"): formats = Array(words.dropFirst())
            case ("JPG", "RANG"):
                if token.numbers.count == 2 { jpegQuality = token.numbers[0]...token.numbers[1] }
            default: break
            }
        }
        if !exi.isEmpty {
            normalSpeedLength = try ESCI2.lengths(exi: exi, key: "NormalSpeedLength")
            maximumLength = try ESCI2.lengths(exi: exi, key: "MaxLength")
        }
    }

    /// The resolutions a scan can use: ones the scanner accepts that `EXI` gives a page length for,
    /// since the page length sets the scan area.
    public var scanResolutions: [Int] {
        resolutions.filter { normalSpeedLength[$0] != nil }.sorted()
    }
}
