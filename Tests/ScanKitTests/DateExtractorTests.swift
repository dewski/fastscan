import Testing
@testable import ScanKit

@Suite struct DateExtractorTests {
    let october7 = CalendarDate(year: 2026, month: 10, day: 7)!

    @Test(arguments: [
        "INV. DATE 07OCT26",
        "READY 14: 59 070CT26",
        "07 OCT 2026",
        "7-Oct-2026",
        "10/07/2026",
        "10/07/26",
        "10-07-2026",
        "Oct 7, 2026",
        "October 7th, 2026",
        "Oct. 07 2026",
        "on 2026-10-07 at noon",
    ])
    func readsEachPrintedForm(_ text: String) {
        #expect(DateExtractor.dates(in: text) == [october7])
    }

    @Test func ignoresDigitRunsThatAreNotDates() {
        let text = "VIN 4S4BTAFC1MJ2MAR21 SOLD-STK:52814N 31207/31209 4337 48213 13/45/2026 31FEB26"
        #expect(DateExtractor.dates(in: text) == [])
    }

    @Test func documentDateIsTheLatestDateThatIsNotInTheFuture() {
        let invoice = "DEL. DATE 09MAR24 R.O. OPENED 17:00 06OCT26 READY 14:59 07OCT26 WARRANTY EXPIRES 09MAR28"

        #expect(DateExtractor.documentDate(in: invoice, today: october7) == october7)
    }

    @Test func formatsForFoldersAndPeople() {
        #expect(october7.iso == "2026-10-07")
        #expect(october7.display == "Oct 7, 2026")
    }

    @Test func twoDigitYearsPivotAt1970() {
        #expect(DateExtractor.dates(in: "12/25/84") == [CalendarDate(year: 1984, month: 12, day: 25)!])
    }
}
