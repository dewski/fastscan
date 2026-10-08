import Foundation
import ImageIO
import ScanKit

let usage = """
    usage: scankit discover
           scankit info
           scankit ocr <image...>
           scankit process <image...> -o out.pdf [--color <mode>]
           scankit suggest <image...> --root <cabinet> [--no-model] [--color <mode>] [--fronts-only] [--pages-dir <dir>]
           scankit file <image...> --root <cabinet> --receipt <receipt.json> [--no-model] [--color <mode>] [--fronts-only] [--photos-dir <dir>]
           scankit undo <receipt.json>
           scankit tree [<folder>] --root <cabinet>
           scankit scan --root <cabinet> [--no-model]

    --color is automatic (the default), color, or grayscale. --fronts-only reads every side, then leaves out the back of each sheet.
    Images are a duplex scan in feeder order at 300 dpi: front, back, front, back, ...
    `file` refuses any cabinet inside iCloud Drive; point it at a copy made by script/mirror-tree.
    Photos are never added to the photo library; `file` writes them to --photos-dir instead.
    """

struct CLIError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Splits `--flag value` options from positional arguments.
struct Arguments {
    static let valued: Set<String> = ["-o", "--root", "--pages-dir", "--receipt", "--photos-dir", "--color"]
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: some Sequence<String>) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            if Self.valued.contains(argument) {
                guard let value = iterator.next() else { throw CLIError("\(argument) needs a value") }
                options[argument] = value
            } else if argument.hasPrefix("-") {
                flags.insert(argument)
            } else {
                positional.append(argument)
            }
        }
    }

    func required(_ option: String) throws -> String {
        guard let value = options[option] else { throw CLIError("missing \(option)") }
        return value
    }

    func root() throws -> URL { URL(filePath: try required("--root"), directoryHint: .isDirectory) }

    func colorMode() throws -> ColorMode {
        guard let value = options["--color"] else { return .automatic }
        guard let mode = ColorMode(rawValue: value) else {
            throw CLIError("--color must be one of \(ColorMode.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return mode
    }

    /// Keeps the CLI's index, feedback, and staging out of the app's Application Support.
    func reader(root: URL) throws -> BatchReader {
        let support = FileManager.default.temporaryDirectory.appending(path: "scankit-\(ProcessInfo.processInfo.processIdentifier)")
        return BatchReader(root: root,
                           indexStore: FolderIndexStore(cacheURL: support.appending(path: "index.json")),
                           suggester: FilingSuggester(useModel: !flags.contains("--no-model")),
                           feedbackStore: FilingFeedbackStore(url: support.appending(path: "feedback.json")),
                           stagingDirectory: support.appending(path: "Staging"), colorMode: try colorMode())
    }

    var pageSelection: PageSelection { flags.contains("--fronts-only") ? .frontsOnly : .allSides }
}

func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

func loadImage(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CLIError("cannot read \(path)") }
    return image
}

/// Reads every side, then applies the page selection to the finished draft, as the File screen does.
func readBatch(_ paths: [String], reader: BatchReader, selection: PageSelection) async throws -> Batch {
    guard !paths.isEmpty else { throw CLIError("no input images") }
    var sides: [Int: ScannedSide] = [:]
    for (index, path) in paths.enumerated() {
        sides[index] = try await BatchReader.read(RawPage(index: index, side: index % 2 == 0 ? .front : .back, image: try loadImage(path), dpi: 300))
    }
    var batch = Batch(sheets: BatchReader.sheets(from: sides, pageCount: paths.count))
    batch.setDocument(try await reader.document(for: batch))
    if let document = batch.document, document.encoding.selection != selection {
        batch.editDocument { $0.encoding.selection = selection }
        batch.setDocument(try await reader.document(for: batch))
    }
    return batch
}

func report(_ batch: Batch) {
    print("Sheets")
    for sheet in batch.sheets {
        let sides = [("front", sheet.front), ("back", sheet.back)].map { name, side in
            side.map { "\(name) \(String(format: "%.1fx%.1f in", $0.features.widthInches, $0.features.heightInches))" } ?? "\(name) blank"
        }
        let features = sheet.face.features
        print("  sheet \(sheet.id + 1): \(batch.kind(of: sheet).rawValue)  (\(sides.joined(separator: ", ")); text \(String(format: "%.0f%%", features.textCoverage * 100)),"
            + " document \(String(format: "%.2f", features.documentConfidence)), scene \(String(format: "%.2f", features.sceneConfidence)),"
            + " color \(String(format: "%.1f%%", features.colorfulFraction * 100)))")
    }
    for photo in batch.photos { print("  photo from sheet \(photo.id + 1), caption: \(photo.caption ?? "none")") }

    guard let document = batch.document else {
        print("\nNo paper in this batch.")
        return
    }
    let evidence = document.evidence
    print("\nEvidence: \(evidence.title); date \(evidence.date?.iso ?? "none"); type \(evidence.documentType ?? "none");"
        + " vehicles \(evidence.vehicles.map { "\($0.year) \($0.make) (\($0.vin))" }.joined(separator: ", "))")
    print("\nTop candidates (\(document.result.candidates.count) sent to the model)")
    for candidate in document.result.candidates.prefix(8) {
        let events = candidate.matchedEvents.isEmpty ? "" : "  events: \(candidate.matchedEvents.joined(separator: "; "))"
        print("  \(String(format: "%6.2f", candidate.score))  \(candidate.path)  [\(candidate.matchedTerms.joined(separator: ", "))]\(events)")
    }
    print("\nOn-device model: \(FilingSuggester.modelAvailability)")
    switch document.result.source {
    case .model: print("Suggestion from: Foundation Models")
    case .heuristic(let why): print("Suggestion from: heuristic fallback, because \(why)")
    }
    if let tokens = document.result.promptTokens { print("Prompt size: \(tokens) tokens") }
    print("Took: \(document.result.elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
    let suggestion = document.suggestion
    print("""

        Title:      \(suggestion.title)
        Name:       \(document.fileName).pdf
        Folder:     \(document.folderPath)
        New folder: \(document.newSubfolder ?? "none")
        Reason:     \(suggestion.reason)
        Confidence: \(suggestion.confidence.rawValue)
        """)
    print("\nStored pages (\(document.pages.count), PDF \(size((try? Data(contentsOf: document.stagedURL).count) ?? 0)))")
    for (number, page) in document.pages.enumerated() {
        print("  page \(number + 1): \(page.pixelWidth)x\(page.pixelHeight) at \(page.dpi) dpi, \(page.isGray ? "gray" : "color"), \(size(page.jpeg.count))")
    }
}

/// The family's live folder must never be written by a tool run from a terminal.
func refuseICloud(_ root: URL) throws {
    if root.standardizedFileURL.path.contains("/Library/Mobile Documents/") {
        throw CLIError("refusing to file into iCloud Drive (\(root.path)); use a copy made with script/mirror-tree")
    }
}

func tree(_ root: URL, under path: String) -> String {
    let folder = root.appending(path: path)
    let items = (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).sorted()
    return ([path + "/"] + items.map { "  " + $0 }).joined(separator: "\n")
}

func describe(_ state: ScanState) -> String {
    switch state {
    case .looking: "looking for the scanner"
    case .notFound(let reason): "not found: \(reason)"
    case .ready(let endpoint): "ready: \(endpoint.name) at \(endpoint.ipv4)"
    case .starting(_, let kept): "starting the scanner (\(kept) page(s) kept)"
    case .scanning(_, let pages): "scanning: \(pages) page(s)"
    case .jammed(_, let pages): "jammed: \(pages) page(s) kept"
    case .reading(_, let done, let total): "reading: \(done) of \(total)"
    case .reviewing(_, _, let mode): "reviewing (\(mode))"
    case .filing: "filing"
    case .filed: "filed"
    case .failed(_, let message): "failed: \(message)"
    }
}

do {
    let raw = CommandLine.arguments.dropFirst()
    let arguments = try Arguments(raw.dropFirst())
    switch raw.first {
    case "discover":
        let endpoints = try await ScannerDiscovery.discover(timeout: .seconds(5))
        if endpoints.isEmpty { throw CLIError("No Epson scanner found on the local network.") }
        for endpoint in endpoints {
            print("\(endpoint.name)  host=\(endpoint.host)  ipv4=\(endpoint.ipv4)  port=\(endpoint.port)")
        }
    case "info":
        guard let endpoint = try await ScannerDiscovery.discover(timeout: .seconds(10), firstOnly: true).first else {
            throw CLIError("No Epson scanner found on the local network.")
        }
        let session = SANESession()
        try await session.open(endpoint)
        for option in try await session.options() {
            print("  \(option.name) = \(option.value)  [\(option.allowed)]  \(option.title)")
        }
        await session.close()
    case "ocr":
        for path in arguments.positional {
            for line in try await TextRecognizer.recognize(PageProcessor.crop(try loadImage(path), dpi: 300)) { print(line.text) }
        }
    case "process":
        let output = URL(filePath: try arguments.required("-o"))
        var pages: [StoredPage] = []
        for (index, path) in arguments.positional.enumerated() {
            let raw = RawPage(index: index, side: .front, image: try loadImage(path), dpi: 300)
            guard let side = try await BatchReader.read(raw) else {
                print("page \(index + 1): blank, skipped")
                continue
            }
            let page = try PageEncoder.encode(side.processed, mode: try arguments.colorMode())
            print("page \(index + 1): \(page.pixelWidth)x\(page.pixelHeight), \(page.isGray ? "gray" : "color"), \(size(page.jpeg.count))")
            pages.append(page)
        }
        try PDFBuilder.write(pages, to: output)
        print("wrote \(output.path)")
    case "suggest":
        let root = try arguments.root()
        let batch = try await readBatch(arguments.positional, reader: try arguments.reader(root: root), selection: arguments.pageSelection)
        report(batch)
        if let directory = arguments.options["--pages-dir"], let document = batch.document {
            for (index, page) in document.pages.enumerated() {
                try page.jpeg.write(to: URL(filePath: directory).appending(path: "stored-\(index + 1).jpg"))
            }
        }
    case "file":
        let root = try arguments.root()
        try refuseICloud(root)
        let receiptURL = URL(filePath: try arguments.required("--receipt"))
        let batch = try await readBatch(arguments.positional, reader: try arguments.reader(root: root), selection: arguments.pageSelection)
        report(batch)
        guard let document = batch.document else { throw CLIError("nothing to file") }
        let receipt = try Filer.file(document.stagedURL, name: document.fileName, folderPath: document.folderPath,
                                     newSubfolder: document.newSubfolder, root: root)
        try JSONEncoder().encode(receipt).write(to: receiptURL)
        print("\nFiled \(receipt.relativePath)")
        print("Created folders: \(receipt.createdFolders.map(\.lastPathComponent).joined(separator: ", ").ifEmpty("none"))")
        print("Receipt: \(receiptURL.path)")
        if !batch.photos.isEmpty {
            let directory = URL(filePath: arguments.options["--photos-dir"] ?? FileManager.default.temporaryDirectory.appending(path: "scankit-photos").path)
            let result = try await DryRunPhotoWriter(directory: directory)
                .save(try batch.photos.map(PhotoExport.init), album: PhotoAlbum.name(for: CalendarDate(.now)))
            print("Photos (dry run): \(result.saved) written to \(directory.appending(path: result.album).path)")
        }
    case "undo":
        guard let path = arguments.positional.first else { throw CLIError("undo needs a receipt") }
        let receipt = try JSONDecoder().decode(FilingReceipt.self, from: Data(contentsOf: URL(filePath: path)))
        try Filer.undo(receipt)
        print("Moved \(receipt.relativePath) back to \(receipt.stagedURL.path)")
        let removed = receipt.createdFolders.filter { !FileManager.default.fileExists(atPath: $0.path) }
        print("Removed empty folders it created: \(removed.map(\.lastPathComponent).joined(separator: ", ").ifEmpty("none"))")
    case "tree":
        print(tree(try arguments.root(), under: arguments.positional.first ?? ""))
    case "scan":
        let root = try arguments.root()
        let job = await ScanJob(reader: try arguments.reader(root: root),
                                photoWriter: DryRunPhotoWriter(directory: FileManager.default.temporaryDirectory.appending(path: "scankit-photos")))
        await MainActor.run { job.onChange = { print(describe($0)) } }
        await job.discover()
        await job.scan()
        if let batch = await job.state.batch { report(batch) }
    default:
        print(usage)
        exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}
