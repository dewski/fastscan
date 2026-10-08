import Foundation

/// An app-owned SANE config directory, so the app never depends on the global
/// /opt/homebrew/etc/sane.d. Listing only epsonds in dll.conf keeps sane_init from loading
/// every backend Homebrew ships.
public enum SANEConfig {
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "FastScan/sane.d", directoryHint: .isDirectory)
    }

    public static func deviceName(for endpoint: ScannerEndpoint) -> String {
        "epsonds:net:\(endpoint.ipv4)"
    }

    public static func write(for endpoint: ScannerEndpoint, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "epsonds\n".write(to: directory.appending(path: "dll.conf"), atomically: true, encoding: .utf8)
        try "net \(endpoint.ipv4)\n".write(to: directory.appending(path: "epsonds.conf"), atomically: true, encoding: .utf8)
    }
}
