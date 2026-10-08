import Foundation
import Network
import dnssd
import Synchronization

public struct ScannerEndpoint: Equatable, Hashable, Codable, Sendable {
    public var name: String
    public var host: String
    public var ipv4: String
    public var port: UInt16

    public init(name: String, host: String, ipv4: String, port: UInt16) {
        self.name = name
        self.host = host
        self.ipv4 = ipv4
        self.port = port
    }
}

/// Finds Epson scanners advertising `_scanner._tcp` over Bonjour. SANE's own epsonds autodiscovery
/// does not find the FF-680W, so the app resolves the address itself and hands SANE an explicit IP.
public enum ScannerDiscovery {
    public static let serviceType = "_scanner._tcp"

    public enum Failure: LocalizedError, Equatable {
        case localNetworkDenied
        case browser(String)

        public var errorDescription: String? {
            switch self {
            case .localNetworkDenied:
                "FastScan isn't allowed to use the local network. Turn it on in System Settings > Privacy & Security > Local Network."
            case .browser(let message):
                "Scanner discovery failed: \(message)"
            }
        }
    }

    public static func endpoints() -> AsyncThrowingStream<ScannerEndpoint, any Error> {
        AsyncThrowingStream { continuation in
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            let seen = Mutex<Set<String>>([])
            browser.browseResultsChangedHandler = { _, changes in
                for case .added(let result) in changes {
                    guard case let .service(name, type, domain, _) = result.endpoint,
                          name.localizedCaseInsensitiveContains("EPSON"),
                          seen.withLock({ $0.insert(name).inserted })
                    else { continue }
                    Task {
                        if let endpoint = await resolve(name: name, type: type, domain: domain) {
                            continuation.yield(endpoint)
                        }
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(.dns(let code)) where code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied):
                    continuation.finish(throwing: Failure.localNetworkDenied)
                case .failed(let error):
                    continuation.finish(throwing: Failure.browser(error.localizedDescription))
                default:
                    break
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "FastScan.discovery"))
        }
    }

    /// Collects endpoints until `timeout` elapses, or until the first one when `firstOnly` is set.
    public static func discover(timeout: Duration, firstOnly: Bool = false) async throws -> [ScannerEndpoint] {
        let collector = Task {
            var found: [ScannerEndpoint] = []
            for try await endpoint in endpoints() {
                found.append(endpoint)
                if firstOnly { break }
            }
            return found
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            collector.cancel()
        }
        defer { timer.cancel() }
        return try await collector.value
    }

    private static func resolve(name: String, type: String, domain: String) async -> ScannerEndpoint? {
        guard let (host, port) = await resolveService(name: name, type: type, domain: domain),
              let ipv4 = await ipv4Address(of: host)
        else { return nil }
        return ScannerEndpoint(name: name, host: host, ipv4: ipv4, port: port)
    }

    /// DNS-SD resolve gives the host name and port without opening a connection to the scanner,
    /// which an NWConnection-based resolve would do.
    private static func resolveService(name: String, type: String, domain: String) async -> (String, UInt16)? {
        final class Box: @unchecked Sendable {
            let continuation: CheckedContinuation<(String, UInt16)?, Never>
            var ref: DNSServiceRef?
            var done = false
            init(_ continuation: CheckedContinuation<(String, UInt16)?, Never>) { self.continuation = continuation }

            // Only ever called on `queue`, so `done` and `ref` need no lock.
            func finish(_ result: (String, UInt16)?) {
                guard !done else { return }
                done = true
                if let ref { DNSServiceRefDeallocate(ref) }
                continuation.resume(returning: result)
                Unmanaged.passUnretained(self).release()
            }
        }

        let queue = DispatchQueue(label: "FastScan.resolve")
        return await withCheckedContinuation { continuation in
            queue.async {
                let box = Box(continuation)
                let context = Unmanaged.passRetained(box).toOpaque()
                let error = DNSServiceResolve(&box.ref, 0, 0, name, type, domain, { _, _, _, error, _, host, port, _, _, context in
                    let box = Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue()
                    guard error == kDNSServiceErr_NoError, let host else { return box.finish(nil) }
                    box.finish((String(cString: host), UInt16(bigEndian: port)))
                }, context)
                guard error == kDNSServiceErr_NoError, let ref = box.ref else {
                    box.ref = nil
                    return box.finish(nil)
                }
                DNSServiceSetDispatchQueue(ref, queue)
                queue.asyncAfter(deadline: .now() + 5) { box.finish(nil) }
            }
        }
    }

    private static func ipv4Address(of host: String) async -> String? {
        await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &info) == 0, let info else { return nil }
            defer { freeaddrinfo(info) }
            var address = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return buffer.withUnsafeMutableBufferPointer { buffer in
                inet_ntop(AF_INET, &address, buffer.baseAddress, socklen_t(buffer.count)).map { String(cString: $0) }
            }
        }.value
    }
}
