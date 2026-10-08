import Foundation
import ScanKit

@MainActor
final class AppSettings {
    static let shared = AppSettings()
    static let didChange = Notification.Name("FastScanSettingsDidChange")

    private let defaults = UserDefaults.standard
    private let rootKey = "filingCabinetPath"
    private let whenUnsureKey = "whenUnsure"
    private let recentKey = "recentDestinations"
    private let colorModeKey = "colorMode"

    static let defaultCabinet = URL.documentsDirectory.appending(path: "Scans", directoryHint: .isDirectory)

    /// FASTSCAN_ROOT points the app at a stand-in cabinet (a script/mirror-tree copy) for development.
    var rootOverride: URL? {
        ProcessInfo.processInfo.environment["FASTSCAN_ROOT"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    var filingCabinet: URL {
        get {
            if let rootOverride { return rootOverride }
            if let path = defaults.string(forKey: rootKey) { return URL(filePath: path, directoryHint: .isDirectory) }
            try? FileManager.default.createDirectory(at: Self.defaultCabinet, withIntermediateDirectories: true)
            return Self.defaultCabinet
        }
        set {
            defaults.set(newValue.path, forKey: rootKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var whenUnsure: BatchReader.WhenUnsure {
        get { defaults.string(forKey: whenUnsureKey).flatMap(BatchReader.WhenUnsure.init) ?? .inbox }
        set {
            defaults.set(newValue.rawValue, forKey: whenUnsureKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var colorMode: ColorMode {
        get { defaults.string(forKey: colorModeKey).flatMap(ColorMode.init) ?? .automatic }
        set {
            defaults.set(newValue.rawValue, forKey: colorModeKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    var recentDestinations: [String] {
        get { defaults.stringArray(forKey: recentKey) ?? [] }
        set { defaults.set(Array(newValue.prefix(5)), forKey: recentKey) }
    }

    func noteFiled(into folderPath: String) {
        recentDestinations = [folderPath] + recentDestinations.filter { $0 != folderPath }
    }
}
