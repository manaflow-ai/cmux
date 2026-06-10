import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class TerminalControllerSocketListenerHealthTests: XCTestCase {
    private let transport = SocketTransport()

    @MainActor
    func testStartPreservesRefusedSocketFileWhenLockHasNoReusableMarker() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let path = makeTempSocketPath()
        let listenerFD = try bindUnixSocket(at: path)
        Darwin.close(listenerFD)
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))
        XCTAssertFalse(transport.pathCanBeReclaimedForStartup(path))
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))
        XCTAssertFalse(transport.pathAcceptsConnections(path))
    }

    @MainActor
    func testStartReclaimsTaggedRefusedSocketFileWithoutReusableLockMarker() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let path = "/tmp/cmux-debug-reclaim-\(UUID().uuidString.lowercased()).sock"
        let listenerFD = try bindUnixSocket(at: path)
        Darwin.close(listenerFD)
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )

        XCTAssertTrue(transport.pathAcceptsConnections(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))
    }

    @MainActor
    func testStartReclaimsRefusedSocketFileWhenReusableLockExists() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let path = makeTempSocketPath()
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )
        XCTAssertTrue(transport.pathAcceptsConnections(path))

        TerminalController.shared.stop()
        let listenerFD = try bindUnixSocket(at: path)
        Darwin.close(listenerFD)
        defer {
            unlink(path)
            unlink(path + ".lock")
        }
        XCTAssertTrue(transport.pathCanBeReclaimedForStartup(path))

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )

        XCTAssertTrue(transport.pathAcceptsConnections(path))
    }

    @MainActor
    func testStartRejectsSymlinkedSocketPathLockWithoutTouchingTarget() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let path = makeTempSocketPath()
        let lockPath = path + ".lock"
        let targetPath = path + ".target"
        try "preserve me".write(toFile: targetPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(symlink(targetPath, lockPath), 0)
        defer {
            unlink(path)
            unlink(lockPath)
            unlink(targetPath)
        }

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )

        XCTAssertEqual(
            try String(contentsOfFile: targetPath, encoding: .utf8),
            "preserve me"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    @MainActor
    func testReservedStartupSocketPathFeedsActivePathBeforeListenerStarts() {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let reservedPath = "/tmp/cmux-reserved-startup-\(UUID().uuidString).sock"
        defer {
            unlink(reservedPath)
            unlink(reservedPath + ".lock")
        }
        XCTAssertEqual(TerminalController.shared.reserveStartupSocketPath(reservedPath), reservedPath)

        XCTAssertEqual(
            TerminalController.shared.activeSocketPath(preferredPath: "/tmp/cmux-preferred.sock"),
            reservedPath
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedPath + ".lock"))

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: TerminalController.shared.activeSocketPath(preferredPath: "/tmp/cmux-preferred.sock"),
            accessMode: .allowAll
        )

        XCTAssertTrue(transport.pathAcceptsConnections(reservedPath))
    }

    @MainActor
    func testActiveSocketPathPreservesRunningFallbackPathForSettingsRestart() {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let fallbackPath = makeTempSocketPath()
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: fallbackPath,
            accessMode: .cmuxOnly
        )

        let restartPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.stableDefaultSocketPath
        )
        XCTAssertEqual(restartPath, fallbackPath)

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: restartPath,
            accessMode: .allowAll
        )

        XCTAssertEqual(
            TerminalController.shared.activeSocketPath(
                preferredPath: SocketControlSettings.stableDefaultSocketPath
            ),
            fallbackPath
        )
    }

    @MainActor
    func testReserveStartupSocketPathDoesNotCreateLockWhileListenerRuns() {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let activePath = makeTempSocketPath()
        let reservedPath = makeTempSocketPath()
        defer {
            unlink(activePath)
            unlink(activePath + ".lock")
            unlink(reservedPath)
            unlink(reservedPath + ".lock")
        }

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: activePath,
            accessMode: .allowAll
        )
        XCTAssertTrue(transport.pathAcceptsConnections(activePath))

        XCTAssertEqual(TerminalController.shared.reserveStartupSocketPath(reservedPath), reservedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedPath + ".lock"))
        XCTAssertEqual(
            TerminalController.shared.activeSocketPath(preferredPath: reservedPath),
            activePath
        )
    }

    private func makeTempSocketPath() -> String {
        "/tmp/cmux-socket-health-\(UUID().uuidString).sock"
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(pathBuf, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }

    @MainActor
    func testSocketListenerHealthRecognizesSocketPath() throws {
        let path = makeTempSocketPath()
        let fd = try bindUnixSocket(at: path)
        defer {
            Darwin.close(fd)
            unlink(path)
        }

        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        XCTAssertTrue(health.socketPathExists)
        XCTAssertFalse(health.isHealthy)
    }

    @MainActor
    func testSocketListenerHealthRejectsRegularFile() throws {
        let path = makeTempSocketPath()
        let url = URL(fileURLWithPath: path)
        try "not-a-socket".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        XCTAssertFalse(health.socketPathExists)
        XCTAssertFalse(health.isHealthy)
    }

}
