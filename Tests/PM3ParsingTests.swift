import XCTest
@testable import pm3kit

/// Fixtures reproduce the shape of real `lf search` output. The identifiers
/// are invented; no real credential appears in this repository.
final class PM3ParsingTests: XCTestCase {

    private let em410xSearch = """
    [=] Session log /Users/user/.proxmark3/logs/log_20260825060101.txt
    [+] loaded `/Users/user/.proxmark3/preferences.json`
    [=] Checking for known tags...
    [+] EM 410x ID 1A2B3C4D5E
    [+] EM410x ( RF/64 )
    [+]     DEZ 8          : 00692861
    [+] Valid EM410x ID found!
    """

    private let hidProxSearch = """
    [=] Session log /Users/user/.proxmark3/logs/log_20261105160514.txt
    [=] Checking for known tags...
    [+] [H10301  ] HID H10301 26-bit                FC: 203  CN: 15385  parity ( ok )
    [+] [ind26   ] Indala 26-bit                    FC: 3251  CN: 3097  parity ( ok )
    [=] found 2 matching 26-bit formats
    [+] [Tecom27 ] Tecom 27-bit                     FC: 1111  CN: 63592
    [=] raw: 000000000000002004d2162e
    [+] Valid HID Prox ID found!
    [+] Chipset... EM4x05 / EM4x69
    """

    // MARK: EM410x

    func testParsesEM410xID() throws {
        let track = try XCTUnwrap(PM3.parseLF(em410xSearch))
        XCTAssertEqual(track.family, "em410x")
        XCTAssertEqual(track.ident, "1A2B3C4D5E")
        XCTAssertEqual(track.band, .lf)
    }

    func testEM410xIDIsNotTakenFromTheSessionLogFilename() {
        // log_20260825060101 contains "2026082506", ten valid hex characters.
        XCTAssertEqual(PM3.em410xID(in: em410xSearch), "1A2B3C4D5E")
        XCTAssertNotEqual(PM3.em410xID(in: em410xSearch), "2026082506")
    }

    func testEM410xIDIsNilWhenNoCardIsPresent() {
        let empty = """
        [=] Session log /Users/user/.proxmark3/logs/log_20260825060101.txt
        [=] Checking for known tags...
        [-] No known 125/134 kHz tags found
        """
        XCTAssertNil(PM3.em410xID(in: empty), "a log filename must not read as a card")
        XCTAssertNil(PM3.parseLF(empty))
    }

    // MARK: HID Prox

    func testParsesHIDProxRawValue() throws {
        let track = try XCTUnwrap(PM3.parseLF(hidProxSearch))
        XCTAssertEqual(track.family, "hid_prox")
        XCTAssertEqual(track.ident, "000000000000002004d2162e")
        XCTAssertEqual(track.familyLabel, "HID Prox")
        XCTAssertTrue(track.cloneable)
    }

    func testHIDProxPrefersTheRawValueOverTheFormatGuesses() {
        // FC 203 / CN 15385 and the other decodings must not become the identity.
        let id = PM3.hidProxRawID(in: hidProxSearch)
        XCTAssertEqual(id, "000000000000002004d2162e")
    }

    func testHIDProxIsNilWithoutTheHIDMarker() {
        let indalaOnly = """
        [+] [ind26   ] Indala 26-bit  FC: 3251  CN: 3097
        [=] raw: 000000000000002004d2162e
        """
        XCTAssertNil(PM3.hidProxRawID(in: indalaOnly),
                     "a raw line alone is not proof the card is HID Prox")
    }

    // MARK: manual entry

    func testHIDProxTrackAcceptsAPastedRawValue() throws {
        let track = try XCTUnwrap(PM3.hidProxTrack(fromRaw: "0000000000000010ABCDEF01"))
        XCTAssertEqual(track.ident, "0000000000000010abcdef01", "stored lowercase, as pm3 prints it")
    }

    func testHIDProxTrackRejectsBadInput() {
        XCTAssertNil(PM3.hidProxTrack(fromRaw: "abc"), "too short")
        XCTAssertNil(PM3.hidProxTrack(fromRaw: "0000000"), "odd number of digits")
        XCTAssertNil(PM3.hidProxTrack(fromRaw: String(repeating: "a", count: 26)), "too long")
    }

    func testEM410xTrackStillRequiresTenHexDigits() {
        XCTAssertNotNil(PM3.em410xTrack(fromSerial: "9F8E7D6C5B"))
        XCTAssertNil(PM3.em410xTrack(fromSerial: "6C0057F6"))
    }
}
