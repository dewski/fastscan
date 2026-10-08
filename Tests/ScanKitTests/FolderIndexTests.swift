import Foundation
import Testing
@testable import ScanKit

/// A throwaway folder tree in the temporary directory, removed when the test ends.
final class TemporaryTree {
    let root: URL

    init(_ paths: [String]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "fastscan-tree-\(UUID())", directoryHint: .isDirectory)
        for path in paths {
            let url = root.appending(path: path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: path).path) }
}

@Suite struct FolderIndexTests {
    @Test func indexesFoldersAndExampleFilesButNotHiddenItemsOrPackageContents() throws {
        let tree = try TemporaryTree([
            "Vehicles/2021 Subaru Outback/Services/2025-04-02 10,000 Mile Service/Invoice.pdf",
            "Vehicles/2021 Subaru Outback/Window Sticker.pdf",
            "Medical/FSA-HSA Receipts/Receipt #4471920.pdf",
            "Medical/.secret/hidden.pdf",
            "Recipes/Pie.app/Contents/Info.plist",
            "Empty/",
        ])

        let index = try FolderIndex.build(root: tree.root)

        #expect(index.folders.map(\.path) == [
            "", "Empty", "Medical", "Medical/FSA-HSA Receipts", "Recipes", "Vehicles",
            "Vehicles/2021 Subaru Outback", "Vehicles/2021 Subaru Outback/Services",
            "Vehicles/2021 Subaru Outback/Services/2025-04-02 10,000 Mile Service",
        ])
        #expect(index.folder(at: "Recipes")?.exampleFiles == ["Pie.app"])
        #expect(index.folder(at: "Vehicles/2021 Subaru Outback")?.subfolders == ["Services"])
        #expect(index.folder(at: "Vehicles/2021 Subaru Outback")?.exampleFiles == ["Window Sticker.pdf"])
        #expect(index.folder(at: "Medical")?.subfolders == ["FSA-HSA Receipts"])
    }

    @Test func storeServesTheCacheAndRebuildsOnRefresh() async throws {
        let tree = try TemporaryTree(["Taxes/Taxes 2025/"])
        let cache = tree.root.appending(path: ".cache/index.json")
        let store = FolderIndexStore(cacheURL: cache)

        let first = try await store.current(root: tree.root)
        try FileManager.default.createDirectory(at: tree.root.appending(path: "Taxes/Taxes 2026"), withIntermediateDirectories: true)
        let cached = try await FolderIndexStore(cacheURL: cache).current(root: tree.root)
        let refreshed = try await store.refresh(root: tree.root)

        #expect(first.folder(at: "Taxes/Taxes 2026") == nil)
        #expect(cached == first)
        #expect(refreshed.folder(at: "Taxes/Taxes 2026") != nil)
    }
}
