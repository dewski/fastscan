import Testing
@testable import ScanKit

@Suite struct ScannerCapabilitiesTests {
    /// The FF-680W's CAPA data block, from a capture.
    static let capa = Array(("#ADFDPLX#ADFPEDT#ADFDFL1DFL3#ADFLDF #ADFEJCT#ADFCRP #ADFSKEW#ADFOVSN#ADFRSMSLISTd300d600"
        + "#COLLISTC024M008R008G008B008#FMTLISTJPG #JPGRANGd001d100#GMMLISTUG10UG18#GMTLISTRED GRN BLU MONO#CMXLISTUNITUM08"
        + "#RSMLISTd050d075d100d150d200d240d300d360d400d600#RSSLISTd050d075d100d150d200d240d300d360d400d600"
        + "#CRPRANGi-000020d020#LAMLISTON  OFF ").utf8)

    @Test func readsTheScannersCapabilities() throws {
        #expect(Self.capa.count == 332)
        let capabilities = try ScannerCapabilities(capa: Self.capa, exi: ESCI2Tests.exi)
        #expect(capabilities.resolutions == [50, 75, 100, 150, 200, 240, 300, 360, 400, 600])
        #expect(capabilities.feederResolutions == [300, 600])
        #expect(capabilities.colorModes == ["C024", "M008", "R008", "G008", "B008"])
        #expect(capabilities.formats == ["JPG"])
        #expect(capabilities.jpegQuality == 1...100)
        #expect(capabilities.feederOptions == ["DPLX", "PEDT", "DFL1", "DFL3", "LDF", "EJCT", "CRP", "SKEW", "OVSN"])
        #expect(capabilities.normalSpeedLength == [300: 3600, 600: 1550])
        #expect(capabilities.maximumLength == [200: 24000, 300: 21500, 600: 5300])
        #expect(capabilities.tokens.count == 19)  // nine #ADF entries and ten others
    }

    @Test func scansOnlyAtResolutionsWithAPageLength() throws {
        #expect(try ScannerCapabilities(capa: Self.capa, exi: ESCI2Tests.exi).scanResolutions == [300, 600])
    }

    @Test func asksTheScannerInItsOwnMode() async throws {
        let scanner = ScriptedScanner(
            ScriptedScanner.opening() + [ScriptedScanner.mode("Y")] + ScriptedScanner.command("CAPA", data: Self.capa)
                + ScriptedScanner.command("FIN") + [ScriptedScanner.unlock]
        )
        let session = ScannerSession()
        try await session.open(scanner)
        let capabilities = try await session.capabilities()
        await session.close()
        #expect(capabilities.scanResolutions == [300, 600])
        #expect(await scanner.unmatched == [])
        #expect(await scanner.finished)
    }
}
