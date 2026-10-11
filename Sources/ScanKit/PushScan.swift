import Foundation

/// The scanner's start button ("Scanning from the scanner's button" in docs/esci2-protocol.md):
/// an SLP request on UDP 2968 asking for a computer, then PushScan HTTP requests to it on TCP 2968.
public enum PushScan {
    public static let port: UInt16 = 2968
    /// The SLP multicast group the scanner asks on.
    public static let group = "239.255.255.253"
    static let service = "service:NetScanMonitor-agent"
    static let namespace = "http://schema.epson.net/EpsonNet/Scan/2004/pushscan"

    // MARK: SLP

    /// The scanner's SLP attribute request, as far as an answer needs it.
    public struct Question: Equatable, Sendable {
        public var xid: UInt16
        public var language: String
        public var scope: String
        public var tags: [String]
    }

    /// Reads an SLP version 2 attribute request (function 6) for `service:NetScanMonitor-agent`;
    /// anything else is nil.
    public static func question(_ bytes: [UInt8]) -> Question? {
        var reader = Reader(bytes)
        guard reader.byte() == 2, reader.byte() == 6,
              let length = reader.integer(3), length == bytes.count,
              reader.integer(2) != nil, reader.integer(3) != nil,
              let xid = reader.integer(2), let language = reader.string(),
              reader.string() != nil,  // previous responders
              reader.string() == service,
              let scope = reader.string(), let tags = reader.string()
        else { return nil }
        return Question(xid: UInt16(xid), language: language, scope: scope, tags: tags.split(separator: ",").map(String.init))
    }

    /// The SLP attribute reply (function 7) naming this computer: where to send the PushScan
    /// requests. `address` must be the one the scan will come from; the scanner serves port 1865
    /// only to it while a button scan is pending.
    public static func answer(_ question: Question, clientName: String, address: String, eventPort: UInt16 = port) -> [UInt8] {
        let attributes = "(Ver=3.0),(ClientName=\(clientName)),(IPAddress=\(address)),(EventPort=\(eventPort)),(Group=0)"
        var body: [UInt8] = [0, 0]  // error code
        body += lengthPrefixed(attributes)
        body.append(0)  // no authentication blocks
        let language = lengthPrefixed(question.language)
        // Version, function, length (3), flags (2), extension offset (3) and XID (2) come first.
        let length = 12 + language.count + body.count
        var message: [UInt8] = [2, 7, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        message += [0, 0, 0, 0, 0, UInt8(question.xid >> 8), UInt8(question.xid & 0xFF)]
        return message + language + body
    }

    // MARK: HTTP

    /// One of the scanner's PushScan requests.
    public struct Request: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Asks what the computer can do, with the scanner's capabilities.
            case jobList(capabilities: [String])
            /// Asks the computer to scan.
            case pushScan(job: Int)
            /// The scan the button started is over.
            case scanEnd
            case other(String)
        }

        public var kind: Kind
        public var uid: String
    }

    /// Reads a whole HTTP request: headers, then a body of `Content-Length` bytes. Nil until it's
    /// all there, so a caller can keep reading.
    public static func request(_ bytes: [UInt8]) -> Request? {
        guard let end = headerEnd(bytes) else { return nil }
        let headers = headerFields(String(decoding: bytes[..<end], as: UTF8.self))
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard bytes.count >= end + 4 + length else { return nil }
        let body = String(decoding: bytes[(end + 4)..<(end + 4 + length)], as: UTF8.self)
        let kind: Request.Kind
        switch element(in: body) {
        case "JobList": kind = .jobList(capabilities: values("CapabilityIn", in: body))
        case "PushScan": kind = .pushScan(job: values("JobNumberIn", in: body).first.flatMap { Int($0) } ?? 0)
        case "ScanEnd": kind = .scanEnd
        case let other: kind = .other(other ?? "")
        }
        return Request(kind: kind, uid: headers["x-uid"] ?? "0")
    }

    /// The answer to a request: HTTP/1.0 `200 OK` with a `PushScanResponse`, headed like
    /// ScanSmart's, echoing the capabilities a `JobList` offered.
    public static func response(to request: Request, ok: Bool = true) -> [UInt8] {
        var elements = ["<StatusOut>\(ok ? "OK" : "ERROR")</StatusOut>"]
        if case .jobList(let capabilities) = request.kind {
            elements += capabilities.map { "<CapabilityOut>\(escape($0))</CapabilityOut>" }
        }
        let body = """
            <?xml version="1.0" ?>\r
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">\r
              <s:Body>\r
                <p:PushScanResponse xmlns:p="\(namespace)">\r
            \(elements.map { "      \($0)\r\n" }.joined())    </p:PushScanResponse>\r
              </s:Body>\r
            </s:Envelope>\r

            """
        let content = Array(body.utf8)
        let head = [
            "HTTP/1.0 200 OK",
            "Server : FastScan",
            "Content-Type : application/octet-stream",
            "Content-Length : \(content.count)",
            "x-protocol-name : Epson Network Service Protocol",
            "x-protocol-version : 3.00",
            "x-uid : \(request.uid)",
            "x-status : 0001",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        return Array(head.utf8) + content
    }

    // MARK: Helpers

    static func lengthPrefixed(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        return [UInt8(bytes.count >> 8 & 0xFF), UInt8(bytes.count & 0xFF)] + bytes
    }

    static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        return (0...(bytes.count - 4)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }
    }

    /// Header names lowercased; both `Name: value` and ScanSmart's `Name : value`.
    static func headerFields(_ head: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// The local name of the element inside `s:Body`.
    static func element(in body: String) -> String? {
        guard let bodyStart = body.range(of: "Body>") else { return nil }
        let rest = body[bodyStart.upperBound...]
        guard let open = rest.firstIndex(of: "<") else { return nil }
        let name = rest[rest.index(after: open)...].prefix { !" />".contains($0) }
        return name.split(separator: ":").last.map(String.init)
    }

    static func values(_ element: String, in body: String) -> [String] {
        body.components(separatedBy: "<\(element)>").dropFirst().compactMap { $0.components(separatedBy: "</\(element)>").first }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    struct Reader {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func byte() -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func integer(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            defer { index += count }
            return bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
        }

        mutating func string() -> String? {
            guard let length = integer(2), index + length <= bytes.count else { return nil }
            defer { index += length }
            return String(decoding: bytes[index..<index + length], as: UTF8.self)
        }
    }
}
