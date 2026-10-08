import CoreGraphics

/// Pure image transforms for scanned pages.
///
/// The FF-680W returns every ADF page at the maximum frame length. Top to bottom, a frame is a short
/// leading edge, the paper, a dark trailing-edge shadow, sometimes ~0.35 in of uniform gray backing
/// (luminance ~210), then fill to the end of the frame. The fill is exactly 255 with no sensor noise,
/// which is what tells it apart from blank paper. `crop` cuts at the paper's edges, so the page keeps
/// its physical size instead of being trimmed to its content.
public enum PageProcessor {
    public static func crop(_ image: CGImage, dpi: Int) -> CGImage {
        let factor = max(1, dpi / 75)
        let raster = GrayRaster(image, downsample: factor)
        let edge = 75 * 15 / 100

        let rows = (0..<raster.height).map { raster.lineStats(row: $0) }
        let top = leadingInset(rows, maxEdge: edge)
        let bottom = trailingInset(rows, maxEdge: edge)
        guard rows.count - top - bottom > rows.count / 10 else { return image }

        let columns = (0..<raster.width).map { raster.lineStats(column: $0, rows: top..<(rows.count - bottom)) }
        let left = leadingInset(columns, maxEdge: edge)
        let right = leadingInset(columns.reversed(), maxEdge: edge)
        guard columns.count - left - right > columns.count / 10 else { return image }

        // Insets scale back up from the edges, so a truncated last raster row never trims the image.
        let rect = CGRect(x: left * factor, y: top * factor,
                          width: image.width - (left + right) * factor, height: image.height - (top + bottom) * factor)
        return image.cropping(to: rect) ?? image
    }

    /// A page is blank when almost nothing on it is much darker than the paper itself. Bleed-through
    /// from the other side and sensor noise stay within ~90 levels of the paper, and isolated specks
    /// are averaged away by analysing at 150 dpi.
    public static func isBlank(_ image: CGImage, dpi: Int) -> Bool {
        let raster = GrayRaster(image, downsample: max(1, dpi / 150))
        let marginX = raster.width / 25, marginY = raster.height / 25
        var histogram = [Int](repeating: 0, count: 256)
        for y in marginY..<(raster.height - marginY) {
            for x in marginX..<(raster.width - marginX) {
                histogram[Int(raster[x, y])] += 1
            }
        }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return true }
        let paper = percentile(histogram, total: total, 0.9)
        // A soft, low-contrast photo (fog, a beach, an overexposed print) can have no "ink", but
        // most of it isn't paper-colored either; a blank side is paper almost everywhere.
        if percentile(histogram, total: total, 0.5) < paper - 20 { return false }
        let inkThreshold = max(0, paper - 90)
        let ink = histogram[..<inkThreshold].reduce(0, +)
        return Double(ink) / Double(total) < 0.0002
    }

    private static func percentile(_ histogram: [Int], total: Int, _ fraction: Double) -> Int {
        var running = 0
        for (level, count) in histogram.enumerated() {
            running += count
            if Double(running) >= Double(total) * fraction { return level }
        }
        return 255
    }

    /// Skips gray backing at the start of a profile, then up to `maxEdge` lines of shadow or
    /// leading edge until paper-white begins.
    private static func leadingInset(_ lines: some Collection<LineStats>, maxEdge: Int) -> Int {
        let lines = Array(lines)
        var i = 0
        while i < lines.count, lines[i].isBacking { i += 1 }
        let limit = min(lines.count, i + maxEdge)
        while i < limit, !lines[i].isPaper { i += 1 }
        return i
    }

    /// Skips the fill, the gray backing band when the scanner left one, then the trailing-edge shadow.
    private static func trailingInset(_ rows: [LineStats], maxEdge: Int) -> Int {
        var y = rows.count - 1
        while y >= 0, rows[y].isFill { y -= 1 }
        guard y >= 0 else { return 0 }
        // A skewed page slants the fill/backing boundary, so look a few rows past it for the band.
        if let band = stride(from: y, through: max(0, y - maxEdge), by: -1).first(where: { rows[$0].isBacking }) {
            y = band
            while y >= 0, rows[y].isBacking { y -= 1 }
        }
        // The shadow can sit a few near-white rows above the fill, so cut above the highest
        // non-paper row near the edge rather than stopping at the first paper-like row.
        if let shadowTop = (max(0, y - maxEdge)...y).first(where: { !rows[$0].isPaper }) { y = shadowTop - 1 }
        return rows.count - 1 - y
    }
}

struct LineStats {
    var mean: Double
    var deviation: Double
    var brightFraction: Double
    var minimum: UInt8

    /// Mostly paper-white, which also holds for a line that crosses a narrow page and backing.
    var isPaper: Bool { brightFraction >= 0.5 }
    var isFill: Bool { minimum >= 254 }
    var isBacking: Bool { (150...232).contains(mean) && deviation <= 6 }
}

/// An 8-bit grayscale copy of an image, box-averaged by an integer factor. Row 0 is the top.
struct GrayRaster {
    let width: Int
    let height: Int
    private var pixels: [UInt8]
    /// Darkest full-resolution pixel under each raster row; box averaging would hide paper noise.
    private var rowMinimum: [UInt8]

    init(_ image: CGImage, downsample factor: Int) {
        let fullWidth = image.width, fullHeight = image.height
        var full = [UInt8](repeating: 255, count: fullWidth * fullHeight)
        full.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: fullWidth, height: fullHeight, bitsPerComponent: 8,
                                    bytesPerRow: fullWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight))
        }
        width = fullWidth / factor
        height = fullHeight / factor
        rowMinimum = (0..<height).map { y in full[(y * factor * fullWidth)..<((y + 1) * factor * fullWidth)].min() ?? 255 }
        guard factor > 1 else {
            pixels = full
            return
        }
        var reduced = [UInt8](repeating: 0, count: width * height)
        let area = factor * factor
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0
                for dy in 0..<factor {
                    let base = (y * factor + dy) * fullWidth + x * factor
                    for dx in 0..<factor { sum += Int(full[base + dx]) }
                }
                reduced[y * width + x] = UInt8(sum / area)
            }
        }
        pixels = reduced
    }

    subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// Stats over the middle 80% of a row, so backing that shows beside a narrow page doesn't
    /// mask the paper.
    func lineStats(row y: Int) -> LineStats {
        let inset = width / 10
        return Self.stats((inset..<(width - inset)).map { self[$0, y] }, minimum: rowMinimum[y])
    }

    func lineStats(column x: Int, rows: Range<Int>) -> LineStats {
        let values = rows.map { self[x, $0] }
        return Self.stats(values, minimum: values.min() ?? 255)
    }

    private static func stats(_ values: [UInt8], minimum: UInt8) -> LineStats {
        guard !values.isEmpty else { return LineStats(mean: 255, deviation: 0, brightFraction: 1, minimum: minimum) }
        let count = Double(values.count)
        let mean = values.reduce(0.0) { $0 + Double($1) } / count
        let variance = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / count
        let bright = Double(values.count { $0 >= 235 }) / count
        return LineStats(mean: mean, deviation: variance.squareRoot(), brightFraction: bright, minimum: minimum)
    }
}
