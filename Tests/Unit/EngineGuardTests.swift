import XCTest
@testable import LocalShift

final class EngineGuardTests: XCTestCase {
    func testCanonicalAliasesDependOnCategory() {
        XCTAssertEqual(ConverterEngine.canonical("trim", category: .audio), "trimAudio")
        XCTAssertEqual(ConverterEngine.canonical("trim", category: .video), "trimVideo")
        XCTAssertEqual(ConverterEngine.canonical("crop", category: .image), "cropImage")
        XCTAssertEqual(ConverterEngine.canonical("crop", category: .video), "cropVideo")
        XCTAssertEqual(ConverterEngine.canonical("pdfMerge", category: .pdf), "mergePDF")
        XCTAssertEqual(ConverterEngine.canonical("format_png", category: .image), "format_png")
    }

    func testRejectsEmptyInput() {
        XCTAssertThrowsError(try ConverterEngine.convert([], option: "format_png", settings: ConversionSettings(), progress: { _, _ in }))
    }

    func testRejectsInvalidSettingsBeforeTouchingFiles() throws {
        let file = try temporaryFile("a.txt")
        var settings = ConversionSettings(); settings.quality = 2
        XCTAssertThrowsError(try ConverterEngine.convert([file], option: "format_md", settings: settings, progress: { _, _ in }))
        settings = ConversionSettings(); settings.width = 0
        XCTAssertThrowsError(try ConverterEngine.convert([file], option: "format_md", settings: settings, progress: { _, _ in }))
    }

    func testRejectsUnsupportedOperation() throws {
        let file = try temporaryFile("a.txt")
        XCTAssertThrowsError(try ConverterEngine.convert([file], option: "format_mp3", settings: ConversionSettings(), progress: { _, _ in }))
    }

    func testUniqueURLNumbersCollisions() throws {
        let folder = try temporaryFolder()
        let first = ConverterEngine.uniqueURL(in: folder, name: "report.pdf")
        XCTAssertEqual(first.lastPathComponent, "report.pdf")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        XCTAssertEqual(ConverterEngine.uniqueURL(in: folder, name: "report.pdf").lastPathComponent, "report (1).pdf")
    }

    func testDevelopmentBinariesMayUseSystemRuntimes() {
        // The test runner is not an .app bundle, so development fallbacks stay enabled here.
        XCTAssertTrue(OperationContext.allowsSystemRuntime)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalShiftUnit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func temporaryFile(_ name: String) throws -> URL {
        let url = try temporaryFolder().appendingPathComponent(name)
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
