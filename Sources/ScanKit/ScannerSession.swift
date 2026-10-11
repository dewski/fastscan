import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

public enum PageSide: String, Sendable {
    case front, back
}

public struct RawPage: Sendable {
    public var index: Int
    public var side: PageSide
    public var image: CGImage
    public var dpi: Int

    public init(index: Int, side: PageSide, image: CGImage, dpi: Int) {
        self.index = index
        self.side = side
        self.image = image
        self.dpi = dpi
    }
}

/// One locked session with an FF-680W, over the protocol in docs/esci2-protocol.md. Open one
/// session at a time: the scanner serves the host holding its lock.
public actor ScannerSession {
    private var connection: ScannerConnection?
    private var locked = false
    private var modeOpen = false
    /// False once a reply went wrong, since the connection may then be partway through a packet;
    /// closing then skips `FIN` and the unlock and just drops it.
    private var healthy = true
    private var info: [ESCI2.Token] = []
    private var exi: [UInt8] = []
    private var scan: (settings: ScanSettings, length: Int)?
    /// Set from any thread by `cancel()`; the `IMG` loop sees it between polls.
    private nonisolated let cancelRequested = Mutex(false)

    public init() {}

    public func open(_ endpoint: ScannerEndpoint) async throws {
        try await open(NetworkTransport(host: endpoint.ipv4, port: endpoint.port))
    }

    /// Greeting, lock, then `FS Y` to read `INFO` (to confirm the product) and `EXI` (for the
    /// page height), then `FIN` ("FastScan's needs").
    func open(_ transport: any ScannerTransport) async throws {
        let connection = ScannerConnection(transport: transport)
        self.connection = connection
        healthy = true
        do {
            try await connection.awaitGreeting()
            try await connection.lock()
            locked = true
            try await enter("Y")
            info = try ESCI2.parseTokens(try await connection.command("INFO").data[...])
            let product = info.first { $0.name == "PRD" }?.byteStrings.first.map(ESCI2.ascii) ?? "an unknown scanner"
            guard product == "FF-680W" else { throw ScannerError.unsupportedScanner(product) }
            exi = try await connection.command("EXI").data
            try await finishMode()
        } catch {
            await fail(error)
            await close()
            throw error
        }
    }

    /// `FIN` if a mode is open, then the unlock. The connection closes either way.
    public func close() async {
        guard let connection else { return }
        if healthy {
            if modeOpen { _ = try? await connection.command("FIN") }
            if locked { try? await connection.unlock() }
        }
        self.connection = nil
        locked = false
        modeOpen = false
        scan = nil
    }

    /// Only color is supported, at a resolution `EXI` gives a page length for (300 or 600 dpi on
    /// the FF-680W). Nothing is sent until `pages()`.
    public func apply(_ settings: ScanSettings) throws {
        guard connection != nil, !exi.isEmpty else { throw ScannerError.notOpen }
        guard settings.color == .color else { throw ScannerError.unsupportedSettings("FastScan scans in color only") }
        guard let length = try ESCI2.normalSpeedLength(exi: exi, dpi: settings.dpi) else {
            throw ScannerError.unsupportedSettings("there's no page length for \(settings.dpi) dpi")
        }
        scan = (settings, length)
    }

    /// Stops the scan after the `IMG` reply in flight: `pages()` then ends with
    /// `ScannerError.cancelled`. Sides already delivered stay delivered; the side in progress, and
    /// sheets the scanner fed but hadn't sent, are lost, and the sheet being fed stops partway
    /// ("Cancelling").
    public nonisolated func cancel() {
        cancelRequested.withLock { $0 = true }
    }

    /// Feeds pages until the feeder is empty. An empty feeder at the start is
    /// `ScannerError.feederEmpty`. Ending the stream early cancels the scan.
    public nonisolated func pages() -> AsyncThrowingStream<RawPage, any Error> {
        AsyncThrowingStream { continuation in
            Task { await self.feed(into: continuation) }
            continuation.onTermination = { termination in
                if case .cancelled = termination { self.cancel() }
            }
        }
    }

    /// Checks that the scanner could start a scan, as ScanSmart does before each one: `FS Y`,
    /// `STAT`, `FIN`. Throws `ScannerError.feederEmpty` with no paper loaded, and `jammed` or
    /// `doubleFeed` for one that hasn't been cleared yet.
    public func checkReady() async throws {
        guard let connection else { throw ScannerError.notOpen }
        do {
            try await enter("Y")
            try Self.checkStatus(try await connection.command("STAT").data)
            try await finishMode()
        } catch {
            await fail(error)
            throw error
        }
    }

    /// The scanner's `INFO` tokens and its `EXI` page lengths, for `scankit info`.
    public func details() -> [String] {
        info.map { ESCI2.printable($0.encoded) } + (exi.isEmpty ? [] : ["EXI " + ESCI2.ascii(exi)])
    }

    /// `FS Y`, `STAT`, `FIN` to check the feeder, as ScanSmart does before a scan; then `FS X`,
    /// `STAT`, `PARA`, `TRDT`, and `IMG` until the last side's `#lft d000`, then `FIN`.
    /// A cancel sends `CAN` between polls, then `FIN`.
    private func feed(into continuation: AsyncThrowingStream<RawPage, any Error>.Continuation) async {
        do {
            guard let connection, let scan else { throw ScannerError.notOpen }
            try await checkReady()
            try await enter("X")
            try Self.checkStatus(try await connection.command("STAT").data)

            let parameters = ESCI2.scanParameters(sides: scan.settings.sides, dpi: scan.settings.dpi, length: scan.length)
            let para = try await connection.command("PARA", parameters: parameters).reply
            guard para.token("par")?.words == ["OK  "] else {
                throw ScannerError.unexpectedReply("PARA answered \(ESCI2.printable(ESCI2.encode(para.tokens)))")
            }
            _ = try await connection.command("TRDT")

            // The first side can take seconds to start (about 8 at 600 dpi), with every reply
            // empty until then, so empty replies are polled through without a limit.
            var assembler = SideAssembler()
            var index = 0
            while !assembler.isFinished {
                if cancelRequested.withLock({ $0 }) {
                    _ = try await connection.command("CAN")
                    try await finishMode()
                    throw ScannerError.cancelled
                }
                let (reply, data) = try await connection.command("IMG")
                // The scanner's Stop button asks the host to cancel. The data this reply announced
                // has been fetched, keeping the connection in step; it belongs to the lost side.
                if let attention = reply.token("atn") {
                    guard attention.words == ["CAN "] else {
                        throw ScannerError.unexpectedReply("#atn\(attention.words.joined()) in IMG reply")
                    }
                    _ = try await connection.command("CAN")
                    try await finishMode()
                    throw ScannerError.stoppedAtScanner
                }
                for (side, jpeg) in try assembler.take(reply, data: data) {
                    continuation.yield(RawPage(index: index, side: side, image: try Self.decode(jpeg, side: side), dpi: scan.settings.dpi))
                    index += 1
                }
            }
            try await finishMode()
            continuation.finish()
        } catch {
            await fail(error)
            continuation.finish(throwing: error)
        }
    }

    private func enter(_ mode: Character) async throws {
        guard let connection else { throw ScannerError.notOpen }
        try await connection.mode(mode)
        modeOpen = true
    }

    private func finishMode() async throws {
        guard let connection else { throw ScannerError.notOpen }
        _ = try await connection.command("FIN")
        modeOpen = false
    }

    /// Errors the scanner reported in a complete reply leave the connection usable; anything else
    /// may have left it partway through a packet.
    private func fail(_ error: any Error) async {
        switch error as? ScannerError {
        case .feederEmpty, .jammed, .doubleFeed, .scannerReported, .unsupportedScanner, .cancelled, .stoppedAtScanner: break
        default: healthy = false
        }
    }

    /// A `STAT` data block: `#ERRADF PE  ` is an empty feeder; `PJ` and `DFED` are a jam or a
    /// double feed that hasn't been cleared yet.
    static func checkStatus(_ data: [UInt8]) throws {
        let codes = ESCI2.errorCodes(inStatus: try ESCI2.parseTokens(data[...])).filter { $0 != "NONE" }
        if codes.contains("PE") { throw ScannerError.feederEmpty }
        if let code = codes.first { throw ScannerError.reported(code) }
    }

    static func decode(_ jpeg: [UInt8], side: PageSide) throws -> CGImage {
        let options = [kCGImageSourceTypeIdentifierHint: UTType.jpeg.identifier] as CFDictionary
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, options),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ScannerError.undecodableImage(side) }
        return image
    }
}

/// Joins `IMG` data into one JPEG per side ("Image transfer"). A side starts with the reply
/// carrying `#pst` and ends with the one carrying `#pen`; `#lft d000` ends the scan. Replies
/// outside a side carry no tokens at all. `#err` stops the scan, even though its reply also
/// carries a `#pst` and a few bytes for a side that never comes ("Errors during a scan").
struct SideAssembler {
    private var inProgress: [PageSide: [UInt8]] = [:]
    private(set) var isFinished = false

    /// The sides this reply completes, with their JPEG bytes.
    mutating func take(_ reply: ESCI2.ReplyBlock, data: [UInt8]) throws -> [(PageSide, [UInt8])] {
        func unexpected(_ why: String) -> ScannerError {
            .unexpectedReply("\(why) in IMG reply \(ESCI2.printable(ESCI2.encode(reply.tokens)))")
        }
        if let error = reply.token("err") {
            let code = error.words.dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
            throw ScannerError.reported(code)
        }
        // Tokens nobody has seen in an IMG reply may mean another error, which hasn't been
        // captured, so they stop the scan rather than being skipped.
        if let unknown = reply.tokens.first(where: { !["typ", "pst", "pen", "lft"].contains($0.name) }) {
            throw unexpected("#\(unknown.name)")
        }
        guard !isFinished else { throw unexpected("reply after the last side") }
        if reply.tokens.isEmpty, data.isEmpty { return [] }
        let side: PageSide
        switch reply.token("typ")?.words {
        case ["IMGA"]?: side = .front
        case ["IMGB"]?: side = .back
        default: throw unexpected("no side")
        }

        if reply.token("pst") != nil {
            guard inProgress[side] == nil else { throw unexpected("a second #pst") }
            inProgress[side] = []
        }
        if !data.isEmpty {
            guard inProgress[side] != nil else { throw unexpected("data before #pst") }
            inProgress[side]! += data
        }
        var finished: [(PageSide, [UInt8])] = []
        if reply.token("pen") != nil {
            guard let jpeg = inProgress.removeValue(forKey: side) else { throw unexpected("#pen before #pst") }
            finished.append((side, jpeg))
        }
        if let left = reply.token("lft") {
            guard left.numbers == [0] else { throw unexpected("sheets left") }
            guard inProgress.isEmpty else { throw unexpected("a side still open at the end") }
            isFinished = true
        }
        return finished
    }
}
