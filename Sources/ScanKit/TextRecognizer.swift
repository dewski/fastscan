import CoreGraphics
import Vision

public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    /// Normalized to 0...1 with a lower-left origin, matching PDF page space.
    public var normalizedBox: CGRect

    public init(text: String, normalizedBox: CGRect) {
        self.text = text
        self.normalizedBox = normalizedBox
    }
}

public enum TextRecognizer {
    public static func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        let first = try await read(image)
        guard first.confidence < 0.85 else { return first.lines }
        // Vision sometimes reads a whole upright page as if it were upside down, giving garbage at
        // ~0.75 mean confidence instead of ~0.95. It depends on the exact pixel dimensions, so a
        // second pass over a slightly inset copy reads it correctly.
        let inset = 16
        let frame = CGRect(x: inset, y: inset, width: image.width - 2 * inset, height: image.height - 2 * inset)
        guard let insetImage = image.cropping(to: frame) else { return first.lines }
        let second = try await read(insetImage)
        guard second.score > first.score else { return first.lines }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return second.lines.map { line in
            var line = line
            let box = line.normalizedBox
            line.normalizedBox = CGRect(x: (frame.minX + box.minX * frame.width) / width,
                                        y: (frame.minY + box.minY * frame.height) / height,
                                        width: box.width * frame.width / width,
                                        height: box.height * frame.height / height)
            return line
        }
    }

    private struct Reading {
        var lines: [RecognizedLine]
        var confidence: Double
        var score: Double { confidence * Double(lines.reduce(0) { $0 + $1.text.count }) }
    }

    private static func read(_ image: CGImage) async throws -> Reading {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // The default skips the fine print on dense pages such as warranty terms.
        request.minimumTextHeightFraction = 0.004
        let observations = try await request.perform(on: image, orientation: .up)
        let lines = observations.compactMap { observation in
            observation.topCandidates(1).first.map {
                RecognizedLine(text: $0.string, normalizedBox: observation.boundingBox.cgRect)
            }
        }
        let confidence = observations.isEmpty ? 1 : observations.map { Double($0.confidence) }.reduce(0, +) / Double(observations.count)
        return Reading(lines: lines, confidence: confidence)
    }
}
