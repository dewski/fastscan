public enum Sides: String, CaseIterable, Codable, Sendable {
    case front, duplex
}

/// What the scanner captures. How paper is stored afterwards is `ColorMode`.
public enum ScanColor: String, CaseIterable, Codable, Sendable {
    case lineart, gray, color
}

public struct ScanSettings: Equatable, Codable, Sendable {
    public var sides: Sides
    public var color: ScanColor
    public var dpi: Int

    public static let `default` = ScanSettings(sides: .front, color: .gray, dpi: 300)

    public init(sides: Sides, color: ScanColor, dpi: Int) {
        self.sides = sides
        self.color = color
        self.dpi = dpi
    }
}

public enum SANEOptionValue: Equatable, Sendable {
    case string(String)
    case int(Int)
}

extension ScanSettings {
    /// The one place app settings become epsonds option assignments, in the order they must be applied
    /// (mode before depth, because changing mode resets depth).
    public var saneOptions: [(name: String, value: SANEOptionValue)] {
        let source: String = switch sides {
        case .front: "ADF Front"
        case .duplex: "ADF Duplex"
        }
        let (mode, depth): (String, Int) = switch color {
        case .lineart: ("Lineart", 1)
        case .gray: ("Gray", 8)
        case .color: ("Color", 8)
        }
        return [
            ("source", .string(source)),
            ("mode", .string(mode)),
            ("depth", .int(depth)),
            ("resolution", .int(dpi)),
        ]
    }
}
