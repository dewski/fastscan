import Foundation
import Testing
@testable import ScanKit

/// Messages from the "Scan button" capture in docs/esci2-protocol.md, with the computer's name and
/// the scanner's MAC address replaced.
@Suite struct PushScanTests {
    static let question: [UInt8] = [0x02, 0x06, 0x00, 0x00, 0x66, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x65, 0x6E, 0x00, 0x00]
        + PushScan.lengthPrefixed("service:NetScanMonitor-agent") + PushScan.lengthPrefixed("PID 016B")
        + PushScan.lengthPrefixed("Ver,ClientName,IPAddress,EventPort,Group") + [0x00, 0x00]

    @Test func readsTheScannersQuestion() throws {
        #expect(Self.question.count == 102)
        let question = try #require(PushScan.question(Self.question))
        #expect(question == PushScan.Question(xid: 1, language: "en", scope: "PID 016B",
                                              tags: ["Ver", "ClientName", "IPAddress", "EventPort", "Group"]))
    }

    @Test func ignoresOtherSLPMessages() {
        var otherService = Self.question
        otherService[otherService.firstIndex(of: UInt8(ascii: "N"))!] = UInt8(ascii: "X")
        #expect(PushScan.question(otherService) == nil)
        var reply = Self.question
        reply[1] = 7
        #expect(PushScan.question(reply) == nil)
        #expect(PushScan.question(Array(Self.question.dropLast())) == nil)
        #expect(PushScan.question([]) == nil)
    }

    @Test func answersLikeEpsonsAgent() throws {
        let question = try #require(PushScan.question(Self.question))
        // A 15-character name and this address, as in the capture, give its length, 112.
        let answer = PushScan.answer(question, clientName: "Example-Mac-123", address: "192.168.3.195")
        #expect(answer.count == 112)
        #expect(Array(answer.prefix(16)) == [0x02, 0x07, 0x00, 0x00, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x02, 0x65, 0x6E])
        #expect(Array(answer[16..<20]) == [0x00, 0x00, 0x00, 0x5B])
        #expect(String(decoding: answer[20..<111], as: UTF8.self)
            == "(Ver=3.0),(ClientName=Example-Mac-123),(IPAddress=192.168.3.195),(EventPort=2968),(Group=0)")
        #expect(answer.last == 0)
    }

    static func post(uid: Int, _ element: String) -> [UInt8] {
        let body = """
            <?xml version="1.0" ?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>\
            <p:\(element.split(separator: ">").first!) xmlns:p="http://schema.epson.net/EpsonNet/Scan/2004/pushscan">\
            <ProductNameIn>PID 016B</ProductNameIn><IPAddressIn>C0A8007F</IPAddressIn><MACAddressIn>000000000000</MACAddressIn>\
            \(element.split(separator: ">", maxSplits: 1).dropFirst().first.map(String.init) ?? "")\
            </p:\(element.split(separator: ">").first!)></s:Body></s:Envelope>
            """
        let head = "POST /PushScan HTTP/1.0\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.utf8.count)\r\n"
            + "x-protocol-name: Epson Network Service Protocol\r\nx-protocol-version: 3.00\r\nx-uid: \(uid)\r\n\r\n"
        return Array(head.utf8) + Array(body.utf8)
    }

    @Test func readsTheThreeRequests() {
        #expect(PushScan.request(Self.post(uid: 2, "JobList><CapabilityIn>OfficeFormat</CapabilityIn><CapabilityIn>PanelData=0110</CapabilityIn>"))
            == PushScan.Request(kind: .jobList(capabilities: ["OfficeFormat", "PanelData=0110"]), uid: "2"))
        #expect(PushScan.request(Self.post(uid: 3, "PushScan><JobNumberIn>0</JobNumberIn>"))
            == PushScan.Request(kind: .pushScan(job: 0), uid: "3"))
        #expect(PushScan.request(Self.post(uid: 4, "ScanEnd")) == PushScan.Request(kind: .scanEnd, uid: "4"))
    }

    @Test func waitsForTheWholeRequest() {
        let whole = Self.post(uid: 3, "PushScan><JobNumberIn>0</JobNumberIn>")
        #expect(PushScan.request(Array(whole.prefix(40))) == nil)
        #expect(PushScan.request(Array(whole.dropLast(5))) == nil)
        #expect(PushScan.request(whole) != nil)
    }

    @Test func answersAJobListWithItsCapabilities() throws {
        let request = PushScan.Request(kind: .jobList(capabilities: ["OfficeFormat", "PanelData=0110"]), uid: "2")
        let text = String(decoding: PushScan.response(to: request), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.0 200 OK\r\n"))
        #expect(text.contains("x-uid : 2\r\n"))
        #expect(text.contains("x-status : 0001\r\n"))
        #expect(text.contains("<StatusOut>OK</StatusOut>"))
        #expect(text.contains("<CapabilityOut>OfficeFormat</CapabilityOut>"))
        #expect(text.contains("<CapabilityOut>PanelData=0110</CapabilityOut>"))
        let parts = text.components(separatedBy: "\r\n\r\n")
        let length = try #require(PushScan.headerFields(parts[0])["content-length"].flatMap { Int($0) })
        #expect(length == parts.dropFirst().joined(separator: "\r\n\r\n").utf8.count)
    }

    @Test func jobWriteIsTheCapturedBytes() {
        let captured = "4a4f4257" + String(repeating: "00", count: 16) + "011a18000000000a0000" + "440075006d006d007900" + "03000000020000020100"
        #expect(ESCI2.jobWrite.map { ESCI2.hexDigits(Int($0), count: 2) }.joined().lowercased() == captured)
        #expect(ESCI2.jobWrite.count == 50)
        // Header 23 00, payload 58: the data header (50 bytes, no reply) and the request.
        #expect(Array(ESCI2.jobRequest(ESCI2.jobWrite, replyLength: 0).prefix(20))
            == [0x49, 0x53, 0x23, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x3A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00, 0x00])
    }

    @Test func jobSessionsWriteThenReadTheJob() async throws {
        func session(_ request: [UInt8], replyLength: Int, reply: [UInt8]) -> ScriptedScanner {
            ScriptedScanner([
                .init(expect: ESCI2.packet(.lock, payload: ESCI2.jobLockPayload), reply: ScriptedScanner.packet(0xA100, [0x06])),
                .init(expect: ESCI2.jobRequest(request, replyLength: replyLength), reply: ScriptedScanner.packet(0xA300, reply)),
                ScriptedScanner.unlock,
            ])
        }
        let write = session(ESCI2.jobWrite, replyLength: 0, reply: [])
        let read = session(Array("JOBR".utf8), replyLength: 8, reply: [0x03, 0x00, 0x02, 0x00, 0x00, 0x02, 0x00, 0x01])
        try await ScannerSession.acceptButtonJob(write, read)
        #expect(await write.unmatched == [])
        #expect(await write.finished)
        #expect(await read.unmatched == [])
        #expect(await read.finished)
    }
}
