import Foundation

public struct FilingReceipt: Codable, Sendable, Equatable {
    public var fileURL: URL
    public var createdFolders: [URL]
    /// Where the PDF came from, and where undo puts it back.
    public var stagedURL: URL
    public var relativePath: String

    public init(fileURL: URL, createdFolders: [URL], stagedURL: URL, relativePath: String) {
        self.fileURL = fileURL
        self.createdFolders = createdFolders
        self.stagedURL = stagedURL
        self.relativePath = relativePath
    }
}

/// Moves a staged PDF into the filing cabinet and back out. Only ever called after the person
/// pressed File It or File All.
public enum Filer {
    public enum Failure: LocalizedError {
        case outsideCabinet(String)
        case missingFolder(String)

        public var errorDescription: String? {
            switch self {
            case .outsideCabinet(let path): "“\(path)” is outside the filing cabinet."
            case .missingFolder(let path): "The folder “\(path)” no longer exists."
            }
        }
    }

    /// Files `staged` as `<root>/<folderPath>/<newSubfolder>/<name>.pdf`, creating only the
    /// new subfolder (and the Inbox) and never overwriting: a taken name gets " 2", " 3", ...
    public static func file(_ staged: URL, name: String, folderPath: String, newSubfolder: String?, root: URL) throws -> FilingReceipt {
        let manager = FileManager.default
        let folder = try resolve(folderPath, in: root)
        var created: [URL] = []
        if !manager.fileExists(atPath: folder.path) {
            guard folderPath == CandidateRanker.inboxName else { throw Failure.missingFolder(folderPath) }
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            created.append(folder)
        }
        var destinationFolder = folder
        if let newSubfolder {
            destinationFolder = folder.appending(path: safeFileName(newSubfolder), directoryHint: .isDirectory)
            if !manager.fileExists(atPath: destinationFolder.path) {
                try manager.createDirectory(at: destinationFolder, withIntermediateDirectories: false)
                created.append(destinationFolder)
            }
        }
        let base = safeFileName(name)
        var target = destinationFolder.appending(path: "\(base).pdf")
        var suffix = 2
        while manager.fileExists(atPath: target.path) {
            target = destinationFolder.appending(path: "\(base) \(suffix).pdf")
            suffix += 1
        }
        do {
            try manager.moveItem(at: staged, to: target)
        } catch {
            for folder in created.reversed() { try? manager.removeItem(at: folder) }
            throw error
        }
        let relative = String(target.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return FilingReceipt(fileURL: target, createdFolders: created, stagedURL: staged, relativePath: relative)
    }

    /// Moves the file back to staging, then removes the folders the filing created if nothing
    /// else has been put in them since.
    public static func undo(_ receipt: FilingReceipt) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: receipt.stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: receipt.fileURL, to: receipt.stagedURL)
        for folder in receipt.createdFolders.reversed() {
            let contents = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try manager.removeItem(at: folder) }
        }
    }

    /// Slashes and colons would make a path or confuse Finder; leading dots would hide the file.
    public static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.drop { $0 == "." })
        return trimmed.isEmpty ? "Scan" : trimmed
    }

    private static func resolve(_ folderPath: String, in root: URL) throws -> URL {
        let folder = folderPath.isEmpty ? root : root.appending(path: folderPath, directoryHint: .isDirectory)
        let standardized = folder.standardizedFileURL.path
        guard standardized == root.standardizedFileURL.path || standardized.hasPrefix(root.standardizedFileURL.path + "/")
        else { throw Failure.outsideCabinet(folderPath) }
        return folder
    }
}
