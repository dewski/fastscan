import CSANE
import Foundation

public enum SANEError: Error, Equatable, Sendable {
    case unsupported
    case cancelled
    case deviceBusy
    case invalid
    case jammed
    case feederEmpty
    case coverOpen
    case ioError
    case noMemory
    case accessDenied
    case status(Int)
    case missingOption(String)
    case unsupportedFrame(format: Int, depth: Int)

    /// Returns nil for SANE_STATUS_GOOD so call sites read `if let error = SANEError(status) { throw error }`.
    init?(_ status: SANE_Status) {
        switch status {
        case SANE_STATUS_GOOD: return nil
        case SANE_STATUS_UNSUPPORTED: self = .unsupported
        case SANE_STATUS_CANCELLED: self = .cancelled
        case SANE_STATUS_DEVICE_BUSY: self = .deviceBusy
        case SANE_STATUS_INVAL: self = .invalid
        case SANE_STATUS_JAMMED: self = .jammed
        case SANE_STATUS_NO_DOCS: self = .feederEmpty
        case SANE_STATUS_COVER_OPEN: self = .coverOpen
        case SANE_STATUS_IO_ERROR: self = .ioError
        case SANE_STATUS_NO_MEM: self = .noMemory
        case SANE_STATUS_ACCESS_DENIED: self = .accessDenied
        default: self = .status(Int(status.rawValue))
        }
    }
}

extension SANEError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported: "The scanner does not support that operation."
        case .cancelled: "The scan was cancelled."
        case .deviceBusy: "The scanner is busy. Try again in a moment."
        case .invalid: "The scanner rejected the request, or could not be reached."
        case .jammed: "The feeder is jammed. Clear the paper path and try again."
        case .feederEmpty: "The feeder is empty. Load pages and try again."
        case .coverOpen: "The scanner cover is open."
        case .ioError: "Lost contact with the scanner."
        case .noMemory: "The scanner driver ran out of memory."
        case .accessDenied: "Access to the scanner was denied."
        case .status(let code): "The scanner returned SANE status \(code)."
        case .missingOption(let name): "The scanner has no \"\(name)\" option."
        case .unsupportedFrame(let format, let depth): "Unsupported image format \(format) at depth \(depth)."
        }
    }
}
