import XCTest
@testable import LocalShift

final class SubtitleTests: XCTestCase {
    private func convert(_ content: String, from ext: String, to format: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalShiftSubs-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("in." + ext)
        try content.write(to: input, atomically: true, encoding: .utf8)
        let output = try SubtitleEngine.convert(input, format: format, scratch: folder)
        XCTAssertEqual(output.pathExtension, format)
        return try String(contentsOf: output, encoding: .utf8)
    }

    private let srt = "1\r\n00:00:01,200 --> 00:00:02,400\r\n你好。\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,500\r\n第二行\r\n换行保留\r\n"

    func testSRTToVTTKeepsMillisecondsAndLines() throws {
        let vtt = try convert(srt, from: "srt", to: "vtt")
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:01.200 --> 00:00:02.400\n你好。"))
        XCTAssertTrue(vtt.contains("第二行\n换行保留"))
    }

    func testVTTToSRTNumbersCuesAndDropsIdentifiers() throws {
        let vtt = "WEBVTT\n\nintro\n00:01.000 --> 00:03.000 align:start\nFirst\n\nnext\n00:04.000 --> 00:05.000\nSecond\n"
        let out = try convert(vtt, from: "vtt", to: "srt")
        XCTAssertEqual(out, "1\n00:00:01,000 --> 00:00:03,000\nFirst\n\n2\n00:00:04,000 --> 00:00:05,000\nSecond\n")
    }

    func testTextDropsTiming() throws {
        let txt = try convert(srt, from: "srt", to: "txt")
        XCTAssertEqual(txt, "你好。\n\n第二行\n换行保留\n")
    }

    func testRejectsFileWithoutTimings() {
        XCTAssertThrowsError(try convert("just text", from: "srt", to: "vtt"))
    }
}
