import XCTest
@testable import pm3kit

final class PM3RunCLITests: XCTestCase {

    func testRunCLIReturnsOutputOfAWellBehavedBinary() {
        let output = PM3.runCLI("/bin/echo", ["ignored"], timeout: 10)
        XCTAssertTrue(output.contains("-c"), "arguments are passed as -c <command>")
    }

    func testRunCLIReportsABinaryThatDoesNotExist() {
        let output = PM3.runCLI("/nonexistent/pm3", ["hw version"], timeout: 10)
        XCTAssertTrue(output.contains("cannot launch pm3"), output)
    }

    /// Stands in for pm3 with no device attached: prints a line, ignores its
    /// arguments, then never exits.
    private func makeHangingBinary() throws -> String {
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm3-hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho 'Waiting for Proxmark3 to appear...'\nsleep 300\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: script) }
        return script.path
    }

    func testRunCLIStopsACommandThatNeverExits() throws {
        let hangingBinary = try makeHangingBinary()

        let started = Date()
        let output = PM3.runCLI(hangingBinary, ["hw version"], timeout: 2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 20, "the deadline must stop a command that never exits")
        XCTAssertTrue(output.contains("did not finish within 2s"), output)
        XCTAssertTrue(output.contains("not plugged in"), "the message must point at the likely cause")
        XCTAssertTrue(output.contains("Waiting for Proxmark3"),
                      "output produced before the deadline must still reach the log")
    }

    func testTimeoutKillsTheChildProcessNotJustTheWrapper() throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm3-child-\(UUID().uuidString).pid")
        let script = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm3-wrapper-\(UUID().uuidString).sh")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: marker)
        }

        // Stands in for the pm3 bash wrapper launching proxmark3.
        try """
        #!/bin/sh
        sleep 300 &
        echo $! > \(marker.path)
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        _ = PM3.runCLI(script.path, ["hw version"], timeout: 2)

        let recorded = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(pid_t(recorded), "wrapper did not record a child pid")

        var stillAlive = true
        for _ in 0..<40 where stillAlive {
            if kill(childPID, 0) != 0 { stillAlive = false; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(stillAlive, "the grandchild holding the USB port must not be orphaned")
    }

    func testLongCommandsGetALongerDeadlineThanQuickOnes() {
        XCTAssertGreaterThan(PM3.longCommandTimeout, PM3.quickCommandTimeout,
                             "autopwn and restore need longer than a search")
    }
}
