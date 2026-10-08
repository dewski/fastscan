import CoreGraphics
import Foundation

public struct ScannedSide: Sendable {
    public var image: CGImage
    public var dpi: Int
    public var lines: [RecognizedLine]
    public var features: SideFeatures

    public init(image: CGImage, dpi: Int, lines: [RecognizedLine], features: SideFeatures) {
        self.image = image
        self.dpi = dpi
        self.lines = lines
        self.features = features
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
    public var processed: ProcessedPage { ProcessedPage(image: image, dpi: dpi, lines: lines) }
}

/// A sheet through the feeder. Blank sides are dropped as they arrive, so either side may be nil,
/// but never both.
public struct ScannedSheet: Sendable, Identifiable {
    public var id: Int
    public var front: ScannedSide?
    public var back: ScannedSide?

    public init(id: Int, front: ScannedSide?, back: ScannedSide?) {
        self.id = id
        self.front = front
        self.back = back
    }

    /// The side people look at: the front, unless it was blank (a sheet fed face down).
    public var face: ScannedSide { (front ?? back)! }
    public var sides: [ScannedSide] { [front, back].compactMap { $0 } }
    public var detectedKind: PageKind { PageKindClassifier.classify(face.features) }
}

public struct PhotoDraft: Sendable, Identifiable {
    public var id: Int { sheet.id }
    public var sheet: ScannedSheet
    public var caption: String? {
        guard sheet.front != nil, let back = sheet.back else { return nil }
        let text = back.lines.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Which sides of the paper sheets become the document's pages. Every non-blank side is kept
/// until filing, so this can change after the scan.
public enum PageSelection: String, Sendable, CaseIterable {
    case allSides, frontsOnly
}

/// How a document's pages are made from its sheets: which sides, stored in which color.
public struct PageEncoding: Equatable, Sendable {
    public var color: ColorMode
    public var selection: PageSelection

    public init(color: ColorMode, selection: PageSelection = .allSides) {
        self.color = color
        self.selection = selection
    }
}

extension ScannedSheet {
    /// Fronts only keeps the face, so a sheet fed face down keeps its one printed side.
    public func sides(_ selection: PageSelection) -> [ScannedSide] {
        switch selection {
        case .allSides: sides
        case .frontsOnly: [face]
        }
    }

    public var hasBothSides: Bool { front != nil && back != nil }
}

public struct DocumentDraft: Sendable {
    public var sheetIDs: [Int]
    public private(set) var pages: [StoredPage]
    /// What the family chose. While it differs from `pagesEncoding`, the pages are being
    /// re-encoded and the staged PDF still holds the old ones.
    public var encoding: PageEncoding
    public private(set) var pagesEncoding: PageEncoding
    public var stagedURL: URL
    public var evidence: DocumentEvidence
    public var result: SuggestionResult
    public var fileName: String
    public var folderPath: String
    public var newSubfolder: String?

    public init(sheetIDs: [Int], pages: [StoredPage], encoding: PageEncoding, stagedURL: URL, evidence: DocumentEvidence,
                result: SuggestionResult, fileName: String, folderPath: String, newSubfolder: String?) {
        self.sheetIDs = sheetIDs
        self.pages = pages
        self.encoding = encoding
        self.pagesEncoding = encoding
        self.stagedURL = stagedURL
        self.evidence = evidence
        self.result = result
        self.fileName = fileName
        self.folderPath = folderPath
        self.newSubfolder = newSubfolder
    }

    public var isReencoding: Bool { encoding != pagesEncoding }

    public mutating func setPages(_ pages: [StoredPage], encodedAs encoding: PageEncoding) {
        self.pages = pages
        pagesEncoding = encoding
    }

    /// Re-encoded pages are taken only for the encoding still chosen and the same sheets, so a
    /// superseded re-encode that finishes late is dropped.
    public func accepts(_ reencoded: ReencodedPages) -> Bool {
        isReencoding && reencoded.encoding == encoding && reencoded.sheetIDs == sheetIDs
    }

    public var suggestion: FilingSuggestion { result.suggestion }
    public var destinationPath: String {
        guard let newSubfolder else { return folderPath }
        return folderPath.isEmpty ? newSubfolder : "\(folderPath)/\(newSubfolder)"
    }
    public var isEdited: Bool {
        fileName != suggestion.fileName || destinationPath != suggestion.destinationPath
    }
}

/// A document's pages encoded again, with their PDF written beside the staged one, ready to
/// replace it.
public struct ReencodedPages: Sendable {
    public var batchID: UUID
    public var sheetIDs: [Int]
    public var encoding: PageEncoding
    public var pages: [StoredPage]
    public var pdf: URL
}

public enum ScanItem: Sendable, Identifiable {
    case document(DocumentDraft)
    case photo(PhotoDraft)

    public var id: String {
        switch self {
        case .document: "document"
        case .photo(let photo): "photo-\(photo.id)"
        }
    }
}

/// Everything a scan produced, with the family's per-sheet corrections to paper or photo.
///
/// Equality is by identity and revision: a batch is only ever changed by `ScanJob`, which bumps
/// the revision, and comparing CGImages pixel by pixel would be both slow and pointless.
public struct Batch: Sendable, Equatable {
    public let id: UUID
    public private(set) var revision = 0
    public private(set) var sheets: [ScannedSheet]
    public private(set) var kindOverrides: [Int: PageKind] = [:]
    public private(set) var document: DocumentDraft?
    /// A sheet was flipped and the document is being rebuilt for the new paper sheets.
    public private(set) var isRebuildingDocument = false
    public private(set) var documentReceipt: FilingReceipt?
    public private(set) var photoResult: PhotoSaveResult?

    public init(id: UUID = UUID(), sheets: [ScannedSheet]) {
        self.id = id
        self.sheets = sheets
    }

    public static func == (a: Batch, b: Batch) -> Bool { a.id == b.id && a.revision == b.revision }

    public func kind(of sheet: ScannedSheet) -> PageKind { kindOverrides[sheet.id] ?? sheet.detectedKind }

    public var paperSheets: [ScannedSheet] { sheets.filter { kind(of: $0) == .paper } }
    public var photos: [PhotoDraft] { sheets.filter { kind(of: $0) == .photo }.map(PhotoDraft.init) }

    public var items: [ScanItem] {
        (document.map { [ScanItem.document($0)] } ?? []) + photos.map(ScanItem.photo)
    }

    /// Paper and photos together get the mixed review; a lone document gets the filing card.
    public var isMixed: Bool { !photos.isEmpty }

    /// Some paper sheet has a back worth keeping, so the document can be fronts only.
    public var documentHasBacks: Bool { paperSheets.contains(where: \.hasBothSides) }

    public mutating func flip(_ sheetID: Int) {
        guard let sheet = sheets.first(where: { $0.id == sheetID }) else { return }
        let flipped = kind(of: sheet).flipped
        kindOverrides[sheetID] = flipped == sheet.detectedKind ? nil : flipped
        isRebuildingDocument = true
        revision += 1
    }

    public mutating func setDocument(_ document: DocumentDraft?) {
        self.document = document
        isRebuildingDocument = false
        revision += 1
    }

    public mutating func editDocument(_ edit: (inout DocumentDraft) -> Void) {
        guard var document else { return }
        edit(&document)
        self.document = document
        revision += 1
    }

    public var documentFiled: Bool { documentReceipt != nil }
    public var photosFiled: Bool { photoResult != nil }
    public var isComplete: Bool { (document == nil || documentFiled) && (photos.isEmpty || photosFiled) }

    public mutating func recordFiling(document receipt: FilingReceipt?) {
        documentReceipt = receipt
        revision += 1
    }

    public mutating func recordFiling(photos result: PhotoSaveResult?) {
        photoResult = result
        revision += 1
    }

    public mutating func append(_ more: [ScannedSheet]) {
        sheets += more
        revision += 1
    }
}
