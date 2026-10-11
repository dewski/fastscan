import Foundation

/// Encoding and parsing for the FF-680W's network protocol. Everything here follows
/// docs/esci2-protocol.md and nothing else; section names in comments refer to that document.
enum ESCI2 {
    static let port: UInt16 = 1865

    // MARK: Packets

    enum PacketType: UInt16, Sendable {
        case greeting = 0x8000
        case lock = 0x2100
        case lockReply = 0xA100
        case unlock = 0x2101
        case unlockReply = 0xA101
        case request = 0x2000
        case reply = 0xA000
        /// A job request, after the scanner's start button ("Job sessions").
        case job = 0x2300
        case jobReply = 0xA300
    }

    static let headerLength = 12
    /// The lock payload ScanSmart sends. Its fields' meanings are unknown; the last two bytes are 300.
    static let lockPayload: [UInt8] = [0x01, 0xA0, 0x04, 0x00, 0x00, 0x01, 0x2C]
    /// The lock ScanSmart's short job sessions send, ending in 30 instead of 300.
    static let jobLockPayload: [UInt8] = [0x01, 0xA0, 0x04, 0x00, 0x00, 0x00, 0x1E]
    /// ScanSmart's `JOBW`, as captured: a job named "Dummy". The other fields' meanings are unknown.
    static let jobWrite: [UInt8] = Array("JOBW".utf8) + [UInt8](repeating: 0, count: 16)
        + [0x01, 0x1A, 0x18, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00]
        + Array("Dummy".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        + [0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x02, 0x01, 0x00]
    /// ScanSmart's `JOBR`, which reads 8 bytes back.
    static let jobRead: [UInt8] = Array("JOBR".utf8)
    /// The one-byte reply to a lock or a mode byte.
    static let acknowledge: UInt8 = 0x06

    struct PacketHeader: Equatable, Sendable {
        var type: UInt16
        var payloadLength: Int
    }

    /// A host packet: `IS`, the type, `00 0C`, the payload length, `00 00`, then the payload.
    static func packet(_ type: PacketType, payload: [UInt8] = []) -> [UInt8] {
        var bytes: [UInt8] = [0x49, 0x53]
        bytes.appendBigEndian(type.rawValue)
        bytes += [0x00, UInt8(headerLength)]
        bytes.appendBigEndian(UInt32(payload.count))
        bytes += [0x00, 0x00]
        return bytes + payload
    }

    /// A `20 00` request: the data header (length of `bytes`, then the expected reply length), then `bytes`.
    /// A `23 00` job request: the same data header as a `20 00` request.
    static func jobRequest(_ bytes: [UInt8], replyLength: Int) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendBigEndian(UInt32(bytes.count))
        payload.appendBigEndian(UInt32(replyLength))
        return packet(.job, payload: payload + bytes)
    }

    static func request(_ bytes: [UInt8], replyLength: Int) -> [UInt8] {
        var payload: [UInt8] = []
        payload.appendBigEndian(UInt32(bytes.count))
        payload.appendBigEndian(UInt32(replyLength))
        return packet(.request, payload: payload + bytes)
    }

    /// Parses a header the scanner sent, which has `38` in byte 4.
    static func parseHeader(_ bytes: [UInt8]) throws -> PacketHeader {
        guard bytes.count == headerLength, bytes[0] == 0x49, bytes[1] == 0x53, bytes[4] == 0x38, bytes[5] == UInt8(headerLength)
        else { throw ScannerError.malformed("packet header \(hex(bytes))") }
        return PacketHeader(type: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                            payloadLength: Int(bytes[6]) << 24 | Int(bytes[7]) << 16 | Int(bytes[8]) << 8 | Int(bytes[9]))
    }

    /// `FS` and a mode letter: `Y` for capabilities, `X` before a scan.
    static func modeBytes(_ letter: Character) -> [UInt8] { [0x1C, letter.asciiValue!] }

    // MARK: Commands

    static let replyBlockLength = 64

    /// The 12-byte request block: the command padded to four characters, `x`, and the parameter
    /// block's length in seven uppercase hex digits.
    static func commandBlock(_ command: String, parameterLength: Int = 0) -> [UInt8] {
        Array((padded(command) + "x" + hexDigits(parameterLength, count: 7)).utf8)
    }

    /// A 64-byte reply block: the command, `x`, the length of the data block the scanner is holding,
    /// then tokens. The `#---` padding is dropped.
    struct ReplyBlock: Equatable, Sendable {
        var command: String
        var dataLength: Int
        var tokens: [Token]

        func token(_ name: String) -> Token? { tokens.first { $0.name == name } }
    }

    static func parseReplyBlock(_ bytes: [UInt8]) throws -> ReplyBlock {
        guard bytes.count >= 12, bytes[4] == UInt8(ascii: "x"),
              let length = unsigned(bytes[5..<12], radix: 16)
        else { throw ScannerError.malformed("reply block \(printable(bytes))") }
        let tokens = try parseTokens(bytes[12...], stopAtNull: true).filter { $0.name != "---" }
        return ReplyBlock(command: ascii(bytes[0..<4]), dataLength: length, tokens: tokens)
    }

    // MARK: Tokens

    /// One field of a token's value ("Tokens").
    enum Field: Equatable, Sendable {
        /// `d` and three digits.
        case short(Int)
        /// `i` and seven digits.
        case long(Int)
        /// `x` and seven hex digits.
        case hex(Int)
        /// `h`, three hex digits of length, then the raw bytes, then zero bytes up to a multiple
        /// of four.
        case bytes([UInt8])
        /// Four characters, space padded.
        case word(String)

        var number: Int? {
            switch self {
            case .short(let value), .long(let value), .hex(let value): value
            default: nil
            }
        }

        var encoded: [UInt8] {
            switch self {
            case .short(let value): Array(("d" + decimalDigits(value, count: 3)).utf8)
            case .long(let value): Array(("i" + decimalDigits(value, count: 7)).utf8)
            case .hex(let value): Array(("x" + hexDigits(value, count: 7)).utf8)
            case .bytes(let bytes):
                Array(("h" + hexDigits(bytes.count, count: 3)).utf8) + bytes + [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4)
            case .word(let word): Array(padded(word).utf8)
            }
        }
    }

    /// `#`, a three-character name, then fields.
    struct Token: Equatable, Sendable {
        var name: String
        var fields: [Field]

        init(_ name: String, _ fields: [Field] = []) {
            self.name = name
            self.fields = fields
        }

        var encoded: [UInt8] { Array(("#" + name).utf8) + fields.flatMap(\.encoded) }
        var words: [String] { fields.compactMap { if case .word(let word) = $0 { word } else { nil } } }
        var numbers: [Int] { fields.compactMap(\.number) }
        var byteStrings: [[UInt8]] { fields.compactMap { if case .bytes(let bytes) = $0 { bytes } else { nil } } }
    }

    static func encode(_ tokens: [Token]) -> [UInt8] { tokens.flatMap(\.encoded) }

    /// Reads tokens until the end of `bytes`, or a `00` byte when `stopAtNull` (reply blocks only).
    /// Byte strings are read by their length, so a `#` inside one doesn't end the token.
    static func parseTokens(_ bytes: ArraySlice<UInt8>, stopAtNull: Bool = false) throws -> [Token] {
        let end = bytes.endIndex
        var index = bytes.startIndex
        var tokens: [Token] = []

        func atBoundary(_ index: Int) -> Bool {
            index >= end || bytes[index] == UInt8(ascii: "#") || (stopAtNull && bytes[index] == 0)
        }
        // Lengths and hex fields are digits only; decimal values may carry a sign, as in `i-000020`.
        func digits(_ range: Range<Int>, radix: Int, signed: Bool = false) -> Int? {
            guard range.upperBound <= end else { return nil }
            return signed ? Int(ascii(bytes[range]), radix: radix) : unsigned(bytes[range], radix: radix)
        }

        while index < end, !(stopAtNull && bytes[index] == 0) {
            guard bytes[index] == UInt8(ascii: "#"), index + 4 <= end else {
                throw ScannerError.malformed("token at \(index - bytes.startIndex) in \(printable(Array(bytes)))")
            }
            var token = Token(ascii(bytes[index + 1..<index + 4]))
            index += 4
            while !atBoundary(index) {
                switch bytes[index] {
                case UInt8(ascii: "h"):
                    if let length = digits(index + 1..<index + 4, radix: 16), index + 4 + length <= end {
                        token.fields.append(.bytes(Array(bytes[index + 4..<index + 4 + length])))
                        index += 4 + length
                        // Zero padding up to a multiple of four.
                        var padding = (4 - length % 4) % 4
                        while padding > 0, index < end, bytes[index] == 0 {
                            index += 1
                            padding -= 1
                        }
                        continue
                    }
                case UInt8(ascii: "d"):
                    if let value = digits(index + 1..<index + 4, radix: 10, signed: true) {
                        token.fields.append(.short(value))
                        index += 4
                        continue
                    }
                case UInt8(ascii: "i"):
                    if let value = digits(index + 1..<index + 8, radix: 10, signed: true) {
                        token.fields.append(.long(value))
                        index += 8
                        continue
                    }
                case UInt8(ascii: "x"):
                    if let value = digits(index + 1..<index + 8, radix: 16) {
                        token.fields.append(.hex(value))
                        index += 8
                        continue
                    }
                default:
                    break
                }
                var wordEnd = index + 1
                while wordEnd < index + 4, !atBoundary(wordEnd) { wordEnd += 1 }
                token.fields.append(.word(ascii(bytes[index..<wordEnd])))
                index = wordEnd
            }
            tokens.append(token)
        }
        return tokens
    }

    /// A number written only in digits of `radix`, with no sign.
    static func unsigned(_ bytes: some Collection<UInt8>, radix: Int) -> Int? {
        guard !bytes.isEmpty, bytes.allSatisfy({ Character(UnicodeScalar($0)).hexDigitValue.map { $0 < radix } ?? false }) else { return nil }
        return Int(ascii(bytes), radix: radix)
    }

    // MARK: Status

    /// The `#ERR` codes in a `STAT` data block, such as `PE` for an empty feeder. The first word
    /// names the part (`ADF`); the codes follow it.
    static func errorCodes(inStatus tokens: [Token]) -> [String] {
        tokens.filter { $0.name == "ERR" }.flatMap { $0.words.dropFirst() }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: EXI

    /// The normal-speed page length, in 1/100 inch, that `EXI` gives for `dpi`.
    static func normalSpeedLength(exi: [UInt8], dpi: Int) throws -> Int? {
        struct Lengths: Decodable {
            struct Entry: Decodable {
                var resolution: Int
                var length: Int
                enum CodingKeys: String, CodingKey {
                    case resolution = "Resolution", length = "Length"
                }
            }
            var normalSpeedLength: [Entry]
            enum CodingKeys: String, CodingKey {
                case normalSpeedLength = "NormalSpeedLength"
            }
        }
        let lengths: Lengths
        do {
            lengths = try JSONDecoder().decode(Lengths.self, from: Data(exi))
        } catch {
            throw ScannerError.malformed("EXI \(printable(exi))")
        }
        return lengths.normalSpeedLength.first { $0.resolution == dpi }?.length
    }

    // MARK: Scan parameters

    /// 8.5 inches, the feeder's full width ("The scan area").
    static let paperWidth = 850
    /// The exact identity ramp, `00` to `FF`.
    static let identityGamma = (0...255).map(UInt8.init)
    /// The identity matrix, with `20` meaning 1.0.
    static let identityColorMatrix: [UInt8] = [0x20, 0, 0, 0, 0x20, 0, 0, 0, 0x20]

    /// The `PARA` block for a color scan, in ScanSmart's order ("Scan parameters"), with identity
    /// gamma tables and color matrix. `length` is the page height in 1/100 inch, from `EXI`.
    static func scanParameters(sides: Sides, dpi: Int, length: Int) -> [Token] {
        let feeder = ["CRP ", "SKEW"] + (sides == .duplex ? ["DPLX"] : []) + ["DFL1"]
        return [
            Token("ADF", feeder.map(Field.word)),
            Token("RSM", [.long(dpi)]),
            Token("RSS", [.long(dpi)]),
            Token("COL", [.word("C024")]),
            Token("FMT", [.word("JPG ")]),
            Token("JPG", [.short(90)]),
            Token("GMM", [.word("UG18")]),
            Token("GMT", [.word("RED "), .bytes(identityGamma)]),
            Token("GMT", [.word("BLU "), .bytes(identityGamma)]),
            Token("GMT", [.word("GRN "), .bytes(identityGamma)]),
            Token("CMX", [.word("UM08"), .bytes(identityColorMatrix)]),
            Token("CRP", [.long(0)]),
            Token("DFA", [.long(0), .long(1550)]),
            Token("LAM", [.word("OFF ")]),
            Token("PAG", [.short(0)]),
            Token("ACQ", [.long(0), .long(0), .long(paperWidth * dpi / 100), .long(length * dpi / 100)]),
            Token("BSZ", [.long(1_048_576)]),
        ]
    }

    // MARK: Text helpers

    static func padded(_ text: String) -> String {
        text.count >= 4 ? text : text + String(repeating: " ", count: 4 - text.count)
    }

    static func hexDigits(_ value: Int, count: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, count - digits.count)) + digits
    }

    /// Zero-padded to `count` characters, with a leading `-` taking one of them, as in `i-000020`.
    static func decimalDigits(_ value: Int, count: Int) -> String {
        let digits = String(value.magnitude)
        let width = value < 0 ? count - 1 : count
        return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    static func ascii(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func hex(_ bytes: some Collection<UInt8>) -> String {
        bytes.map { hexDigits(Int($0), count: 2) }.joined(separator: " ")
    }

    /// Printable ASCII as is, anything else as `.`, for error messages.
    static func printable(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes.prefix(128).map { (0x20..<0x7F).contains($0) ? $0 : UInt8(ascii: ".") }, as: UTF8.self)
    }
}

extension [UInt8] {
    mutating func appendBigEndian(_ value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
