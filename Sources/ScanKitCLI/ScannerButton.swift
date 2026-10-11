import Darwin
import Foundation
import ScanKit
import SystemConfiguration

/// Answers the scanner when its start button is pressed ("Scanning from the scanner's button"):
/// the SLP question on UDP 2968, then its PushScan requests on TCP 2968. Port 2968 can have one
/// owner, so Epson's Event Manager has to be stopped while this runs.
final class ScannerButton: @unchecked Sendable {
    enum Event: Sendable {
        /// The scanner asked for a computer; this one answered.
        case asked
        /// A PushScan request, already answered `OK`.
        case request(PushScan.Request.Kind)
    }

    let events: AsyncStream<Event>
    private let emit: AsyncStream<Event>.Continuation
    private let scanner: String
    private let address: String
    private let clientName: String
    private var udp: Int32 = -1
    private var tcp: Int32 = -1
    /// When the last question was answered. The scanner asks three times per press; Epson's agent
    /// effectively answered once, so this does too.
    private var answered = Date.distantPast

    /// `address` is this computer's address on the way to `scanner`: where the scan will come from.
    init(scanner: String, clientName: String) throws {
        guard let address = Self.localAddress(toward: scanner) else { throw CLIError("can't tell which address reaches the scanner at \(scanner)") }
        self.scanner = scanner
        self.address = address
        self.clientName = clientName
        (events, emit) = AsyncStream.makeStream(of: Event.self)
        udp = try Self.multicastSocket(joining: PushScan.group, on: address)
        tcp = try Self.listeningSocket()
        Thread.detachNewThread { [self] in answerQuestions() }
        Thread.detachNewThread { [self] in serveRequests() }
    }

    var advertisedAddress: String { address }

    /// The computer's local network name, as set in Sharing settings, cut to 15 characters, as
    /// Epson's agent sends it.
    static var localName: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "FastScan"
        return String(name.prefix(15))
    }

    func stop() {
        emit.finish()
        close(udp)
        close(tcp)
    }

    private func answerQuestions() {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { return }
            guard Self.string(from.sin_addr) == scanner, let question = PushScan.question(Array(buffer[..<count])) else { continue }
            guard Date.now.timeIntervalSince(answered) > 3 else { continue }
            answered = .now
            // Epson's agent answers from an ephemeral port to the scanner's 2968.
            Self.send(PushScan.answer(question, clientName: clientName, address: address), to: scanner, port: PushScan.port)
            emit.yield(.asked)
        }
    }

    private func serveRequests() {
        while true {
            let connection = accept(tcp, nil, nil)
            guard connection >= 0 else { return }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var received: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            var request: PushScan.Request?
            while request == nil {
                let count = read(connection, &buffer, buffer.count)
                guard count > 0 else { break }
                received += buffer[..<count]
                request = PushScan.request(received)
            }
            if let request {
                let response = PushScan.response(to: request)
                _ = response.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                emit.yield(.request(request.kind))
            }
            close(connection)
        }
    }

    // MARK: Sockets

    private static func multicastSocket(joining group: String, on address: String) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw CLIError("can't open a UDP socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        try bind(fd, port: PushScan.port, what: "UDP")
        var membership = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(group)), imr_interface: in_addr(s_addr: inet_addr(address)))
        guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
            close(fd)
            throw CLIError("can't join the scanner's multicast group \(group): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    private static func listeningSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw CLIError("can't open a TCP socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        try bind(fd, port: PushScan.port, what: "TCP")
        guard listen(fd, 4) == 0 else { throw CLIError("can't listen on TCP \(PushScan.port)") }
        return fd
    }

    private static func bind(_ fd: Int32, port: UInt16, what: String) throws {
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: port.bigEndian, sin_addr: in_addr(s_addr: INADDR_ANY), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw CLIError("can't use \(what) port \(port) (\(reason)); quit Epson Event Manager, which uses it too")
        }
    }

    /// The local address the system would use to reach `host`, found by connecting a UDP socket,
    /// which sends nothing.
    static func localAddress(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                 sin_port: PushScan.port.bigEndian, sin_addr: in_addr(s_addr: inet_addr(host)), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return named == 0 ? string(local.sin_addr) : nil
    }

    private static func send(_ bytes: [UInt8], to host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var remote = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                 sin_port: port.bigEndian, sin_addr: in_addr(s_addr: inet_addr(host)), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        _ = withUnsafePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    private static func string(_ address: in_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return buffer.withUnsafeMutableBufferPointer { String(cString: inet_ntop(AF_INET, &address, $0.baseAddress, socklen_t($0.count))!) }
    }
}
