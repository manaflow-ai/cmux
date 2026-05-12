import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PortScannerProcessCaptureTests: XCTestCase {
    private func openFDCount() -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    func testCaptureStandardOutputDoesNotLeakPipeFDs() throws {
        guard let baseline = openFDCount() else {
            throw XCTSkip("Unable to inspect /dev/fd on this runner")
        }

        var maxCount = baseline
        for _ in 0..<200 {
            let output = PortScanner.captureStandardOutput(
                executablePath: "/usr/bin/printf",
                arguments: ["cmux"]
            )
            XCTAssertEqual(output, "cmux")
            if let current = openFDCount() {
                maxCount = max(maxCount, current)
            }
        }

        guard let finalCount = openFDCount() else {
            throw XCTSkip("Unable to inspect final /dev/fd count on this runner")
        }

        XCTAssertLessThanOrEqual(maxCount - baseline, 8)
        XCTAssertLessThanOrEqual(finalCount - baseline, 8)
    }

    func testProcessScannerFindsCurrentProcessParent() throws {
        let parentByPid = ProcessScanner.parentByPid()
        let currentPID = Int(getpid())
        let currentParentPID = Int(getppid())

        XCTAssertEqual(parentByPid[currentPID], currentParentPID)
    }

    func testProcessScannerFindsListeningTCPPortForCurrentProcess() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw XCTSkip("Unable to create TCP socket")
        }
        defer { close(socketFD) }

        var reuse: Int32 = 1
        XCTAssertEqual(
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuse,
                socklen_t(MemoryLayout.size(ofValue: reuse))
            ),
            0
        )

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(socketFD, 4), 0)

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(socketFD, sockaddrPtr, &boundLen)
            }
        }
        XCTAssertEqual(nameResult, 0)

        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        XCTAssertGreaterThan(port, 0)

        let portsByPID = ProcessScanner.listeningTCPPorts(forPIDs: [Int(getpid())])
        XCTAssertTrue(
            portsByPID[Int(getpid()), default: []].contains(port),
            "Expected ProcessScanner to find current test process listening on \(port); got \(portsByPID)"
        )
    }
}
