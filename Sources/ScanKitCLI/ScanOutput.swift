import Foundation
import ScanKit

/// Where `scan` (and `watch`) put each scanned document.
enum ScanOutput {
    /// Filed into a copy of the cabinet under the suggested folder and name, with an undo receipt.
    case cabinet(URL)
    /// Written to exactly this PDF.
    case file(URL)

    /// `--out <dir>` or `--file <path.pdf>`, or nil for neither. Like `file`, both refuse iCloud Drive.
    init?(_ arguments: Arguments) throws {
        switch (arguments.options["--out"], arguments.options["--file"]) {
        case (nil, nil):
            return nil
        case (let out?, nil):
            let directory = URL(filePath: out, directoryHint: .isDirectory)
            try refuseICloud(directory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError("--out \(out) isn't a folder")
            }
            self = .cabinet(directory)
        case (nil, let file?):
            let url = URL(filePath: file)
            try refuseICloud(url)
            guard url.pathExtension.lowercased() == "pdf" else { throw CLIError("--file needs a path ending in .pdf") }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw CLIError("\(file) already exists") }
            self = .file(url)
        default:
            throw CLIError("use --out or --file, not both")
        }
    }

    var cabinet: URL? { if case .cabinet(let directory) = self { directory } else { nil } }

    var directory: URL {
        switch self {
        case .cabinet(let directory): directory
        case .file(let url): url.deletingLastPathComponent()
        }
    }
}

/// What scanning one stack produced, and where it was saved.
struct ScanReport {
    var title: String?
    var fileName: String?
    var folder: String?
    var confidence: String?
    var reason: String?
    var pages = 0
    var sheets = 0
    var photos = 0
    var savedTo: String?
    var receipt: String?
    var photosSavedTo: String?
    var jammed = false
}

/// Scans one stack with `job`, which must be ready, then saves the document and any photos to
/// `output`. After a jam, what was scanned before it is kept and saved, and the report says so.
/// Leaves `job` ready for the next stack.
@MainActor
func scanStack(_ job: ScanJob, to output: ScanOutput?, photosDirectory: URL?, printReport: Bool) async throws -> ScanReport {
    await job.scan()
    var result = ScanReport()
    if case .jammed = job.state {
        result.jammed = true
        await job.finishWithKept()
    }
    guard case .reviewing(_, let batch, _) = job.state else {
        let message: String
        if case .failed(_, let failure) = job.state { message = failure } else { message = "Nothing was scanned." }
        job.send(.done)
        throw CLIError(message)
    }
    defer { job.finish() }
    if printReport { report(batch) }

    result.sheets = batch.sheets.count
    result.photos = batch.photos.count
    if let document = batch.document {
        result.title = document.suggestion.title
        result.fileName = "\(document.fileName).pdf"
        result.folder = document.destinationPath
        result.confidence = document.suggestion.confidence.rawValue
        result.reason = document.suggestion.reason
        result.pages = document.pages.count
        switch output {
        case .cabinet(let root)?:
            let created = try createFolders(document.folderPath, in: root)
            var receipt = try Filer.file(document.stagedURL, name: document.fileName, folderPath: document.folderPath,
                                         newSubfolder: document.newSubfolder, root: root)
            // Undo removes them again, innermost first.
            receipt.createdFolders = created + receipt.createdFolders
            let receipts = root.appending(path: ".scankit/receipts", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
            let receiptURL = receipts.appending(path: "\(receiptTime.string(from: .now)) \(Filer.safeFileName(document.fileName)).json")
            try JSONEncoder().encode(receipt).write(to: receiptURL)
            result.savedTo = receipt.fileURL.path
            result.receipt = receiptURL.path
        case .file(let url)?:
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: document.stagedURL, to: url)
            result.savedTo = url.path
        case nil:
            break
        }
    }
    if let output, !batch.photos.isEmpty {
        let directory = photosDirectory ?? output.directory.appending(path: ".scankit/photos", directoryHint: .isDirectory)
        let saved = try await DryRunPhotoWriter(directory: directory)
            .save(try batch.photos.map(PhotoExport.init), album: PhotoAlbum.name(for: CalendarDate(.now)))
        result.photosSavedTo = directory.appending(path: saved.album).path
    }
    return result
}

/// When a receipt was written, for its file name. Dots, not colons, which Finder shows as slashes.
let receiptTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return formatter
}()

/// Creates the folders on `folderPath` that `root` doesn't have yet, outermost first, so a copy
/// of the cabinet can take a document whose suggested folder it lacks.
func createFolders(_ folderPath: String, in root: URL) throws -> [URL] {
    var folder = root
    var created: [URL] = []
    for component in folderPath.split(separator: "/") where component != "." && component != ".." {
        folder = folder.appending(path: String(component), directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            created.append(folder)
        }
    }
    return created
}

