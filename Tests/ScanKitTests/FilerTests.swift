import Foundation
import Testing
@testable import ScanKit

@Suite struct FilerTests {
    let services = "Vehicles/2021 Subaru Outback/Services"

    func staged(_ tree: TemporaryTree, _ name: String = "Invoice.pdf") throws -> URL {
        let url = tree.root.appending(path: ".staging/\(UUID())/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: url)
        return url
    }

    @Test func filesIntoANewEventFolderAndUndoRemovesIt() throws {
        let tree = try TemporaryTree(["\(services)/2025-11-12 20,000 Mile Service/Invoice.pdf"])
        let pdf = try staged(tree)

        let receipt = try Filer.file(pdf, name: "Invoice", folderPath: services, newSubfolder: "2026-10-07 30,000 Mile Service", root: tree.root)

        #expect(receipt.relativePath == "\(services)/2026-10-07 30,000 Mile Service/Invoice.pdf")
        #expect(tree.exists(receipt.relativePath))
        #expect(!FileManager.default.fileExists(atPath: pdf.path))

        try Filer.undo(receipt)

        #expect(!tree.exists("\(services)/2026-10-07 30,000 Mile Service"))
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        #expect(tree.exists("\(services)/2025-11-12 20,000 Mile Service/Invoice.pdf"))
    }

    @Test func undoKeepsACreatedFolderThatSomethingElseWasPutIn() throws {
        let tree = try TemporaryTree(["\(services)/"])
        let receipt = try Filer.file(try staged(tree), name: "Invoice", folderPath: services, newSubfolder: "2026-10-07 30,000 Mile Service", root: tree.root)
        try Data().write(to: tree.root.appending(path: "\(services)/2026-10-07 30,000 Mile Service/Receipt.pdf"))

        try Filer.undo(receipt)

        #expect(tree.exists("\(services)/2026-10-07 30,000 Mile Service/Receipt.pdf"))
        #expect(!tree.exists("\(services)/2026-10-07 30,000 Mile Service/Invoice.pdf"))
    }

    @Test func neverOverwritesAndNeverCreatesTheFolderItWasPointedAt() throws {
        let tree = try TemporaryTree(["Receipts/Invoice.pdf"])

        let receipt = try Filer.file(try staged(tree), name: "Invoice", folderPath: "Receipts", newSubfolder: nil, root: tree.root)

        #expect(receipt.relativePath == "Receipts/Invoice 2.pdf")
        #expect(receipt.createdFolders.isEmpty)
        #expect(throws: Filer.Failure.self) {
            try Filer.file(try staged(tree), name: "Invoice", folderPath: "Gone", newSubfolder: nil, root: tree.root)
        }
        #expect(!tree.exists("Gone"))
    }

    @Test func theInboxIsCreatedOnFirstUse() throws {
        let tree = try TemporaryTree(["Receipts/"])

        let receipt = try Filer.file(try staged(tree), name: "Scan", folderPath: "Inbox", newSubfolder: nil, root: tree.root)

        #expect(receipt.relativePath == "Inbox/Scan.pdf")
        #expect(receipt.createdFolders.map(\.lastPathComponent) == ["Inbox"])
    }

    @Test func refusesPathsThatEscapeTheCabinet() throws {
        let tree = try TemporaryTree(["Receipts/"])

        #expect(throws: Filer.Failure.self) {
            try Filer.file(try staged(tree), name: "x", folderPath: "../outside", newSubfolder: nil, root: tree.root)
        }
        #expect(Filer.safeFileName("a/b:c") == "a-b-c")
        #expect(Filer.safeFileName("..hidden") == "hidden")
    }
}
