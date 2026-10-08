import Testing
@testable import ScanKit

@Suite struct ScanSettingsTests {
    @Test func defaultIsOneSidedGrayAt300() {
        #expect(ScanSettings.default == ScanSettings(sides: .front, color: .gray, dpi: 300))
    }

    @Test(arguments: [
        (Sides.front, ScanColor.lineart, 200, "ADF Front", "Lineart", 1),
        (Sides.duplex, ScanColor.gray, 300, "ADF Duplex", "Gray", 8),
        (Sides.front, ScanColor.color, 600, "ADF Front", "Color", 8),
    ])
    func mapsToEpsondsOptions(sides: Sides, color: ScanColor, dpi: Int, source: String, mode: String, depth: Int) {
        let options = ScanSettings(sides: sides, color: color, dpi: dpi).saneOptions
        #expect(options.map(\.name) == ["source", "mode", "depth", "resolution"])
        #expect(options.map(\.value) == [.string(source), .string(mode), .int(depth), .int(dpi)])
    }
}
