import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ProcessScannerTests: XCTestCase {
    func testParentByPidIncludesSelfWithMatchingParent() {
        let mapping = ProcessScanner.parentByPid()
        let selfPid = Int(getpid())
        let selfParent = Int(getppid())

        XCTAssertFalse(mapping.isEmpty, "expected to enumerate at least one process")
        XCTAssertEqual(mapping[selfPid], selfParent,
                       "self pid should map to getppid() result")
    }

    func testPidsByTTYResolvesSelfsControllingTerminal() throws {
        guard let (ttyName, _) = currentTerminalName() else {
            throw XCTSkip("Test runner has no controlling tty; skipping.")
        }
        let mapping = ProcessScanner.pidsByTTY(ttyList: ttyName)
        // We don't assert which specific pid is present — the test runner's
        // own pid may or may not be attached to this tty depending on the
        // harness — only that SOMETHING on that tty is returned.
        XCTAssertFalse(mapping.isEmpty,
                       "expected at least one pid on tty \(ttyName)")
        for (_, resolved) in mapping {
            XCTAssertEqual(resolved, ttyName)
        }
    }

    func testPidsByTTYReturnsEmptyForBogusName() {
        XCTAssertTrue(ProcessScanner.pidsByTTY(ttyList: "ttys-does-not-exist").isEmpty)
        XCTAssertTrue(ProcessScanner.pidsByTTY(ttyList: "").isEmpty)
        XCTAssertTrue(ProcessScanner.pidsByTTY(ttyList: "not a tty").isEmpty)
    }

    func testListeningTCPPortsDetectsBoundSocket() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw XCTSkip("socket() failed; skipping.")
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(sock, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(bindResult != 0, "bind() failed; skipping.")
        try XCTSkipIf(listen(sock, 16) != 0, "listen() failed; skipping.")

        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(sock, raw, &actualLen)
            }
        }
        try XCTSkipIf(getResult != 0, "getsockname() failed; skipping.")

        let expectedPort = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertGreaterThan(expectedPort, 0)

        let selfPid = Int(getpid())
        let ports = ProcessScanner.listeningTCPPorts(forPIDs: [selfPid])
        XCTAssertTrue(ports[selfPid]?.contains(expectedPort) ?? false,
                      "expected libproc to report port \(expectedPort) on self pid \(selfPid); got \(ports)")
    }

    func testListeningTCPPortsIgnoresNonListeningSockets() throws {
        // A plain unbound socket should not produce a listening port entry.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw XCTSkip("socket() failed; skipping.")
        }
        defer { close(sock) }

        let ports = ProcessScanner.listeningTCPPorts(forPIDs: [Int(getpid())])
        // We can't assert the result is empty because the test harness itself
        // may hold listening sockets; just assert that nothing looks like our
        // unbound fd (port 0).
        for (_, set) in ports {
            XCTAssertFalse(set.contains(0))
        }
    }

    // MARK: - Helpers

    /// Returns (basename, fd) for the process's controlling terminal if one
    /// exists. Checks stdin, stdout, stderr.
    private func currentTerminalName() -> (String, Int32)? {
        for fd: Int32 in [0, 1, 2] {
            guard isatty(fd) != 0 else { continue }
            guard let cStr = ttyname(fd) else { continue }
            let path = String(cString: cStr)
            let basename = (path as NSString).lastPathComponent
            if !basename.isEmpty && basename != "not a tty" {
                return (basename, fd)
            }
        }
        return nil
    }
}
