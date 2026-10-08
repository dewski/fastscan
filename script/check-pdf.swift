// Usage: swift script/check-pdf.swift <file.pdf> <page>:<text> [<page>:<text> ...]
// Asserts that PDFKit finds each text on the given 1-based page, then prints each page's size
// and how many characters of text it extracts.
import Foundation
import PDFKit

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first, let document = PDFDocument(url: URL(filePath: path)) else {
    print("cannot open PDF")
    exit(1)
}

for index in 0..<document.pageCount {
    let page = document.page(at: index)!
    let size = page.bounds(for: .mediaBox).size
    print("page \(index + 1): \(size.width / 72) x \(size.height / 72) in, \(page.string?.count ?? 0) chars of text")
}

var failed = false
for expectation in arguments.dropFirst() {
    let parts = expectation.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let pageNumber = Int(parts[0]) else { continue }
    let text = String(parts[1])
    let matches = document.findString(text, withOptions: [])
    let pages = matches.compactMap { $0.pages.first }.map { document.index(for: $0) + 1 }
    let ok = pages.contains(pageNumber)
    failed = failed || !ok
    let where_ = matches.first { $0.pages.first.map { document.index(for: $0) + 1 } == pageNumber }
        .map { match in match.bounds(for: match.pages[0]).integral }
    print("\(ok ? "PASS" : "FAIL") \"\(text)\" expected on page \(pageNumber), found on pages \(pages), first at \(where_.map { "\($0)" } ?? "-") pt")
}
exit(failed ? 1 : 0)
