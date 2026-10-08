import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ScanKit

/// A service invoice from Sierra Ridge Auto Care, the fictional shop script/render-demo-pages draws,
/// as OCR reads one, misreads included: `070CT26` for `07OCT26` and `30, 000` for `30,000`.
let sampleInvoiceText = """
    CUSTOMER #: 2087431
    0048213
    * INVOICE*
    ALEX RIVERA
    742 JUNIPER HOLLOW LN
    GRASS VALLEY, CA 95945
    SIERRA RIDGE AUTO CARE
    Independent Subaru & Import Service
    sierraridgeautocare.com
    VIN 4S4DEMXXXM0000000
    2021 SUBARU OUTBACK LIMITED
    DEL. DATE 14MAR21 R.O. OPENED 07:42 060CT26 READY 15: 10 070CT26
    ENG: 2. 5 _Liter_Boxer TRN:CVT
    A PERFORM 30, 000 MILE SERVICE
    30000 PERFORM 30,000 MILE SERVICE
    1 15208AA170 OIL FILTER
    1 16546AA12A ENGINE AIR FILTER
    Drain old engine oil, replaced crush washer, oil filter
    ALL PARTS ARE NEW UNLESS OTHERWISE INDICATED. PARTS AMOUNT
    REPLACEMENT PARTS AND ACCESSORIES UNLIMITED MILEAGE LIMITED PARTS WARRANTY
    """

/// The shapes that compete for that invoice in a family's tree: the right vehicle's other folders,
/// another Subaru that also had a 30,000 mile service, and the home at the customer address.
let sampleCabinet = [
    "Vehicles/2021 Subaru Outback/Purchase/Window Sticker.pdf",
    "Vehicles/2021 Subaru Outback/Purchase/Bill of Sale.pdf",
    "Vehicles/2021 Subaru Outback/Services/2024-03-14 Oil Change/Receipt.pdf",
    "Vehicles/2021 Subaru Outback/Services/2025-04-02 10,000 Mile Service/Invoice.pdf",
    "Vehicles/2021 Subaru Outback/Services/2025-11-18 20,000 Mile Service/Invoice.pdf",
    "Vehicles/2021 Subaru Outback/Services/2025-11-18 20,000 Mile Service/Receipt.pdf",
    "Vehicles/2021 Subaru Outback/Parts/Cargo Tray Receipt.pdf",
    "Vehicles/2016 Subaru Forester/Services/2025-01-07 30,000 Mile Service/Invoice.pdf",
    "Vehicles/2018 Toyota Tacoma/Services/2025-08-09 Brake Job/Invoice.pdf",
    "Homes/742 Juniper Hollow Ln/Services/Pool Service.pdf",
    "Homes/742 Juniper Hollow Ln/Grass Valley Alarm Permit.pdf",
    "Medical/FSA-HSA Receipts/Receipt #4471920.pdf",
    "Receipts/Ring.pdf",
    "Inbox/Scan.pdf",
]

@Suite struct CandidateRankerTests {
    let today = CalendarDate(year: 2026, month: 10, day: 7)!

    @Test func readsTheInvoicesFacts() {
        let evidence = DocumentEvidence(text: sampleInvoiceText, today: today)

        #expect(evidence.date == today)
        #expect(evidence.vehicles == [.init(vin: "4S4DEMXXXM0000000", year: 2021, make: "Subaru")])
        #expect(evidence.documentType == "Invoice")
        #expect(evidence.vendor == "Sierra Ridge Auto Care")
        #expect(evidence.title == "Sierra Ridge Auto Care invoice")
    }

    @Test func theVehiclesServicesFolderRanksFirstWithItsMatchingEvents() throws {
        let tree = try TemporaryTree(sampleCabinet)
        let index = try FolderIndex.build(root: tree.root)

        let ranked = CandidateRanker.rank(DocumentEvidence(text: sampleInvoiceText, today: today), in: index)

        #expect(ranked.first?.path == "Vehicles/2021 Subaru Outback/Services", "\(ranked.prefix(4).map { ($0.path, $0.score) })")
        #expect(ranked.first?.matchedEvents == ["2025-04-02 10,000 Mile Service", "2025-11-18 20,000 Mile Service"])
        #expect(!ranked.contains { $0.path.hasPrefix("Inbox") })
    }

    @Test func anOldEventFolderWinsOnlyForAPaperFromThatDay() throws {
        let tree = try TemporaryTree(sampleCabinet)
        let index = try FolderIndex.build(root: tree.root)
        let sameDay = sampleInvoiceText.replacingOccurrences(of: "070CT26", with: "18NOV25").replacingOccurrences(of: "060CT26", with: "17NOV25")

        let ranked = CandidateRanker.rank(DocumentEvidence(text: sameDay, today: today), in: index)

        #expect(ranked.first?.path == "Vehicles/2021 Subaru Outback/Services/2025-11-18 20,000 Mile Service")
    }

    @Test func eventPatternsGeneralizeNumbers() {
        let pattern = EventPattern("10,000 Mile Service")

        #expect(pattern?.firstMatch(in: "A PERFORM 30, 000 MILE SERVICE") == "30,000 Mile Service")
        #expect(pattern?.firstMatch(in: "OIL SERVICE") == nil)
        #expect(EventPattern("Oil Change") == nil)
    }

    /// The rendered demo invoice, read by OCR, against the demo cabinet:
    /// FASTSCAN_FIXTURES=<script/render-demo-pages output> FASTSCAN_MIRROR=<script/demo-cabinet output>/Rivera Family.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FASTSCAN_FIXTURES"] != nil
                   && ProcessInfo.processInfo.environment["FASTSCAN_MIRROR"] != nil))
    func demoInvoiceRanksTheOutbackServicesFolderFirstInTheDemoCabinet() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtures = URL(filePath: environment["FASTSCAN_FIXTURES"]!)
        var text = ""
        for page in 1...4 {
            let url = fixtures.appending(path: "page-00\(page).png")
            let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            text += try await TextRecognizer.recognize(PageProcessor.crop(image, dpi: 300)).map(\.text).joined(separator: "\n") + "\n"
        }
        let index = try FolderIndex.build(root: URL(filePath: environment["FASTSCAN_MIRROR"]!))

        let evidence = DocumentEvidence(text: text, today: today)

        let ranked = CandidateRanker.rank(evidence, in: index)

        #expect(evidence.vendor == "Sierra Ridge Auto Care")
        #expect(evidence.vehicles.map(\.vin) == ["4S4DEMXXXM0000000"])
        #expect(ranked.first?.path == "Vehicles/2021 Subaru Outback/Services", "\(ranked.prefix(4).map { ($0.path, $0.score) })")
    }
}
