import XCTest
@testable import pm3kit

/// Builds autopwn-shaped file sets in a temporary folder, so the suite runs
/// anywhere and never reads a real card dump.
final class PM3ImportTests: XCTestCase {

    private var source: URL!
    private var destination: URL!

    private let uid = "DEADBEEF"
    private var dumpName: String { "hf-mf-\(uid)-dump.bin" }
    private var jsonName: String { "hf-mf-\(uid)-dump.json" }
    private var keyName: String { "hf-mf-\(uid)-key.bin" }

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("import-tests-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("dumps")
        for dir in [source!, destination!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    @discardableResult
    private func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// A 1K dump starts with the UID in block 0; the key table is 16 sectors
    /// times two keys of six bytes.
    private func writeFullSet() throws -> (dump: URL, json: URL, key: URL) {
        var dump: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        dump.append(contentsOf: [UInt8](repeating: 0x00, count: 1024 - 4))
        let d = try write(dumpName, dump)
        let j = try write(jsonName, Array(#"{"FileType":"mfc v2"}"#.utf8))
        let k = try write(keyName, [UInt8](repeating: 0xFF, count: 16 * 2 * 6))
        return (d, j, k)
    }

    func testFullSetImportsWithKeyBesideDump() throws {
        let set = try writeFullSet()
        let track = try XCTUnwrap(
            PM3.importMifareDump(from: [set.dump, set.json, set.key], into: destination))

        XCTAssertEqual(track.ident, uid)
        XCTAssertEqual(track.family, "mifare_classic")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(track.dumpfile)).lastPathComponent,
                       dumpName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent(keyName).path),
            "Gen2 restore finds the key file by name beside the dump")
    }

    func testSetWithNoJSONStillImports() throws {
        let set = try writeFullSet()
        let track = try XCTUnwrap(PM3.importMifareDump(from: [set.dump, set.key], into: destination))

        XCTAssertEqual(track.ident, uid)
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(track.dumpfile)).lastPathComponent,
                       dumpName)
    }

    func testFileOrderFromThePickerDoesNotMatter() throws {
        let set = try writeFullSet()
        let track = try XCTUnwrap(
            PM3.importMifareDump(from: [set.key, set.json, set.dump], into: destination))

        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(track.dumpfile)).lastPathComponent,
                       dumpName,
                       "the dump must win over the key file whatever order they arrive in")
    }

    func testCopiedFilesAreByteIdentical() throws {
        let set = try writeFullSet()
        _ = PM3.importMifareDump(from: [set.dump, set.json, set.key], into: destination)

        for original in [set.dump, set.json, set.key] {
            let copy = destination.appendingPathComponent(original.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: copy),
                           original.lastPathComponent)
        }
    }

    func testSelectingOnlyTheKeyFileIsRejected() throws {
        let set = try writeFullSet()

        XCTAssertNil(PM3.importMifareDump(from: [set.key], into: destination),
                     "a key file is not a dump; cloning it would write key bytes to the card")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [],
                       "a rejected import must not leave files behind")
    }

    func testDumpAloneImportsForGen1a() throws {
        let set = try writeFullSet()
        let track = try XCTUnwrap(PM3.importMifareDump(from: [set.dump], into: destination))

        XCTAssertEqual(track.ident, uid, "Gen1a cload needs only the dump")
    }

    func testUIDIsReadFromBlockZeroWhenTheFilenameHasNone() throws {
        var dump: [UInt8] = [0xCA, 0xFE, 0xF0, 0x0D]
        dump.append(contentsOf: [UInt8](repeating: 0x00, count: 1024 - 4))
        let renamed = try write("my-card-dump.bin", dump)

        let track = try XCTUnwrap(PM3.importMifareDump(from: [renamed], into: destination))
        XCTAssertEqual(track.ident, "CAFEF00D", "fall back to the UID in block 0")
    }
}
