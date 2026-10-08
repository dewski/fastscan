import CSANE
import CoreGraphics
import Foundation
import Synchronization

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

public struct SANEOption: Sendable {
    public var name: String
    public var title: String
    public var value: String
    public var allowed: String
    public var isActive: Bool
}

/// Owns one SANE device handle. SANE is blocking and not thread-safe, so every call runs on this
/// actor's private serial queue, off the cooperative thread pool. sane_init is process-global:
/// open at most one session at a time.
public actor SANESession {
    private let queue = DispatchSerialQueue(label: "FastScan.SANE")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// sane_cancel is the one SANE call documented as safe from another thread, so `cancel()`
    /// reaches the handle through this lock instead of waiting behind a blocked sane_read.
    private struct Live: @unchecked Sendable {
        var handle: SANE_Handle?
        var cancelled = false
    }
    private nonisolated let live = Mutex(Live())

    private var settings = ScanSettings.default

    public init() {}

    public func open(_ endpoint: ScannerEndpoint, configDirectory: URL = SANEConfig.defaultDirectory) throws {
        try SANEConfig.write(for: endpoint, in: configDirectory)
        setenv("SANE_CONFIG_DIR", configDirectory.path, 1)
        try check(sane_init(nil, nil))
        var handle: SANE_Handle?
        let status = sane_open(SANEConfig.deviceName(for: endpoint), &handle)
        if let error = SANEError(status) {
            sane_exit()
            throw error
        }
        live.withLock { $0 = Live(handle: handle) }
    }

    public func close() {
        guard let handle = live.withLock({ live in defer { live.handle = nil }; return live.handle }) else { return }
        sane_close(handle)
        sane_exit()
    }

    public func apply(_ settings: ScanSettings) throws {
        for (name, value) in settings.saneOptions {
            try set(name, to: value)
        }
        self.settings = settings
    }

    public nonisolated func cancel() {
        live.withLock { live in
            live.cancelled = true
            if let handle = live.handle { sane_cancel(handle) }
        }
    }

    /// Feeds pages until the ADF runs out. An empty feeder on the first page is an error
    /// (`SANEError.feederEmpty`); running out after at least one page ends the batch.
    public nonisolated func pages() -> AsyncThrowingStream<RawPage, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.feed(into: continuation) }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                    self.cancel()
                }
            }
        }
    }

    public func options() throws -> [SANEOption] {
        let handle = try openHandle()
        var options: [SANEOption] = []
        for index in 1..<optionCount(handle) {
            guard let descriptor = sane_get_option_descriptor(handle, index)?.pointee,
                  descriptor.type != SANE_TYPE_GROUP,
                  let name = descriptor.name.map({ String(cString: $0) }), !name.isEmpty
            else { continue }
            let isActive = descriptor.cap & SANE_CAP_INACTIVE == 0
            options.append(SANEOption(
                name: name,
                title: descriptor.title.map { String(cString: $0) } ?? name,
                value: isActive ? (try? value(of: descriptor, at: index, handle: handle)) ?? "" : "inactive",
                allowed: Self.describeConstraint(descriptor),
                isActive: isActive
            ))
        }
        return options
    }

    private func feed(into continuation: AsyncThrowingStream<RawPage, any Error>.Continuation) {
        do {
            let handle = try openHandle()
            var index = 0
            while true {
                if live.withLock({ $0.cancelled }) { throw SANEError.cancelled }
                let status = sane_start(handle)
                if status == SANE_STATUS_NO_DOCS, index > 0 { break }
                try check(status)
                let side: PageSide = settings.sides == .duplex && index % 2 == 1 ? .back : .front
                continuation.yield(RawPage(index: index, side: side, image: try readFrame(handle), dpi: settings.dpi))
                index += 1
            }
            sane_cancel(handle)
            continuation.finish()
        } catch {
            if let handle = live.withLock({ $0.handle }) { sane_cancel(handle) }
            continuation.finish(throwing: error)
        }
    }

    /// Over Wi-Fi in ADF mode the backend often reports `lines == -1`, so the frame is read
    /// until EOF and its height derived from the byte count.
    private func readFrame(_ handle: SANE_Handle) throws -> CGImage {
        var parameters = SANE_Parameters()
        try check(sane_get_parameters(handle, &parameters))
        let bytesPerLine = Int(parameters.bytes_per_line)
        var bytes: [UInt8] = []
        if parameters.lines > 0 { bytes.reserveCapacity(bytesPerLine * Int(parameters.lines)) }
        var chunk = [UInt8](repeating: 0, count: 1 << 18)
        while true {
            var length: SANE_Int = 0
            let status = chunk.withUnsafeMutableBufferPointer {
                sane_read(handle, $0.baseAddress, SANE_Int($0.count), &length)
            }
            if status == SANE_STATUS_EOF { break }
            try check(status)
            bytes.append(contentsOf: chunk[..<Int(length)])
        }
        return try Self.makeImage(
            bytes: bytes,
            width: Int(parameters.pixels_per_line),
            bytesPerLine: bytesPerLine,
            format: parameters.format,
            depth: Int(parameters.depth)
        )
    }

    static func makeImage(bytes: [UInt8], width: Int, bytesPerLine: Int, format: SANE_Frame, depth: Int) throws -> CGImage {
        let height = bytes.count / bytesPerLine
        let (space, components): (CGColorSpace, Int)
        switch (format, depth) {
        case (SANE_FRAME_GRAY, 1), (SANE_FRAME_GRAY, 8): (space, components) = (CGColorSpaceCreateDeviceGray(), 1)
        case (SANE_FRAME_RGB, 8): (space, components) = (CGColorSpaceCreateDeviceRGB(), 3)
        default: throw SANEError.unsupportedFrame(format: Int(format.rawValue), depth: depth)
        }
        // SANE line art uses 1 for black; Quartz gray uses 0 for black.
        let decode: [CGFloat]? = depth == 1 ? [1, 0] : nil
        guard height > 0,
              let provider = CGDataProvider(data: Data(bytes[..<(height * bytesPerLine)]) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: depth,
                                  bitsPerPixel: depth * components, bytesPerRow: bytesPerLine,
                                  space: space, bitmapInfo: [], provider: provider,
                                  decode: decode, shouldInterpolate: false, intent: .defaultIntent)
        else { throw SANEError.unsupportedFrame(format: Int(format.rawValue), depth: depth) }
        return image
    }

    private func set(_ name: String, to value: SANEOptionValue) throws {
        let handle = try openHandle()
        guard let index = (1..<optionCount(handle)).first(where: { index in
            sane_get_option_descriptor(handle, index)?.pointee.name.map { String(cString: $0) } == name
        }), let descriptor = sane_get_option_descriptor(handle, index)?.pointee
        else { throw SANEError.missingOption(name) }

        var info: SANE_Int = 0
        switch value {
        case .string(let string):
            var buffer = [CChar](repeating: 0, count: max(Int(descriptor.size), string.utf8.count + 1))
            buffer.withUnsafeMutableBufferPointer { buffer in
                for (offset, byte) in string.utf8.enumerated() { buffer[offset] = CChar(bitPattern: byte) }
            }
            try check(sane_control_option(handle, index, SANE_ACTION_SET_VALUE, &buffer, &info))
        case .int(let int):
            var word = SANE_Word(descriptor.type == SANE_TYPE_FIXED ? int << SANE_FIXED_SCALE_SHIFT : int)
            try check(sane_control_option(handle, index, SANE_ACTION_SET_VALUE, &word, &info))
        }
    }

    private func value(of descriptor: SANE_Option_Descriptor, at index: SANE_Int, handle: SANE_Handle) throws -> String {
        switch descriptor.type {
        case SANE_TYPE_STRING:
            var buffer = [CChar](repeating: 0, count: Int(descriptor.size) + 1)
            try check(sane_control_option(handle, index, SANE_ACTION_GET_VALUE, &buffer, nil))
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        case SANE_TYPE_INT, SANE_TYPE_BOOL, SANE_TYPE_FIXED:
            var words = [SANE_Word](repeating: 0, count: max(1, Int(descriptor.size) / MemoryLayout<SANE_Word>.size))
            try check(sane_control_option(handle, index, SANE_ACTION_GET_VALUE, &words, nil))
            return Self.format(words[0], type: descriptor.type)
        default:
            return ""
        }
    }

    private static func describeConstraint(_ descriptor: SANE_Option_Descriptor) -> String {
        switch descriptor.constraint_type {
        case SANE_CONSTRAINT_STRING_LIST:
            var strings: [String] = []
            var cursor = descriptor.constraint.string_list
            while let string = cursor?.pointee {
                strings.append(String(cString: string))
                cursor = cursor?.successor()
            }
            return strings.joined(separator: "|")
        case SANE_CONSTRAINT_WORD_LIST:
            guard let list = descriptor.constraint.word_list else { return "" }
            return (1...Int(list[0])).map { format(list[$0], type: descriptor.type) }.joined(separator: "|")
        case SANE_CONSTRAINT_RANGE:
            guard let range = descriptor.constraint.range?.pointee else { return "" }
            return "\(format(range.min, type: descriptor.type))..\(format(range.max, type: descriptor.type))"
        default:
            return ""
        }
    }

    private static func format(_ word: SANE_Word, type: SANE_Value_Type) -> String {
        switch type {
        case SANE_TYPE_FIXED: String(format: "%.1f", Double(word) / Double(1 << SANE_FIXED_SCALE_SHIFT))
        case SANE_TYPE_BOOL: word == 0 ? "no" : "yes"
        default: String(word)
        }
    }

    private func optionCount(_ handle: SANE_Handle) -> SANE_Int {
        var count: SANE_Int = 0
        sane_control_option(handle, 0, SANE_ACTION_GET_VALUE, &count, nil)
        return count
    }

    private func openHandle() throws -> SANE_Handle {
        guard let handle = live.withLock({ $0.handle }) else { throw SANEError.invalid }
        return handle
    }

    private func check(_ status: SANE_Status) throws {
        if let error = SANEError(status) { throw error }
    }
}
