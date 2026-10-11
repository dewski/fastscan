import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ScanKit

/// Plays the scanner's side of a session: each host packet must match the next step, and the
/// step's reply is queued for the host to read.
actor ScriptedScanner: ScannerTransport {
    struct Step {
        var expect: [UInt8]
        var reply: [UInt8]
    }

    private var steps: [Step]
    private var pending: [UInt8]
    private(set) var unmatched: [String] = []

    init(_ steps: [Step], greeting: [UInt8] = [0x01, 0x04, 0x00, 0x00, 0x00]) {
        self.steps = steps
        pending = Self.packet(0x8000, greeting)
    }

    var finished: Bool { steps.isEmpty }

    func send(_ bytes: [UInt8]) async throws {
        guard !steps.isEmpty else {
            unmatched.append("extra packet \(ESCI2.printable(bytes))")
            throw ScannerError.connection("script ended")
        }
        let step = steps.removeFirst()
        if bytes != step.expect {
            unmatched.append("sent \(ESCI2.printable(bytes)), expected \(ESCI2.printable(step.expect))")
        }
        pending += step.reply
    }

    func receive(exactly count: Int) async throws -> [UInt8] {
        guard pending.count >= count else { throw ScannerError.connection("nothing to read") }
        defer { pending.removeFirst(count) }
        return Array(pending.prefix(count))
    }

    // MARK: Building a script

    static func packet(_ type: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x49, 0x53, UInt8(type >> 8), UInt8(type & 0xFF), 0x38, 0x0C]
        bytes.appendBigEndian(UInt32(payload.count))
        return bytes + [0x00, 0x00] + payload
    }

    static func reply(_ payload: [UInt8]) -> [UInt8] { packet(0xA000, payload) }

    static let lock = Step(expect: ESCI2.packet(.lock, payload: ESCI2.lockPayload), reply: packet(0xA100, [0x06]))
    static let unlock = Step(expect: ESCI2.packet(.unlock), reply: packet(0xA101, []))

    static func mode(_ letter: Character) -> Step {
        Step(expect: ESCI2.request(ESCI2.modeBytes(letter), replyLength: 1), reply: reply([0x06]))
    }

    /// A command without parameters, its reply block, and the fetch of `data` if there is any.
    static func command(_ name: String, tokens: String = "", data: [UInt8] = []) -> [Step] {
        let block = ESCI2Tests.replyBlock(ESCI2.padded(name) + "x" + ESCI2.hexDigits(data.count, count: 7) + tokens)
        var steps = [Step(expect: ESCI2.request(ESCI2.commandBlock(name), replyLength: 64), reply: reply(block))]
        if !data.isEmpty { steps.append(Step(expect: ESCI2.request([], replyLength: data.count), reply: reply(data))) }
        return steps
    }

    static func opening(product: String = "FF-680W") -> [Step] {
        [lock, mode("Y")]
            + command("INFO", data: Array("#ADFTYPEFEED#PRDh\(ESCI2.hexDigits(product.utf8.count, count: 3))\(product)#EXI".utf8))
            + command("EXI", data: ESCI2Tests.exi)
            + command("FIN")
    }

    static func startingScan(sides: Sides, dpi: Int, length: Int, status: [UInt8] = []) -> [Step] {
        let parameters = ESCI2.encode(ESCI2.scanParameters(sides: sides, dpi: dpi, length: length))
        return [mode("Y")] + command("STAT", data: status) + command("FIN") + [mode("X")] + command("STAT") + [
            Step(expect: ESCI2.request(ESCI2.commandBlock("PARA", parameterLength: parameters.count), replyLength: 0), reply: reply([])),
            Step(expect: ESCI2.request(parameters, replyLength: 64), reply: reply(ESCI2Tests.replyBlock("PARAx0000000#parOK  "))),
        ] + command("TRDT")
    }
}

@Suite struct ScannerSessionTests {
    @Test func scansTwoSidesOfOneSheet() async throws {
        let front = try Self.jpeg(width: 6, height: 4)
        let back = try Self.jpeg(width: 5, height: 3)
        let split = front.count / 2
        let scanner = ScriptedScanner(
            ScriptedScanner.opening()
                + ScriptedScanner.startingScan(sides: .duplex, dpi: 600, length: 1550)
                // Before the first side, and between sides, replies carry no tokens. Within a side,
                // `#pst` and `#pen` come before `#typ`, as in the cancel captures.
                + ScriptedScanner.command("IMG")
                + ScriptedScanner.command("IMG")
                + ScriptedScanner.command("IMG", tokens: "#psti0000006d000i0000004#typIMGA", data: Array(front[..<split]))
                + ScriptedScanner.command("IMG", tokens: "#typIMGA")
                + ScriptedScanner.command("IMG", tokens: "#typIMGA", data: Array(front[split...]))
                + ScriptedScanner.command("IMG", tokens: "#peni0000006i0000004#typIMGA")
                + ScriptedScanner.command("IMG")
                + ScriptedScanner.command("IMG", tokens: "#psti0000005d000i0000003#typIMGB", data: back)
                + ScriptedScanner.command("IMG", tokens: "#peni0000005i0000003#lftd000#typIMGB")
                + ScriptedScanner.command("FIN")
                + [ScriptedScanner.unlock]
        )

        let session = ScannerSession()
        try await session.open(scanner)
        try await session.apply(ScanSettings(sides: .duplex, color: .color, dpi: 600))
        var pages: [RawPage] = []
        for try await page in session.pages() { pages.append(page) }
        await session.close()

        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
        #expect(pages.map(\.index) == [0, 1])
        #expect(pages.map(\.side) == [.front, .back])
        #expect(pages.map(\.dpi) == [600, 600])
        #expect(pages.map { [$0.image.width, $0.image.height] } == [[6, 4], [5, 3]])
    }

    @Test func cancelSendsCANThenFinishesAndUnlocks() async throws {
        let scanner = ScriptedScanner(
            ScriptedScanner.opening()
                + ScriptedScanner.startingScan(sides: .duplex, dpi: 300, length: 3600)
                + ScriptedScanner.command("CAN")
                + ScriptedScanner.command("FIN")
                + [ScriptedScanner.unlock]
        )
        let session = ScannerSession()
        try await session.open(scanner)
        try await session.apply(ScanSettings(sides: .duplex, color: .color, dpi: 300))
        // Requested before the stream starts, so the loop sees it before its first poll.
        session.cancel()
        await #expect(throws: ScannerError.cancelled) {
            for try await _ in session.pages() {}
        }
        await session.close()
        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
    }

    @Test func doubleFeedKeepsTheSheetsBeforeItAndClosesCleanly() async throws {
        let front = try Self.jpeg(width: 6, height: 4)
        let back = try Self.jpeg(width: 5, height: 3)
        let scanner = ScriptedScanner(
            ScriptedScanner.opening()
                + ScriptedScanner.startingScan(sides: .duplex, dpi: 600, length: 1550)
                + ScriptedScanner.command("IMG", tokens: "#psti0000006d000i0000004#typIMGA", data: front)
                + ScriptedScanner.command("IMG", tokens: "#peni0000006i0000004#typIMGA")
                + ScriptedScanner.command("IMG", tokens: "#psti0000005d000i0000003#typIMGB", data: back)
                + ScriptedScanner.command("IMG", tokens: "#peni0000005i0000003#typIMGB")
                // As captured: the error comes with a full-area #pst and the start of a JPEG.
                + ScriptedScanner.command("IMG", tokens: "#errADF DFED#psti0005100d000i0009300#typIMGA", data: Array(front.prefix(16)))
                + ScriptedScanner.command("FIN")
                + [ScriptedScanner.unlock]
        )
        let session = ScannerSession()
        try await session.open(scanner)
        try await session.apply(ScanSettings(sides: .duplex, color: .color, dpi: 600))
        var sides: [PageSide] = []
        await #expect(throws: ScannerError.doubleFeed) {
            for try await page in session.pages() { sides.append(page.side) }
        }
        await session.close()
        #expect(sides == [.front, .back])
        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
    }

    @Test func scannerStopButtonCancelsAfterFetchingTheAnnouncedData() async throws {
        let front = try Self.jpeg(width: 6, height: 4)
        let back = try Self.jpeg(width: 5, height: 3)
        let scanner = ScriptedScanner(
            ScriptedScanner.opening()
                + ScriptedScanner.startingScan(sides: .duplex, dpi: 600, length: 1550)
                + ScriptedScanner.command("IMG", tokens: "#psti0000006d000i0000004#typIMGA", data: front)
                + ScriptedScanner.command("IMG", tokens: "#peni0000006i0000004#typIMGA")
                + ScriptedScanner.command("IMG", tokens: "#psti0000005d000i0000003#typIMGB", data: back)
                + ScriptedScanner.command("IMG", tokens: "#peni0000005i0000003#typIMGB")
                + ScriptedScanner.command("IMG", tokens: "#psti0000006d000i0000004#typIMGA", data: Array(front.prefix(16)))
                // As captured: the Stop button's reply still announces data, which is fetched first.
                + ScriptedScanner.command("IMG", tokens: "#typIMGA#atnCAN ", data: Array(front.dropFirst(16).prefix(16)))
                + ScriptedScanner.command("CAN")
                + ScriptedScanner.command("FIN")
                + [ScriptedScanner.unlock]
        )
        let session = ScannerSession()
        try await session.open(scanner)
        try await session.apply(ScanSettings(sides: .duplex, color: .color, dpi: 600))
        var sides: [PageSide] = []
        await #expect(throws: ScannerError.stoppedAtScanner) {
            for try await page in session.pages() { sides.append(page.side) }
        }
        await session.close()
        #expect(sides == [.front, .back])
        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
    }

    @Test func emptyFeederFailsAndStillClosesCleanly() async throws {
        let scanner = ScriptedScanner(
            ScriptedScanner.opening()
                + [ScriptedScanner.mode("Y")]
                + ScriptedScanner.command("STAT", data: Array("#ERRADF PE  ".utf8))
                + ScriptedScanner.command("FIN")
                + [ScriptedScanner.unlock]
        )
        let session = ScannerSession()
        try await session.open(scanner)
        try await session.apply(ScanSettings(sides: .front, color: .color, dpi: 300))
        await #expect(throws: ScannerError.feederEmpty) {
            for try await _ in session.pages() {}
        }
        await session.close()
        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
    }

    @Test func unclearedJamStopsBeforeTheScanStarts() async throws {
        // As captured: a jam not yet cleared is still reported by the next session's STAT.
        let scanner = ScriptedScanner(
            ScriptedScanner.opening()
                + [ScriptedScanner.mode("Y")]
                + ScriptedScanner.command("STAT", data: Array("#ERRADF PJ  ".utf8))
                + ScriptedScanner.command("FIN")
                + [ScriptedScanner.unlock]
        )
        let session = ScannerSession()
        try await session.open(scanner)
        try await session.apply(ScanSettings(sides: .duplex, color: .color, dpi: 600))
        await #expect(throws: ScannerError.jammed) {
            for try await _ in session.pages() {}
        }
        await session.close()
        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
    }

    @Test func busyGreetingMeansAnotherHostHasTheLock() async {
        // As probed: byte 2 is 81, an IPv4 address follows, and the scanner then hangs up.
        let scanner = ScriptedScanner([], greeting: [0x01, 0x04, 0x81, 0x00, 0x01, 0x01, 0x00, 0x04, 0xC0, 0xA8, 0x03, 0xC3])
        await #expect(throws: ScannerError.busy) { try await ScannerSession().open(scanner) }
        #expect(await scanner.unmatched == [])
    }

    @Test(arguments: [
        ([UInt8](), nil),
        (Array("#ERRADF PE  ".utf8), ScannerError.feederEmpty),
        (Array("#ERRADF PJ  ".utf8), ScannerError.jammed),
        (Array("#ERRADF DFED".utf8), ScannerError.doubleFeed),
    ] as [([UInt8], ScannerError?)])
    func checkReadyReportsWhatTheScannerSays(status: [UInt8], error: ScannerError?) async throws {
        let scanner = ScriptedScanner(
            ScriptedScanner.opening() + [ScriptedScanner.mode("Y")] + ScriptedScanner.command("STAT", data: status)
                + ScriptedScanner.command("FIN") + [ScriptedScanner.unlock]
        )
        let session = ScannerSession()
        try await session.open(scanner)
        if let error {
            await #expect(throws: error) { try await session.checkReady() }
        } else {
            try await session.checkReady()
        }
        await session.close()
        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
    }

    @Test func refusesAnotherProduct() async {
        let scanner = ScriptedScanner(
            [ScriptedScanner.lock, ScriptedScanner.mode("Y")]
                + ScriptedScanner.command("INFO", data: Array("#PRDh006DS-530".utf8))
                + ScriptedScanner.command("FIN")
                + [ScriptedScanner.unlock]
        )
        await #expect(throws: ScannerError.unsupportedScanner("DS-530")) {
            try await ScannerSession().open(scanner)
        }
        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
    }

    @Test(arguments: [
        ScanSettings(sides: .duplex, color: .gray, dpi: 300),
        ScanSettings(sides: .duplex, color: .color, dpi: 200),
    ])
    func rejectsSettingsTheScannerCantDo(settings: ScanSettings) async throws {
        let scanner = ScriptedScanner(ScriptedScanner.opening())
        let session = ScannerSession()
        try await session.open(scanner)
        await #expect(throws: ScannerError.self) { try await session.apply(settings) }
    }

    @Test func applyNeedsAnOpenSession() async {
        await #expect(throws: ScannerError.notOpen) {
            try await ScannerSession().apply(ScanSettings(sides: .duplex, color: .color, dpi: 300))
        }
    }

    // MARK: Side assembly

    @Test func jamPartwayThroughASideStopsTheScan() throws {
        // As captured: the side had started, then the scanner gave up pulling the sheet in.
        var assembler = SideAssembler()
        let start = try ESCI2.parseReplyBlock(ESCI2Tests.replyBlock("IMG x0000265#psti0005052d000i0006622#typIMGA"))
        #expect(try assembler.take(start, data: [0xFF, 0xD8]).isEmpty)
        let jam = try ESCI2.parseReplyBlock(ESCI2Tests.replyBlock("IMG x0000000#errADF PJ  #typIMGA"))
        #expect(throws: ScannerError.jammed) { try assembler.take(jam, data: []) }
    }

    @Test func unknownTokenInAnImageReplyStopsTheScan() throws {
        var assembler = SideAssembler()
        let reply = try ESCI2.parseReplyBlock(ESCI2Tests.replyBlock("IMG x0000000#typIMGA#xyzADF "))
        #expect(throws: ScannerError.self) { try assembler.take(reply, data: []) }
    }

    @Test func aReplyWithoutTokensIsAnEmptyPoll() throws {
        var assembler = SideAssembler()
        #expect(try assembler.take(try ESCI2.parseReplyBlock(ESCI2Tests.replyBlock("IMG x0000000")), data: []).isEmpty)
        #expect(!assembler.isFinished)
    }

    @Test func dataWithoutASideIsRejected() throws {
        var assembler = SideAssembler()
        #expect(throws: ScannerError.self) {
            try assembler.take(try ESCI2.parseReplyBlock(ESCI2Tests.replyBlock("IMG x0000004")), data: [1, 2, 3, 4])
        }
    }

    @Test func dataBeforeAStartIsRejected() throws {
        var assembler = SideAssembler()
        let reply = try ESCI2.parseReplyBlock(ESCI2Tests.replyBlock("IMG x0000004#typIMGB"))
        #expect(throws: ScannerError.self) { try assembler.take(reply, data: [1, 2, 3, 4]) }
    }

    @Test func oneSidedScanEndsWithTheFrontsLast() throws {
        var assembler = SideAssembler()
        let start = try ESCI2.parseReplyBlock(ESCI2Tests.replyBlock("IMG x0000002#typIMGA#psti0002530d000i0003311"))
        let end = try ESCI2.parseReplyBlock(ESCI2Tests.replyBlock("IMG x0000001#typIMGA#peni0002530i0003311#lftd000"))
        #expect(try assembler.take(start, data: [0xFF, 0xD8]).isEmpty)
        let sides = try assembler.take(end, data: [0xD9])
        #expect(sides.map(\.0) == [.front])
        #expect(sides.map(\.1) == [[0xFF, 0xD8, 0xD9]])
        #expect(assembler.isFinished)
    }

    @Test func notAJPEGIsAnError() {
        #expect(throws: ScannerError.undecodableImage(.back)) { try ScannerSession.decode([0xFF, 0xD8, 0x00], side: .back) }
    }

    static func jpeg(width: Int, height: Int) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return [UInt8](data as Data)
    }
}
