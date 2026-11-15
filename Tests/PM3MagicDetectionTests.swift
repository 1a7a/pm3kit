import XCTest
@testable import pm3kit

/// Fixtures reproduce the shape of real pm3 session output.
final class PM3MagicDetectionTests: XCTestCase {

    /// Magic blanks commonly answer the Gen4 GDM / USCUID probe as well as the
    /// Gen1a one. Checking Gen4 first refuses clones that would have worked.
    private let gen1aThatAlsoAnswersGen4 = """
    [+] Magic capabilities... Gen 1a
    [+] Magic capabilities... Gen 4 GDM / USCUID ( Gen4 Magic Wakeup )
    [+] Magic capabilities... Gen 4 GDM / USCUID ( Gen1 Magic Wakeup )
    [+] Prng detection..... weak
    """

    func testGen1aWinsOverTheGen4ProbeItAlsoAnswers() {
        XCTAssertEqual(PM3.classifyMagic(gen1aThatAlsoAnswersGen4), .gen1a,
                       "this blank clones fine with hf mf cload; calling it Gen4 aborts the clone")
    }

    func testPlainGen1aIsStillGen1a() {
        XCTAssertEqual(PM3.classifyMagic("[+] Magic capabilities... Gen 1a"), .gen1a)
    }

    func testGen2IsDetected() {
        XCTAssertEqual(PM3.classifyMagic("[+] Magic capabilities... Gen 2 / CUID"), .gen2)
    }

    func testAGenuineGen4IsStillGen4() {
        let gen4Only = """
        [+] Magic capabilities... Gen 4 GDM / USCUID ( Gen4 Magic Wakeup )
        """
        XCTAssertEqual(PM3.classifyMagic(gen4Only), .gen4)
    }

    func testUSCUIDIsNotReadAsCUID() {
        XCTAssertEqual(PM3.classifyMagic("[+] Magic capabilities... Gen 4 GDM / USCUID"), .gen4,
                       "CUID is a substring of USCUID; the Gen2 check must match whole words")
    }

    func testPlainCardIsNotMagic() {
        let plain = """
        [=] ---------- ISO14443-A Information ----------
        [+]  UID: 1A 2B 3C 4D   ( ONUID, re-used )
        [+]  SAK: 08 [2]
        """
        XCTAssertEqual(PM3.classifyMagic(plain), .none)
    }

    func testCapabilityLineWithNoRecognisedGenerationIsUnknown() {
        XCTAssertEqual(PM3.classifyMagic("[+] Magic capabilities... something new"), .unknown)
    }

    // MARK: parseHF

    private let realHFSearch = """
    [=] hf search

    [=] ---------- ISO14443-A Information ----------
    [+]  UID: 1A 2B 3C 4D   ( ONUID, re-used )
    [+] ATQA: 00 04
    [+]  SAK: 08 [2]
    [+] Possible types:
    [+]    MIFARE Classic 1K
    [+] Valid ISO 14443-A tag found
    """

    func testParsesRealHFSearchOutput() throws {
        let track = try XCTUnwrap(PM3.parseHF(realHFSearch))
        XCTAssertEqual(track.family, "mifare_classic")
        XCTAssertEqual(track.ident, "1A2B3C4D", "UID bytes are printed space separated")
        XCTAssertEqual(track.band, .hf)
        XCTAssertTrue(track.cloneable)
    }

    func testWriteOutputIsNotMistakenForACard() {
        // hf mf cload prints this; it names MIFARE Classic but identifies no card.
        let cloadOutput = """
        [=] Copying to magic gen1a MIFARE Classic 1K
        [?] Hint: Verify that it is a GDM and not USCUID derivative
        """
        XCTAssertNil(PM3.parseHF(cloadOutput),
                     "a card with no UID cannot be cloned or verified, so it must not be saved")
    }

    func testEncryptedCardIsFlaggedNotCloneable() throws {
        let desfire = """
        [=] ---------- ISO14443-A Information ----------
        [+]  UID: 04 11 22 33 44 55 66
        [+] Possible types:
        [+]    MIFARE DESFire EV1
        """
        let track = try XCTUnwrap(PM3.parseHF(desfire))
        XCTAssertEqual(track.family, "encrypted")
        XCTAssertFalse(track.cloneable)
    }

    func testNoTagFoundParsesToNothing() {
        XCTAssertNil(PM3.parseHF("[!] No known/supported 13.56 MHz tags found"))
    }
}
