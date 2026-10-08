import CoreGraphics
import Foundation

public enum NotFoundReason: Equatable, Sendable {
    case noScanner
    case localNetworkDenied
}

public enum ReviewMode: Equatable, Sendable {
    case mixed
    case document
}

/// Every state after discovery carries the scanner, so "scan with no scanner" can't be represented
/// and finishing knows where to return. Heavy results travel in `Batch`.
public enum ScanState: Equatable, Sendable {
    case looking
    case notFound(NotFoundReason)
    case ready(ScannerEndpoint)
    /// Opening the scanner before the feeder moves, which takes a few seconds. `keptPages` are
    /// the non-blank sides kept from before a jam.
    case starting(ScannerEndpoint, keptPages: Int)
    /// `pages` counts non-blank sides, including those kept from before a jam.
    case scanning(ScannerEndpoint, pages: Int)
    /// The feeder jammed; the `pages` (non-blank sides) of the complete sheets so far are kept.
    case jammed(ScannerEndpoint, pages: Int)
    case reading(ScannerEndpoint, done: Int, total: Int)
    case reviewing(ScannerEndpoint, Batch, ReviewMode)
    case filing(ScannerEndpoint, Batch, ReviewMode)
    case filed(ScannerEndpoint, Batch)
    case failed(ScannerEndpoint?, message: String)

    public enum Event: Equatable, Sendable {
        case discover
        case found(ScannerEndpoint)
        case notFound(NotFoundReason)
        case start
        case resume(keptPages: Int)
        case connected
        case pageScanned
        case jammed(keptPages: Int)
        case read(done: Int, total: Int)
        case review(Batch)
        case revise(Batch)
        case focus(ReviewMode)
        case file
        case filedPart(Batch)
        case fileFailed
        case undone(Batch)
        case cancelled
        case done
        case failed(String)
    }

    /// All transitions live here. An event that doesn't apply to the current state is ignored.
    public func on(_ event: Event) -> ScanState {
        switch (self, event) {
        case (.looking, .found(let endpoint)), (.notFound, .found(let endpoint)):
            .ready(endpoint)
        case (.looking, .notFound(let reason)):
            .notFound(reason)
        case (.notFound, .discover), (.failed(nil, _), .discover):
            .looking
        case (.ready(let endpoint), .start), (.filed(let endpoint, _), .start), (.failed(let endpoint?, _), .start):
            .starting(endpoint, keptPages: 0)
        case (.jammed(let endpoint, _), .resume(let kept)):
            .starting(endpoint, keptPages: kept)
        case (.starting(let endpoint, let kept), .connected):
            .scanning(endpoint, pages: kept)
        case (.scanning(let endpoint, let pages), .pageScanned), (.starting(let endpoint, let pages), .pageScanned):
            .scanning(endpoint, pages: pages + 1)
        case (.scanning(let endpoint, _), .jammed(let kept)), (.starting(let endpoint, _), .jammed(let kept)):
            .jammed(endpoint, pages: kept)
        case (.starting(let endpoint, _), .read(let done, let total)), (.scanning(let endpoint, _), .read(let done, let total)),
             (.jammed(let endpoint, _), .read(let done, let total)), (.reading(let endpoint, _, _), .read(let done, let total)):
            .reading(endpoint, done: min(done, total), total: total)
        case (.reading(let endpoint, _, _), .review(let batch)):
            .reviewing(endpoint, batch, batch.isMixed ? .mixed : .document)
        case (.reviewing(let endpoint, _, let mode), .revise(let batch)):
            .reviewing(endpoint, batch, batch.isMixed || batch.isRebuildingDocument ? mode : .document)
        case (.reviewing(let endpoint, let batch, _), .focus(let mode)):
            .reviewing(endpoint, batch, mode == .mixed && !batch.isMixed ? .document : mode)
        case (.reviewing(let endpoint, let batch, let mode), .file):
            .filing(endpoint, batch, mode)
        case (.filing(let endpoint, _, _), .filedPart(let batch)):
            batch.isComplete ? .filed(endpoint, batch) : .reviewing(endpoint, batch, .mixed)
        case (.filing(let endpoint, let batch, let mode), .fileFailed):
            .reviewing(endpoint, batch, mode)
        case (.filed(let endpoint, _), .undone(let batch)), (.reviewing(let endpoint, _, _), .undone(let batch)):
            .reviewing(endpoint, batch, batch.isMixed ? .mixed : .document)
        case (.starting(let endpoint, _), .cancelled), (.scanning(let endpoint, _), .cancelled), (.reading(let endpoint, _, _), .cancelled), (.jammed(let endpoint, _), .cancelled):
            .ready(endpoint)
        case (.reviewing(let endpoint, _, _), .done), (.filed(let endpoint, _), .done), (.failed(let endpoint?, _), .done):
            .ready(endpoint)
        case (.looking, .failed(let message)):
            .failed(nil, message: message)
        case (_, .failed(let message)) where endpoint != nil:
            .failed(endpoint, message: message)
        default:
            self
        }
    }

    public var endpoint: ScannerEndpoint? {
        switch self {
        case .looking, .notFound: nil
        case .ready(let endpoint), .starting(let endpoint, _), .scanning(let endpoint, _), .jammed(let endpoint, _), .reading(let endpoint, _, _),
             .reviewing(let endpoint, _, _), .filing(let endpoint, _, _), .filed(let endpoint, _):
            endpoint
        case .failed(let endpoint, _): endpoint
        }
    }

    public var batch: Batch? {
        switch self {
        case .reviewing(_, let batch, _), .filing(_, let batch, _), .filed(_, let batch): batch
        default: nil
        }
    }

    public var isBusy: Bool {
        switch self {
        case .looking, .starting, .scanning, .reading, .filing: true
        default: false
        }
    }
}

/// Always both sides, at 300 dpi in color: OCR and photo detection need the detail, and what is
/// stored is reduced afterwards.
public let fastScanSettings = ScanSettings(sides: .duplex, color: .color, dpi: 300)

/// Drives one scanner from discovery through filing. Sides are read as they arrive, overlapping
/// with feeding; nothing is written into the filing cabinet until `file` is called.
@MainActor
public final class ScanJob {
    public private(set) var state: ScanState = .looking {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: ((ScanState) -> Void)?
    public var onSide: ((CGImage) -> Void)?
    /// A filing or undo that failed; the batch stays in review so nothing is lost.
    public var onError: ((String) -> Void)?
    public var reader: BatchReader
    public var photoWriter: any PhotoLibraryWriter
    public var albumDate: () -> CalendarDate = { CalendarDate(.now) }

    private var session: SANESession?
    private var stopRequested = false
    private var keptSheets: [ScannedSheet] = []
    private var pageCount = 0
    private var readCount = 0
    private var feeding = false
    private var reencoding: Task<Void, Never>?

    public init(reader: BatchReader, photoWriter: any PhotoLibraryWriter) {
        self.reader = reader
        self.photoWriter = photoWriter
    }

    public func send(_ event: ScanState.Event) {
        state = state.on(event)
    }

    public func discover() async {
        send(.discover)
        do {
            let endpoint = try await ScannerDiscovery.discover(timeout: .seconds(10), firstOnly: true).first
            send(endpoint.map(ScanState.Event.found) ?? .notFound(.noScanner))
        } catch ScannerDiscovery.Failure.localNetworkDenied {
            send(.notFound(.localNetworkDenied))
        } catch {
            send(.failed(error.localizedDescription))
        }
    }

    public func scan() async {
        guard state.on(.start) != state else { return }
        keptSheets = []
        send(.start)
        await feed()
    }

    public func scanRest() async {
        guard case .jammed = state else { return }
        send(.resume(keptPages: keptSheets.reduce(0) { $0 + $1.sides.count }))
        await feed()
    }

    public func finishWithKept() async {
        guard case .jammed = state else { return }
        await read(keptSheets)
    }

    public func stop() {
        stopRequested = true
        session?.cancel()
    }

    /// Moves the sheet at once, so the screen can show the document being rebuilt, then rebuilds it.
    public func flip(_ sheetID: Int) async {
        guard case .reviewing(_, let original, _) = state, !original.documentFiled, !original.photosFiled,
              !original.isRebuildingDocument else { return }
        reencoding?.cancel()
        var batch = original
        batch.flip(sheetID)
        send(.revise(batch))
        do {
            batch.setDocument(try await reader.document(for: batch))
            send(.revise(batch))
        } catch {
            send(.revise(original))
            onError?(error.localizedDescription)
        }
    }

    public func focus(_ mode: ReviewMode) { send(.focus(mode)) }

    public func rename(_ name: String) {
        guard case .reviewing(_, var batch, _) = state, let document = batch.document else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != document.fileName else { return }
        let renamed = document.stagedURL.deletingLastPathComponent().appending(path: "\(Filer.safeFileName(trimmed)).pdf")
        if (try? FileManager.default.moveItem(at: document.stagedURL, to: renamed)) == nil, !FileManager.default.fileExists(atPath: renamed.path) {
            return
        }
        batch.editDocument {
            $0.fileName = trimmed
            $0.stagedURL = renamed
        }
        send(.revise(batch))
    }

    public func choose(folderPath: String, newSubfolder: String?) {
        guard case .reviewing(_, var batch, _) = state else { return }
        batch.editDocument {
            $0.folderPath = folderPath
            $0.newSubfolder = newSubfolder
        }
        send(.revise(batch))
    }

    @discardableResult
    public func chooseColor(_ mode: ColorMode) -> Task<Void, Never>? { reencode { $0.color = mode } }

    @discardableResult
    public func choosePages(_ selection: PageSelection) -> Task<Void, Never>? { reencode { $0.selection = selection } }

    /// Re-encodes the document's pages off the main actor. The draft records the choice at once,
    /// so the screen can show the wait; the latest choice wins, and the returned task finishes
    /// once the pages (or a later choice) have landed.
    private func reencode(_ change: (inout PageEncoding) -> Void) -> Task<Void, Never>? {
        guard case .reviewing(_, var batch, _) = state, let document = batch.document, !batch.documentFiled else { return nil }
        var wanted = document.encoding
        change(&wanted)
        guard wanted != document.encoding else { return nil }
        reencoding?.cancel()
        reencoding = nil
        batch.editDocument { $0.encoding = wanted }
        send(.revise(batch))
        guard batch.document?.isReencoding == true else { return nil }
        let reader = self.reader
        let task = Task {
            do {
                apply(try await reader.reencode(batch, as: wanted))
            } catch is CancellationError {
            } catch {
                cancelReencode(to: wanted)
                onError?(error.localizedDescription)
            }
        }
        reencoding = task
        return task
    }

    private func apply(_ reencoded: ReencodedPages) {
        guard case .reviewing(_, var batch, _) = state, batch.id == reencoded.batchID, let document = batch.document,
              document.accepts(reencoded)
        else {
            try? FileManager.default.removeItem(at: reencoded.pdf)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(document.stagedURL, withItemAt: reencoded.pdf)
        } catch {
            try? FileManager.default.removeItem(at: reencoded.pdf)
            cancelReencode(to: reencoded.encoding)
            onError?(error.localizedDescription)
            return
        }
        batch.editDocument { $0.setPages(reencoded.pages, encodedAs: reencoded.encoding) }
        send(.revise(batch))
    }

    /// Puts the choice back to what the pages hold, so a failed re-encode doesn't leave the screen waiting.
    private func cancelReencode(to encoding: PageEncoding) {
        guard case .reviewing(_, var batch, _) = state, let document = batch.document, document.encoding == encoding else { return }
        batch.editDocument { $0.encoding = $0.pagesEncoding }
        send(.revise(batch))
    }

    public func fileDocument(toInbox: Bool = false) async {
        guard case .reviewing(_, var batch, _) = state, let document = batch.document, !batch.documentFiled,
              !document.isReencoding else { return }
        if toInbox {
            batch.editDocument {
                $0.folderPath = CandidateRanker.inboxName
                $0.newSubfolder = nil
            }
        }
        send(.file)
        do {
            let filed = try await fileDocument(of: batch)
            batch.recordFiling(document: filed)
            if !toInbox { recordFeedback(document) }
            send(.filedPart(batch))
        } catch {
            send(.fileFailed)
            onError?(error.localizedDescription)
        }
    }

    public func fileAll() async {
        guard case .reviewing(_, var batch, _) = state, batch.document?.isReencoding != true, !batch.isRebuildingDocument else { return }
        send(.file)
        do {
            if let document = batch.document, !batch.documentFiled {
                batch.recordFiling(document: try await fileDocument(of: batch))
                recordFeedback(document)
            }
            if !batch.photos.isEmpty, !batch.photosFiled {
                let exports = try batch.photos.map(PhotoExport.init)
                batch.recordFiling(photos: try await photoWriter.save(exports, album: PhotoAlbum.name(for: albumDate())))
            }
            send(.filedPart(batch))
        } catch {
            // A document filed before the photos failed stays filed, and Undo can still take it back.
            send(.filedPart(batch))
            if case .filed = state {} else { send(.fileFailed) }
            onError?(error.localizedDescription)
        }
    }

    /// Moves the document back out of the cabinet (removing a folder the filing created if it is
    /// empty again) and removes photos it added, then returns to review.
    public func undo() async {
        guard var batch = state.batch, batch.documentFiled || batch.photosFiled else { return }
        do {
            if let receipt = batch.documentReceipt {
                try Filer.undo(receipt)
                batch.recordFiling(document: nil)
            }
            if let result = batch.photoResult {
                try await photoWriter.remove(result)
                batch.recordFiling(photos: nil)
            }
            send(.undone(batch))
        } catch {
            onError?(error.localizedDescription)
        }
    }

    public func finish() {
        if let batch = state.batch, !batch.documentFiled {
            try? FileManager.default.removeItem(at: reader.stagingDirectory.appending(path: batch.id.uuidString))
        }
        send(.done)
    }

    private func fileDocument(of batch: Batch) async throws -> FilingReceipt? {
        guard let document = batch.document else { return nil }
        let root = reader.root
        return try await Task.detached {
            try Filer.file(document.stagedURL, name: document.fileName, folderPath: document.folderPath,
                           newSubfolder: document.newSubfolder, root: root)
        }.value
    }

    private func recordFeedback(_ document: DocumentDraft) {
        guard document.isEdited else { return }
        try? reader.feedbackStore.record(FilingFeedback(
            title: document.suggestion.title, documentType: document.evidence.documentType, vendor: document.evidence.vendor,
            suggestedPath: document.suggestion.destinationPath, chosenPath: document.destinationPath,
            suggestedName: document.suggestion.fileName, chosenName: document.fileName))
    }

    private func feed() async {
        guard let endpoint = state.endpoint else { return }
        stopRequested = false
        let session = SANESession()
        self.session = session
        let firstSheetID = (keptSheets.last?.id ?? -1) + 1
        pageCount = 0
        feeding = true
        readCount = 0

        // Sides are read one at a time as they arrive, while the feeder keeps going.
        let (arrivals, arrival) = AsyncStream.makeStream(of: RawPage.self)
        let reading = Task {
            var sides: [Int: ScannedSide] = [:]
            for await raw in arrivals {
                let side = try await BatchReader.read(raw)
                sides[raw.index] = side
                readCount += 1
                if let side {
                    onSide?(side.image)
                    send(.pageScanned)
                }
                if !feeding { send(.read(done: readCount, total: pageCount + 1)) }
            }
            return sides
        }

        var failure: (any Error)?
        do {
            try await session.open(endpoint)
            try await session.apply(fastScanSettings)
            send(.connected)
            for try await raw in session.pages() {
                pageCount = raw.index + 1
                arrival.yield(raw)
            }
        } catch SANEError.cancelled where stopRequested {
            // Stop keeps what was scanned.
        } catch {
            failure = error
        }
        arrival.finish()
        feeding = false
        await session.close()
        self.session = nil

        if case SANEError.jammed? = failure {
            // A jam usually catches a sheet halfway; keep only sheets whose both sides came through.
            pageCount -= pageCount % 2
        } else if let failure, !(failure as? SANEError == .feederEmpty && !keptSheets.isEmpty) {
            reading.cancel()
            if (failure as? SANEError) == .cancelled { send(.cancelled) } else {
                send(.failed((failure as? LocalizedError)?.errorDescription ?? "\(failure)"))
            }
            return
        } else if failure == nil {
            send(.read(done: readCount, total: pageCount + 1))
        }

        do {
            let sides = try await reading.value
            keptSheets += BatchReader.sheets(from: sides, pageCount: pageCount, firstSheetID: firstSheetID)
        } catch {
            send(.failed(error.localizedDescription))
            return
        }
        if case SANEError.jammed? = failure {
            send(.jammed(keptPages: keptSheets.reduce(0) { $0 + $1.sides.count }))
        } else {
            await read(keptSheets)
        }
    }

    private func read(_ sheets: [ScannedSheet]) async {
        guard !sheets.isEmpty else {
            send(.failed("Every page was blank, so there was nothing to file."))
            return
        }
        let pages = sheets.reduce(0) { $0 + $1.sides.count }
        // Finishing after a jam comes straight here; the suggestion takes seconds, so show it.
        send(.read(done: pages, total: pages + 1))
        let batch = Batch(sheets: sheets)
        do {
            var reviewed = batch
            reviewed.setDocument(try await reader.document(for: batch))
            send(.read(done: pages + 1, total: pages + 1))
            send(.review(reviewed))
        } catch {
            send(.failed(error.localizedDescription))
        }
    }
}
