import AppKit
import ImageIO
import ScanKit

/// FASTSCAN_DEMO=<screen> puts the window on one screen with real data, for snapshots and design
/// review without a scanner. It drives the job only through its public events, so every screen
/// is reached the same way the scanner would reach it.
///
/// FASTSCAN_FIXTURES is a folder holding page-001.png… from a duplex scan (read in place, never
/// copied); FASTSCAN_ROOT is the filing cabinet to suggest against (use a script/mirror-tree copy).
/// The mixed screen adds synthetic photos, since no photo fixtures exist.
@MainActor
final class Demo {
    static let screens = ["looking", "ready", "starting", "scanning", "reading", "file", "file-color", "file-fronts", "file-nobacks", "recoloring", "filing", "choose", "mixed", "filed", "notfound", "jam", "settings", "acknowledgements", "failed"]

    private let state: String
    private let controller: ScanWindowController
    private let job: ScanJob
    private let openSettings: () -> Void
    private let openAcknowledgements: () -> Void
    private let scanner = ScannerEndpoint(name: "EPSON FF-680W", host: "EPSONDEMO01.local.", ipv4: "192.0.2.10", port: 1865)

    init(state: String, controller: ScanWindowController, job: ScanJob, openSettings: @escaping () -> Void, openAcknowledgements: @escaping () -> Void) {
        self.state = state
        self.controller = controller
        self.job = job
        self.openSettings = openSettings
        self.openAcknowledgements = openAcknowledgements
        job.reader = BatchReader(root: job.reader.root,
                                 indexStore: FolderIndexStore(cacheURL: URL(filePath: NSTemporaryDirectory()).appending(path: "fastscan-demo-index.json")),
                                 feedbackStore: FilingFeedbackStore(url: URL(filePath: NSTemporaryDirectory()).appending(path: "fastscan-demo-feedback.json")),
                                 stagingDirectory: URL(filePath: NSTemporaryDirectory()).appending(path: "fastscan-demo-staging"),
                                 whenUnsure: job.reader.whenUnsure, colorMode: job.reader.colorMode)
    }

    func run(snapshot: URL?, delay: Double) {
        Task {
            do {
                try await reach()
            } catch {
                job.send(.failed("Demo: \(error.localizedDescription)"))
            }
            guard let snapshot else { return }
            // An inactive window grays its default button; wait to be frontmost so the snapshot
            // shows the window as people use it.
            for _ in 0..<40 where !NSApp.isActive {
                NSApp.activate()
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(delay))
            let windows: [NSWindow] = switch state {
            case "settings", "acknowledgements": NSApp.windows.filter { $0.title == state.capitalized && $0.isVisible }
            default: [controller.window].compactMap { $0 }
            }
            Snapshot.write(windows, to: snapshot)
            NSApp.terminate(nil)
        }
    }

    private func reach() async throws {
        let fixtures = try fixtureImages()
        switch state {
        case "looking":
            break
        case "notfound":
            job.send(.notFound(.noScanner))
        case "failed":
            job.send(.found(scanner))
            job.send(.failed("Lost contact with the scanner."))
        case "ready":
            job.send(.found(scanner))
        case "acknowledgements":
            job.send(.found(scanner))
            openAcknowledgements()
        case "settings":
            job.send(.found(scanner))
            openSettings()
        case "starting":
            job.send(.found(scanner))
            job.send(.start)
        case "scanning":
            scan(fixtures.prefix(3))
        case "jam":
            scan(fixtures.prefix(2))
            job.send(.jammed(keptPages: 2))
        case "reading":
            scan(fixtures)
            job.send(.read(done: 2, total: fixtures.count + 1))
        case "file", "file-color", "file-fronts", "file-nobacks", "recoloring", "filing", "choose", "filed", "mixed":
            let batch = try await review(fixtures, photos: state == "mixed" ? Self.syntheticPhotos() : [], blankBacks: state == "file-nobacks")
            if state == "file-color" { await controller.chooseColor(.color)?.value }
            if state == "file-fronts" { await controller.choosePages(.frontsOnly)?.value }
            if state == "recoloring" { controller.chooseColor(.color) }
            if state == "filing" { job.send(.file) }
            if state == "choose", let screen = controller.window?.contentView?.firstDescendant(of: FolderRow.self) {
                controller.window?.layoutIfNeeded()
                controller.chooseFolder(screen)
            }
            if state == "filed" { file(batch) }
        default:
            job.send(.failed("Unknown demo screen “\(state)”. Try one of: \(Self.screens.joined(separator: ", "))."))
        }
    }

    private func scan(_ images: some Collection<CGImage>) {
        job.send(.found(scanner))
        job.send(.start)
        job.send(.connected)
        controller.injectThumbnails(images.map { PageProcessor.crop($0, dpi: 300) })
        for _ in images { job.send(.pageScanned) }
    }

    /// `blankBacks` reads the fixtures as if every back were blank, so there is no back to leave out.
    private func review(_ fixtures: [CGImage], photos: [CGImage], blankBacks: Bool = false) async throws -> Batch {
        scan(fixtures)
        var sides: [Int: ScannedSide] = [:]
        for (index, image) in fixtures.enumerated() where !blankBacks || index % 2 == 0 {
            sides[index] = try await BatchReader.read(RawPage(index: index, side: index % 2 == 0 ? .front : .back, image: image, dpi: 300))
        }
        var sheets = BatchReader.sheets(from: sides, pageCount: fixtures.count)
        for (offset, photo) in photos.enumerated() {
            let front = try await BatchReader.read(RawPage(index: 0, side: .front, image: photo, dpi: 300))
            let back = offset == 2 ? try await BatchReader.read(RawPage(index: 1, side: .back, image: Self.handwrittenBack(), dpi: 300)) : nil
            if front != nil || back != nil { sheets.append(ScannedSheet(id: sheets.count, front: front, back: back)) }
        }
        job.send(.read(done: fixtures.count, total: fixtures.count + 1))
        var batch = Batch(sheets: sheets)
        batch.setDocument(try await job.reader.document(for: batch))
        job.send(.review(batch))
        return batch
    }

    /// Shows the Filed screen without touching any folder: the receipt describes the filing the
    /// suggestion would make.
    private func file(_ batch: Batch) {
        guard let document = batch.document else { return }
        var filed = batch
        let relative = "\(document.destinationPath)/\(document.fileName).pdf"
        filed.recordFiling(document: FilingReceipt(fileURL: job.reader.root.appending(path: relative), createdFolders: [],
                                                   stagedURL: document.stagedURL, relativePath: relative))
        job.send(.file)
        job.send(.filedPart(filed))
    }

    private func fixtureImages() throws -> [CGImage] {
        guard let folder = ProcessInfo.processInfo.environment["FASTSCAN_FIXTURES"] else { return [] }
        return try (1...4).map { page in
            let url = URL(filePath: folder).appending(path: "page-00\(page).png")
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
            else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
            return image
        }
    }

    static func syntheticPhotos() -> [CGImage] {
        let palettes: [(sky: (Double, Double, Double), ground: (Double, Double, Double), subject: (Double, Double, Double))] = [
            ((0.98, 0.72, 0.45), (0.25, 0.30, 0.38), (0.12, 0.12, 0.15)),
            ((0.55, 0.75, 0.95), (0.20, 0.45, 0.30), (0.85, 0.30, 0.25)),
            ((0.80, 0.85, 0.90), (0.15, 0.35, 0.55), (0.95, 0.90, 0.80)),
            ((0.95, 0.85, 0.60), (0.55, 0.40, 0.25), (0.30, 0.20, 0.15)),
            ((0.40, 0.50, 0.70), (0.10, 0.20, 0.25), (0.90, 0.75, 0.40)),
            ((0.90, 0.60, 0.65), (0.35, 0.25, 0.35), (0.20, 0.15, 0.25)),
        ]
        return palettes.enumerated().map { index, palette in
            let (width, height) = index == 4 ? (1200, 1800) : (1800, 1200)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let colors = [CGColor(red: palette.sky.0, green: palette.sky.1, blue: palette.sky.2, alpha: 1),
                          CGColor(red: palette.sky.0 * 0.8, green: palette.sky.1 * 0.85, blue: palette.sky.2, alpha: 1)]
            let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: CGFloat(height) * 0.4), options: [.drawsAfterEndLocation])
            context.setFillColor(red: palette.ground.0, green: palette.ground.1, blue: palette.ground.2, alpha: 1)
            let horizon = CGFloat(height) * (0.35 + 0.05 * CGFloat(index % 3))
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLine(to: CGPoint(x: 0, y: horizon))
            for step in 0...12 {
                let x = CGFloat(width) * CGFloat(step) / 12
                context.addLine(to: CGPoint(x: x, y: horizon + CGFloat(sin(Double(step + index) * 1.3)) * 60))
            }
            context.addLine(to: CGPoint(x: CGFloat(width), y: 0))
            context.fillPath()
            context.setFillColor(red: palette.subject.0, green: palette.subject.1, blue: palette.subject.2, alpha: 1)
            context.fillEllipse(in: CGRect(x: CGFloat(width) * (0.3 + 0.08 * CGFloat(index)), y: horizon - 80, width: 220, height: 320))
            context.fillEllipse(in: CGRect(x: CGFloat(width) * (0.3 + 0.08 * CGFloat(index)) + 50, y: horizon + 220, width: 120, height: 120))
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<6000 {
                let gray = CGFloat.random(in: 0...1, using: &rng)
                context.setFillColor(gray: gray, alpha: 0.06)
                context.fill(CGRect(x: .random(in: 0..<CGFloat(width), using: &rng), y: .random(in: 0..<CGFloat(height), using: &rng), width: 3, height: 3))
            }
            return context.makeImage()!
        }
    }

    static func handwrittenBack() -> CGImage {
        let width = 1800, height = 1200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Bradley Hand" as CFString, 150, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Tahoe ’84", attributes: [
            .init(kCTFontAttributeName as String): font, .init(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        context.setFillColor(red: 0.15, green: 0.2, blue: 0.45, alpha: 1)
        context.textPosition = CGPoint(x: 420, y: 560)
        CTLineDraw(line, context)
        return context.makeImage()!
    }
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
