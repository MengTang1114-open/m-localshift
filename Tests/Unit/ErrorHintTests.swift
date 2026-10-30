import XCTest
@testable import LocalShift

final class ErrorHintTests: XCTestCase {
    func testCorruptMediaGetsSpecificHint() {
        let log = "处理失败：[mov,mp4 @ 0x1] moov atom not found\nbroken.mp4: Invalid data found when processing input"
        XCTAssertEqual(ErrorHint.summary(for: log), "文件已损坏，或者实际格式和扩展名不一致。")
    }

    func testPagesAutomationDenied() {
        XCTAssertTrue(ErrorHint.summary(for: "处理失败：execution error: Not authorized to send Apple events to Pages. (-1743)").contains("自动化"))
    }

    func testEncryptedPDF() {
        XCTAssertTrue(ErrorHint.summary(for: "处理失败：pypdf.errors.FileNotDecryptedError: File has not been decrypted").contains("密码"))
    }

    func testUnknownProcessFailureFallsBackToGenericHint() {
        XCTAssertEqual(ErrorHint.summary(for: "处理失败：something odd"), "无法读取或转换这个文件。请确认文件可以正常打开，且输出位置可写。")
    }

    func testOwnMessagesKeepTheirFirstLine() {
        XCTAssertEqual(ErrorHint.summary(for: "此操作需要至少两个文件。\n细节"), "此操作需要至少两个文件。")
    }
}
