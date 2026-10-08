import Foundation

/// The filing cabinet's shape: every folder's path, its subfolders, and a few of its file names.
/// Built from directory metadata only; no file is ever opened.
public struct FolderIndex: Codable, Sendable, Equatable {
    public struct Folder: Codable, Sendable, Hashable {
        /// Relative to the root, `/`-separated. The root itself is "".
        public var path: String
        public var subfolders: [String]
        public var exampleFiles: [String]
        public var fileCount: Int

        public var components: [String] { path.isEmpty ? [] : path.split(separator: "/").map(String.init) }
        public var name: String { components.last ?? "" }
        public var parentPath: String { components.dropLast().joined(separator: "/") }

        public init(path: String, subfolders: [String], exampleFiles: [String], fileCount: Int) {
            self.path = path
            self.subfolders = subfolders
            self.exampleFiles = exampleFiles
            self.fileCount = fileCount
        }
    }

    public var rootPath: String
    public var folders: [Folder]
    public var builtAt: Date

    public var root: URL { URL(filePath: rootPath, directoryHint: .isDirectory) }

    public init(rootPath: String, folders: [Folder], builtAt: Date = .now) {
        self.rootPath = rootPath
        self.folders = folders
        self.builtAt = builtAt
    }

    public func folder(at path: String) -> Folder? { folders.first { $0.path == path } }

    public func url(for path: String) -> URL {
        path.isEmpty ? root : root.appending(path: path, directoryHint: .isDirectory)
    }

    static let examplesPerFolder = 6

    /// Walks `root`, skipping hidden items and packages (a `.pages` document is a file to the family).
    public static func build(root: URL) throws -> FolderIndex {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        let manager = FileManager.default
        var folders: [Folder] = []
        var pending = [(url: root.standardizedFileURL, path: "")]
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        while let (directory, relative) = pending.popLast() {
            let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            var subfolders: [String] = [], files: [String] = []
            for entry in entries {
                let values = try entry.resourceValues(forKeys: Set(keys))
                if values.isHidden == true { continue }
                if values.isDirectory == true, values.isPackage != true {
                    subfolders.append(entry.lastPathComponent)
                    pending.append((entry, relative.isEmpty ? entry.lastPathComponent : "\(relative)/\(entry.lastPathComponent)"))
                } else {
                    files.append(entry.lastPathComponent)
                }
            }
            folders.append(Folder(path: relative,
                                  subfolders: subfolders.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                                  exampleFiles: Array(files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(examplesPerFolder)),
                                  fileCount: files.count))
        }
        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return FolderIndex(rootPath: rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath, folders: folders)
    }
}

/// Keeps the last index on disk so suggestions are instant at launch, and rebuilds it in the
/// background because the family adds folders from other Macs.
public actor FolderIndexStore {
    private let cacheURL: URL
    private var index: FolderIndex?

    public init(cacheURL: URL = URL.applicationSupportDirectory.appending(path: "FastScan/folder-index.json")) {
        self.cacheURL = cacheURL
    }

    public func current(root: URL) async throws -> FolderIndex {
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        if let index, index.root.path == URL(filePath: rootPath).path { return index }
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(FolderIndex.self, from: data),
           cached.root.path == URL(filePath: rootPath).path {
            index = cached
            return cached
        }
        return try await refresh(root: root)
    }

    @discardableResult
    public func refresh(root: URL) async throws -> FolderIndex {
        let built = try await Task.detached(priority: .utility) { try FolderIndex.build(root: root) }.value
        index = built
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(built).write(to: cacheURL, options: .atomic)
        return built
    }
}
