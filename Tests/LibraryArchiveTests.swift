import XCTest
@testable import pm3kit

final class LibraryArchiveTests: XCTestCase {

    private var scratch: URL!

    /// Restore targets this instead of `PM3.dumpDir`, so a test run never
    /// touches the real library's dumps.
    private var restoreTarget: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm3kit-tests-\(UUID().uuidString)")
        restoreTarget = scratch.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: restoreTarget, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    private func writeScratchFile(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func makeMifareDumpSet() throws -> URL {
        let primary = try writeScratchFile("hf-mf-DEADBEEF-dump.bin", [0xDE, 0xAD, 0xBE, 0xEF, 0x01])
        try writeScratchFile("hf-mf-DEADBEEF-key.bin", Array(repeating: 0xFF, count: 6))
        try writeScratchFile("hf-mf-DEADBEEF-dump.json", Array("{}".utf8))
        try writeScratchFile("hf-mf-CAFE0001-dump.bin", [0xCA, 0xFE])
        return primary
    }

    private func makeDualCard(dumpPath: String) -> SavedCard {
        SavedCard(name: "Front door", notes: "lobby", tracks: [
            CardTrack(band: .hf, family: "mifare_classic", ident: "DEADBEEF",
                      cloneable: true, dumpfile: dumpPath),
            CardTrack(band: .lf, family: "em410x", ident: "1234567890", cloneable: true),
        ])
    }

    private func hfTrack(of card: SavedCard) throws -> CardTrack {
        try XCTUnwrap(card.tracks.first { $0.band == .hf })
    }

    // MARK: stem

    func testDumpAndKeyFilesShareAStem() {
        XCTAssertEqual(LibraryArchiveStore.dumpSetStem(forFilename: "hf-mf-DEADBEEF-dump.bin"), "hf-mf-DEADBEEF")
        XCTAssertEqual(LibraryArchiveStore.dumpSetStem(forFilename: "hf-mf-DEADBEEF-key.bin"), "hf-mf-DEADBEEF")
        XCTAssertEqual(LibraryArchiveStore.dumpSetStem(forFilename: "hf-mf-DEADBEEF-dump.json"), "hf-mf-DEADBEEF")
    }

    func testUnrecognizedFilenameStemsToItsBasename() {
        XCTAssertEqual(LibraryArchiveStore.dumpSetStem(forFilename: "mycard.bin"), "mycard")
    }

    // MARK: collection

    func testCollectDumpSetTakesSiblingsAndSkipsOtherCards() throws {
        let primary = try makeMifareDumpSet()
        let set = LibraryArchiveStore.collectDumpSet(primaryPath: primary.path)

        XCTAssertEqual(Set(set.keys), [
            "hf-mf-DEADBEEF-dump.bin",
            "hf-mf-DEADBEEF-key.bin",
            "hf-mf-DEADBEEF-dump.json",
        ], "Gen2 restore needs the key file, and another card's dump must not ride along")
    }

    // MARK: export

    func testArchiveCarriesNoAbsolutePaths() throws {
        let primary = try makeMifareDumpSet()
        let data = try LibraryArchiveStore.encodeArchive(cards: [makeDualCard(dumpPath: primary.path)])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains(NSHomeDirectory()), "an archive must not leak the home directory")
        XCTAssertFalse(json.contains(scratch.path))
    }

    func testExportEmbedsTheWholeDumpSetAndKeepsCardFields() throws {
        let primary = try makeMifareDumpSet()
        let data = try LibraryArchiveStore.encodeArchive(cards: [makeDualCard(dumpPath: primary.path)])
        let archive = try LibraryArchiveStore.decodeArchive(from: data)

        XCTAssertEqual(archive.formatVersion, LibraryArchive.currentFormatVersion)
        XCTAssertEqual(archive.cards.count, 1)
        XCTAssertEqual(archive.cards[0].dumpFiles.count, 3)
        XCTAssertEqual(archive.cards[0].card.notes, "lobby")
        XCTAssertEqual(try hfTrack(of: archive.cards[0].card).dumpfile, "hf-mf-DEADBEEF-dump.bin")
    }

    func testDecodeRejectsAFileThatIsNotAnArchive() {
        XCTAssertThrowsError(try LibraryArchiveStore.decodeArchive(from: Data("not an archive".utf8)))
    }

    // MARK: backup filename

    func testBackupFilenameIsDatedAndPrefixed() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 15
        parts.hour = 17; parts.minute = 9; parts.second = 3
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let date = gregorian.date(from: parts)!

        XCTAssertEqual(LibraryArchiveStore.backupFilename(for: date),
                       "pm3kit-backup-2026-11-15-1709.json")
    }

    // MARK: restore

    func testRestoreWritesTheSetAndRepointsDumpfileLocally() throws {
        let primary = try makeMifareDumpSet()
        let data = try LibraryArchiveStore.encodeArchive(cards: [makeDualCard(dumpPath: primary.path)])
        let archive = try LibraryArchiveStore.decodeArchive(from: data)

        let (restored, summary) = LibraryArchiveStore.restoreCards(from: archive, existing: [], dumpDirectory: restoreTarget)
        XCTAssertEqual(summary.importedCards, 1)
        XCTAssertEqual(summary.writtenFiles, 3)

        let dumpPath = try XCTUnwrap(try hfTrack(of: restored[0]).dumpfile)
        XCTAssertTrue(dumpPath.hasPrefix("/"), "restore must rewrite the bare filename to a local path")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dumpPath))

        let keyBeside = URL(fileURLWithPath: dumpPath)
            .deletingLastPathComponent().appendingPathComponent("hf-mf-DEADBEEF-key.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyBeside.path),
                      "Gen2 restore finds the key file by name beside the dump")
    }

    func testRestoringTheSameArchiveTwiceDoesNotDuplicate() throws {
        let primary = try makeMifareDumpSet()
        let data = try LibraryArchiveStore.encodeArchive(cards: [makeDualCard(dumpPath: primary.path)])
        let archive = try LibraryArchiveStore.decodeArchive(from: data)

        let (restored, _) = LibraryArchiveStore.restoreCards(from: archive, existing: [], dumpDirectory: restoreTarget)
        let (second, summary) = LibraryArchiveStore.restoreCards(from: archive, existing: restored, dumpDirectory: restoreTarget)

        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(summary.skippedDuplicates, 1)
    }

    func testFilenameClashRenamesTheDumpAndItsKeyTogether() throws {
        let primary = try makeMifareDumpSet()
        let data = try LibraryArchiveStore.encodeArchive(cards: [makeDualCard(dumpPath: primary.path)])
        let archive = try LibraryArchiveStore.decodeArchive(from: data)
        let (restored, _) = LibraryArchiveStore.restoreCards(from: archive, existing: [], dumpDirectory: restoreTarget)

        let occupied = try XCTUnwrap(try hfTrack(of: restored[0]).dumpfile)
        try Data([0x00, 0x00]).write(to: URL(fileURLWithPath: occupied))

        var different = archive.cards[0].card
        different.id = UUID()
        let clashing = LibraryArchive(cards: [ArchivedCard(card: different,
                                                           dumpFiles: archive.cards[0].dumpFiles)])
        let (clashed, _) = LibraryArchiveStore.restoreCards(from: clashing, existing: restored, dumpDirectory: restoreTarget)

        let newDump = URL(fileURLWithPath: try XCTUnwrap(try hfTrack(of: clashed[0]).dumpfile))
        XCTAssertNotEqual(newDump.lastPathComponent, "hf-mf-DEADBEEF-dump.bin",
                          "a clash with different bytes must not overwrite the existing dump")

        let stem = LibraryArchiveStore.dumpSetStem(forFilename: newDump.lastPathComponent)
        let renamedKey = newDump.deletingLastPathComponent().appendingPathComponent("\(stem)-key.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedKey.path),
                      "the key must follow the dump's new stem or Gen2 restore breaks")
    }
}
