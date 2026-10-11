import Foundation
import Network

/// Moves bytes to and from the scanner. `NetworkTransport` is the real one; tests script their own.
protocol ScannerTransport: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func receive(exactly count: Int) async throws -> [UInt8]
}

/// One plain TCP connection to port 1865 ("Transport"). The connection opens on first use and
/// closes when the transport is released.
final class NetworkTransport: ScannerTransport {
    private let connection: NetworkConnection<TCP>

    init(host: String, port: UInt16 = ESCI2.port) {
        connection = NetworkConnection(to: .hostPort(host: .init(host), port: .init(rawValue: port)!)) {
            // Keepalive notices a scanner that went away while a reply is awaited.
            TCP().noDelay(true).connectionTimeout(10).keepalive(idleTimeInSeconds: 10, count: 3, intervalInSeconds: 5)
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        do { try await connection.send(bytes) } catch { throw ScannerError.connection(error.localizedDescription) }
    }

    func receive(exactly count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        let bytes: [UInt8]
        do { bytes = [UInt8](try await connection.receive(exactly: count).content) } catch {
            throw ScannerError.connection(error.localizedDescription)
        }
        // A short read means the scanner closed the connection.
        guard bytes.count == count else { throw ScannerError.connection("the scanner closed the connection") }
        return bytes
    }
}

/// The packet and command layers over a transport ("Packets", "Commands").
struct ScannerConnection: Sendable {
    let transport: any ScannerTransport

    func receivePacket() async throws -> (type: UInt16, payload: [UInt8]) {
        let header = try ESCI2.parseHeader(try await transport.receive(exactly: ESCI2.headerLength))
        return (header.type, try await transport.receive(exactly: header.payloadLength))
    }

    /// Sends one host packet and returns its reply's payload. Every host packet gets exactly one
    /// reply, whose type is the request's with the top bit set.
    func exchange(_ packet: [UInt8], expecting replyType: ESCI2.PacketType) async throws -> [UInt8] {
        try await transport.send(packet)
        let reply = try await receivePacket()
        guard reply.type == replyType.rawValue else {
            throw ScannerError.unexpectedReply("packet type \(ESCI2.hexDigits(Int(reply.type), count: 4)) instead of \(ESCI2.hexDigits(Int(replyType.rawValue), count: 4))")
        }
        return reply.payload
    }

    func job(_ bytes: [UInt8], replyLength: Int) async throws -> [UInt8] {
        try await exchange(ESCI2.jobRequest(bytes, replyLength: replyLength), expecting: .jobReply)
    }

    func request(_ bytes: [UInt8], replyLength: Int) async throws -> [UInt8] {
        try await exchange(ESCI2.request(bytes, replyLength: replyLength), expecting: .reply)
    }

    func awaitGreeting() async throws {
        let greeting = try await receivePacket()
        guard greeting.type == ESCI2.PacketType.greeting.rawValue else {
            throw ScannerError.unexpectedReply("packet type \(ESCI2.hexDigits(Int(greeting.type), count: 4)) instead of a greeting")
        }
        // While another host holds the lock, byte 2 is 81 instead of 00, and the scanner closes
        // the connection straight after ("Opening").
        if greeting.payload.count > 2, greeting.payload[2] == 0x81 { throw ScannerError.busy }
    }

    func lock(_ payload: [UInt8] = ESCI2.lockPayload) async throws {
        let reply = try await exchange(ESCI2.packet(.lock, payload: payload), expecting: .lockReply)
        guard reply == [ESCI2.acknowledge] else { throw ScannerError.unexpectedReply("lock answered \(ESCI2.hex(reply))") }
    }

    func unlock() async throws {
        _ = try await exchange(ESCI2.packet(.unlock), expecting: .unlockReply)
    }

    func mode(_ letter: Character) async throws {
        let reply = try await request(ESCI2.modeBytes(letter), replyLength: 1)
        guard reply == [ESCI2.acknowledge] else { throw ScannerError.unexpectedReply("FS \(letter) answered \(ESCI2.hex(reply))") }
    }

    /// Sends a command (and its parameter block, if any), then fetches the data block its reply
    /// announces.
    func command(_ name: String, parameters: [ESCI2.Token]? = nil) async throws -> (reply: ESCI2.ReplyBlock, data: [UInt8]) {
        let replyBytes: [UInt8]
        if let parameters {
            let block = ESCI2.encode(parameters)
            _ = try await request(ESCI2.commandBlock(name, parameterLength: block.count), replyLength: 0)
            replyBytes = try await request(block, replyLength: ESCI2.replyBlockLength)
        } else {
            replyBytes = try await request(ESCI2.commandBlock(name), replyLength: ESCI2.replyBlockLength)
        }
        let reply = try ESCI2.parseReplyBlock(replyBytes)
        guard reply.command == ESCI2.padded(name) else {
            throw ScannerError.unexpectedReply("\(reply.command) answering \(name)")
        }
        let data = reply.dataLength > 0 ? try await request([], replyLength: reply.dataLength) : []
        guard data.count == reply.dataLength else {
            throw ScannerError.unexpectedReply("\(data.count) bytes after \(name) announced \(reply.dataLength)")
        }
        return (reply, data)
    }
}
