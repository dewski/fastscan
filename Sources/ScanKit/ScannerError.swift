import Foundation

public enum ScannerError: Error, Equatable, Sendable {
    case feederEmpty
    /// A paper jam (`PJ`), such as a sheet held back while the scanner tried to pull it in.
    case jammed
    /// `DFED`, which ScanSmart calls a double feed. A folded, crooked sheet set it off, and so did
    /// opening the cover mid-scan.
    case doubleFeed
    case cancelled
    /// The scanner's own Stop button was pressed (`#atnCAN ` in an `IMG` reply).
    case stoppedAtScanner
    case notOpen
    /// Another app or computer holds the scanner's lock.
    case busy
    case unsupportedScanner(String)
    case unsupportedSettings(String)
    /// An error code without a known meaning, as the scanner sent it.
    case scannerReported(String)
    /// A reply that was well formed but not what the protocol calls for at that point.
    case unexpectedReply(String)
    case malformed(String)
    case connection(String)
    case undecodableImage(PageSide)
}

extension ScannerError {
    /// The error for a code from `STAT`'s `#ERR` or an `IMG` reply's `#err`: `PE` is an empty
    /// feeder, `PJ` a paper jam, and `DFED` a double feed. Other codes haven't been observed.
    static func reported(_ code: String) -> ScannerError {
        switch code {
        case "PE": .feederEmpty
        case "PJ": .jammed
        case "DFED": .doubleFeed
        default: .scannerReported(code)
        }
    }
}

extension ScannerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .feederEmpty: "The feeder is empty. Load pages and try again."
        case .jammed: "The feeder is jammed. Clear the paper path and try again."
        case .doubleFeed: "The scanner stopped feeding. Open the scanner, take out the sheet, close it, and try again."
        case .cancelled: "The scan was cancelled."
        case .stoppedAtScanner: "The scan was stopped at the scanner."
        case .notOpen: "The scanner connection isn't open."
        case .busy: "Another app or computer is using the scanner. Try again when it's done."
        case .unsupportedScanner(let product): "FastScan only works with the Epson FastFoto FF-680W, and this scanner is a \(product)."
        case .unsupportedSettings(let reason): "The scanner can't scan that way: \(reason)."
        // Details stay in the error value for the scankit CLI and logs; people get what to do next.
        case .scannerReported: "The scanner stopped with an error. Check it for a message or stuck paper, then try again."
        case .unexpectedReply, .malformed: "There was a problem communicating with the scanner. Turn the scanner off and on again, then try again."
        case .connection: "Lost contact with the scanner."
        case .undecodableImage: "A page from the scanner couldn't be read. Try scanning again."
        }
    }
}
