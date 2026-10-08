import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

public struct PhotoExport: Sendable {
    /// JPEG with the caption embedded as its IPTC caption and EXIF description.
    public var jpeg: Data
    public var caption: String?

    public init(_ photo: PhotoDraft) throws {
        caption = photo.caption
        jpeg = try Self.jpeg(photo.sheet.face.image, dpi: photo.sheet.face.dpi, caption: photo.caption)
    }

    static func jpeg(_ image: CGImage, dpi: Int, caption: String?) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PDFBuilder.Failure.cannotEncode }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        ]
        if let caption {
            properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCaptionAbstract: caption]
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFImageDescription: caption]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PDFBuilder.Failure.cannotEncode }
        return data as Data
    }
}

public struct PhotoSaveResult: Sendable, Equatable {
    public var saved: Int
    public var album: String
    /// Whether captions went into Photos' own caption field, not only the embedded metadata.
    public var captionsInPhotos: Bool
    public var localIdentifiers: [String]
}

/// Behind a protocol so tests, the CLI, and demos never add to the real library.
public protocol PhotoLibraryWriter: Sendable {
    func save(_ photos: [PhotoExport], album: String) async throws -> PhotoSaveResult
    func remove(_ result: PhotoSaveResult) async throws
}

public enum PhotoAlbum {
    /// `Scanned Oct 7, 2026`
    public static func name(for date: CalendarDate) -> String { "Scanned \(date.display)" }
}

public struct DryRunPhotoWriter: PhotoLibraryWriter {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public func save(_ photos: [PhotoExport], album: String) async throws -> PhotoSaveResult {
        let folder = directory.appending(path: album, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var identifiers: [String] = []
        var manifest: [[String: String]] = []
        for (number, photo) in photos.enumerated() {
            let name = "Photo \(number + 1).jpg"
            try photo.jpeg.write(to: folder.appending(path: name))
            identifiers.append(folder.appending(path: name).path)
            manifest.append(["file": name, "caption": photo.caption ?? ""])
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appending(path: "captions.json"))
        return PhotoSaveResult(saved: photos.count, album: album, captionsInPhotos: false, localIdentifiers: identifiers)
    }

    public func remove(_ result: PhotoSaveResult) async throws {
        for path in result.localIdentifiers { try? FileManager.default.removeItem(atPath: path) }
    }
}

/// Adds photos to the system library in a dated album. On macOS 27 the back-of-print writing
/// goes into Photos' caption field (`PHAssetChangeRequest.caption`); on 26 it is only embedded
/// in the JPEG's IPTC caption, which Photos shows as the description on import.
public struct PhotoKitWriter: PhotoLibraryWriter {
    public enum Failure: LocalizedError {
        case notAuthorized

        public var errorDescription: String? {
            "FastScan isn't allowed to add to your photo library. Allow it in System Settings > Privacy & Security > Photos."
        }
    }

    public init() {}

    public func save(_ photos: [PhotoExport], album: String) async throws -> PhotoSaveResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw Failure.notAuthorized }
        let library = PHPhotoLibrary.shared()
        nonisolated(unsafe) var identifiers: [String] = []
        let captionsInPhotos: Bool
        if #available(macOS 27, *) { captionsInPhotos = true } else { captionsInPhotos = false }
        try await library.performChanges {
            let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            var collection: PHAssetCollection?
            existing.enumerateObjects { item, _, stop in
                if item.localizedTitle == album { collection = item; stop.pointee = true }
            }
            let albumRequest = collection.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
            var placeholders: [PHObjectPlaceholder] = []
            for photo in photos {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: photo.jpeg, options: nil)
                if #available(macOS 27, *), let caption = photo.caption { request.caption = caption }
                if let placeholder = request.placeholderForCreatedAsset {
                    placeholders.append(placeholder)
                    identifiers.append(placeholder.localIdentifier)
                }
            }
            albumRequest.addAssets(placeholders as NSArray)
        }
        return PhotoSaveResult(saved: photos.count, album: album, captionsInPhotos: captionsInPhotos, localIdentifiers: identifiers)
    }

    public func remove(_ result: PhotoSaveResult) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: result.localIdentifiers, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
