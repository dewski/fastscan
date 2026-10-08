import CoreGraphics
import Foundation

/// Builds 8-bit gray test images row by row, mimicking what the FF-680W returns.
struct SyntheticPage {
    var width: Int
    private(set) var pixels: [UInt8] = []
    private var generator = SplitMix(seed: 42)

    init(width: Int) { self.width = width }

    var height: Int { pixels.count / width }

    mutating func rows(_ count: Int, level: UInt8, noise: Int = 0) {
        for _ in 0..<(count * width) {
            let jitter = noise == 0 ? 0 : Int(generator.next() % UInt64(2 * noise + 1)) - noise
            pixels.append(UInt8(clamping: Int(level) + jitter))
        }
    }

    /// Paper rows with "text": dark bars in a regular pattern inside 0.5 in margins.
    mutating func paper(_ count: Int, textLines: Int, level: UInt8 = 250) {
        let start = height
        rows(count, level: level, noise: 3)
        let lineHeight = 30, margin = 150
        for line in 0..<textLines {
            let top = start + margin + line * lineHeight * 2
            for y in top..<min(top + lineHeight, start + count) {
                for x in margin..<(width - margin) where (x / 12) % 3 != 2 {
                    pixels[y * width + x] = 20
                }
            }
        }
    }

    mutating func fill(columns: Range<Int>, rows: Range<Int>, level: UInt8) {
        for y in rows {
            for x in columns { pixels[y * width + x] = level }
        }
    }

    mutating func speckle(_ count: Int, level: UInt8) {
        for _ in 0..<count {
            pixels[Int(generator.next() % UInt64(pixels.count))] = level
        }
    }

    /// Faint mirrored text from the other side of thin paper.
    mutating func bleedThrough(rows range: Range<Int>, level: UInt8) {
        for y in range {
            for x in 200..<(width - 200) where (x / 10) % 2 == 0 {
                pixels[y * width + x] = level
            }
        }
    }

    var image: CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
