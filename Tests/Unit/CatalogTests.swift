import XCTest
@testable import LocalShift

final class CatalogTests: XCTestCase {
    private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testFormatsMatchPublishedMatrix() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("docs/conversion-matrix.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let matrix = try XCTUnwrap(json["matrix"] as? [String: [String]])
        XCTAssertEqual(Set(matrix.keys), Set(CapabilityCatalog.formats.keys))
        for (source, targets) in matrix { XCTAssertEqual(Set(targets), Set(CapabilityCatalog.formats[source] ?? []), source) }
        let count = CapabilityCatalog.formats.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(count, json["count"] as? Int)
    }

    func testNoFormatConvertsToItself() {
        for (source, targets) in CapabilityCatalog.formats { XCTAssertFalse(targets.contains(source), source) }
    }

    func testEverySourceFormatHasACategory() {
        for source in CapabilityCatalog.formats.keys {
            XCTAssertNotEqual(CapabilityCatalog.category(for: URL(fileURLWithPath: "/tmp/sample." + source)), .other, source)
        }
    }

    func testExtensionAliases() {
        XCTAssertEqual(CapabilityCatalog.ext(URL(fileURLWithPath: "/tmp/a.JPEG")), "jpg")
        XCTAssertEqual(CapabilityCatalog.ext(URL(fileURLWithPath: "/tmp/a.tif")), "tiff")
        XCTAssertEqual(CapabilityCatalog.category(for: URL(fileURLWithPath: "/tmp/a.m4v")), .video)
    }

    func testToolCatalogHasUniqueIDs() {
        let ids = CapabilityCatalog.tools.map(\.0)
        XCTAssertEqual(ids.count, 26)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testImageToolsResolveToCatalogEntries() {
        let options = CapabilityCatalog.options(for: URL(fileURLWithPath: "/tmp/a.png"), mode: .tools)
        XCTAssertFalse(options.isEmpty)
        let known = Set(CapabilityCatalog.tools.map(\.0) + ["readQRCode"])
        for option in options { XCTAssertTrue(known.contains(option.id), option.id) }
    }

    func testActionsWheelIsRemoved() {
        XCTAssertEqual(CapabilityCatalog.options(for: URL(fileURLWithPath: "/tmp/a.txt"), mode: .actions).count, 0)
    }
}
