import AppKit
import CMUXMobileSyncCore
import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MobileSyncModelTests: XCTestCase {
    func testSmallestActiveAttachmentWinsByAxis() {
        let terminalID = MobileTerminalID(UUID())
        let workspaceID = MobileWorkspaceID(UUID())
        let wideButShort = attachment(
            id: "ipad",
            workspaceID: workspaceID,
            terminalID: terminalID,
            size: TerminalGridSize(columns: 100, rows: 28)
        )
        let narrowButTall = attachment(
            id: "iphone",
            workspaceID: workspaceID,
            terminalID: terminalID,
            size: TerminalGridSize(columns: 72, rows: 40)
        )

        let decision = TerminalSizeCoordinator.decision(
            fallbackSize: TerminalGridSize(columns: 120, rows: 50),
            attachments: [wideButShort, narrowButTall]
        )

        XCTAssertEqual(decision.effectiveSize, TerminalGridSize(columns: 72, rows: 28))
        XCTAssertEqual(decision.columnSourceAttachmentID, narrowButTall.id)
        XCTAssertEqual(decision.rowSourceAttachmentID, wideButShort.id)
        XCTAssertTrue(decision.isRemotelyConstrained)
    }

    func testInactiveAttachmentsDoNotVote() {
        let terminalID = MobileTerminalID(UUID())
        let workspaceID = MobileWorkspaceID(UUID())
        let inactive = attachment(
            id: "stale",
            workspaceID: workspaceID,
            terminalID: terminalID,
            size: TerminalGridSize(columns: 40, rows: 12),
            isActive: false
        )

        let decision = TerminalSizeCoordinator.decision(
            fallbackSize: TerminalGridSize(columns: 120, rows: 50),
            attachments: [inactive]
        )

        XCTAssertEqual(decision.effectiveSize, TerminalGridSize(columns: 120, rows: 50))
        XCTAssertEqual(decision.activeAttachmentCount, 0)
        XCTAssertFalse(decision.isRemotelyConstrained)
    }

    func testAttachmentStoreRemovalRecomputesSmallestVoteImmediately() async {
        let store = MobileTerminalAttachmentStore()
        let terminalID = MobileTerminalID(UUID())
        let workspaceID = MobileWorkspaceID(UUID())
        let smallest = attachment(
            id: "smallest",
            workspaceID: workspaceID,
            terminalID: terminalID,
            size: TerminalGridSize(columns: 70, rows: 24)
        )
        let next = attachment(
            id: "next",
            workspaceID: workspaceID,
            terminalID: terminalID,
            size: TerminalGridSize(columns: 90, rows: 30)
        )

        await store.upsert(smallest)
        await store.upsert(next)
        var decision = await store.decision(
            for: terminalID,
            fallbackSize: TerminalGridSize(columns: 120, rows: 50)
        )
        XCTAssertEqual(decision.effectiveSize, TerminalGridSize(columns: 70, rows: 24))

        await store.remove(smallest.id)
        decision = await store.decision(
            for: terminalID,
            fallbackSize: TerminalGridSize(columns: 120, rows: 50)
        )
        XCTAssertEqual(decision.effectiveSize, TerminalGridSize(columns: 90, rows: 30))
        XCTAssertEqual(decision.columnSourceAttachmentID, next.id)
        XCTAssertEqual(decision.rowSourceAttachmentID, next.id)
    }

    func testSnapshotsAreCodableAndSendableValueModels() throws {
        let workspaceID = MobileWorkspaceID(UUID())
        let terminal = MobileTerminalSnapshot(
            id: MobileTerminalID(UUID()),
            workspaceID: workspaceID,
            title: "shell",
            currentDirectory: "/tmp",
            isFocused: true,
            displayOrder: 0
        )
        let snapshot = MobileWorkspaceSnapshot(
            id: workspaceID,
            title: "work",
            customTitle: nil,
            description: "description",
            currentDirectory: "/tmp",
            isSelected: true,
            isPinned: false,
            customColor: "#008080",
            terminals: [terminal]
        )

        let encoded = try JSONEncoder().encode(sendableValue(snapshot))
        let decoded = try JSONDecoder().decode(MobileWorkspaceSnapshot.self, from: encoded)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.terminals.first?.workspaceID, workspaceID)
    }

    func testTailscaleDetectionFiltersTailnetAddresses() {
        let addresses = [
            MobileSyncInterfaceAddress(interfaceName: "en0", address: "192.168.0.20", kind: .ipv4),
            MobileSyncInterfaceAddress(interfaceName: "utun4", address: "100.64.0.1", kind: .ipv4),
            MobileSyncInterfaceAddress(interfaceName: "utun5", address: "100.127.255.255", kind: .ipv4),
            MobileSyncInterfaceAddress(interfaceName: "utun6", address: "100.128.0.1", kind: .ipv4),
            MobileSyncInterfaceAddress(interfaceName: "utun7", address: "fd7a:115c:a1e0:abcd::1", kind: .ipv6),
        ]

        let detection = MobileSyncTailscaleDetector.detect(addresses: addresses)

        XCTAssertTrue(detection.isAvailable)
        XCTAssertEqual(detection.addresses.map(\.address), [
            "100.64.0.1",
            "100.127.255.255",
            "fd7a:115c:a1e0:abcd::1",
        ])
        XCTAssertEqual(detection.selectedAddress?.address, "100.64.0.1")
    }

    func testStatusBuilderReportsDisabledStoppedWithoutListener() {
        let status = MobileSyncStatusBuilder.status(
            tabManager: nil,
            settings: MobileSyncSettingsSnapshot(enabled: false),
            tailscale: MobileSyncTailscaleDetection(addresses: [])
        )

        XCTAssertFalse(status.settings.enabled)
        XCTAssertEqual(status.listenerState, .stopped)
        XCTAssertFalse(status.tailscale.isAvailable)
        XCTAssertEqual(status.workspaceCount, 0)
        XCTAssertEqual(status.terminalCount, 0)
        XCTAssertEqual(status.activeAttachmentCount, 0)
        XCTAssertEqual(status.socketPayload["enabled"] as? Bool, false)
    }

    func testMobileSyncServerRespondsToLengthPrefixedPing() throws {
        let server = MobileSyncServer(host: "127.0.0.1") { request in
            [
                "method": request["method"] as? String ?? "",
                "pong": request["method"] as? String == "system.ping",
            ]
        }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let response = try sendMobileSyncRequest(
            port: port,
            request: [
                "id": "ping-1",
                "method": "system.ping",
            ]
        )

        XCTAssertEqual(response["id"] as? String, "ping-1")
        XCTAssertEqual(response["ok"] as? Bool, true)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["method"] as? String, "system.ping")
        XCTAssertEqual(result["pong"] as? Bool, true)
    }

    func testMobileSyncServerReturnsProtocolErrorsAsFailedEnvelopes() throws {
        let server = MobileSyncServer(host: "127.0.0.1") { _ in
            [
                "error": [
                    "code": "not_found",
                    "message": "Terminal not found",
                ],
            ]
        }
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let response = try sendMobileSyncRequest(
            port: port,
            request: [
                "id": "missing-terminal",
                "method": "terminal.snapshot",
            ]
        )

        XCTAssertEqual(response["id"] as? String, "missing-terminal")
        XCTAssertEqual(response["ok"] as? Bool, false)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "not_found")
        XCTAssertEqual(error["message"] as? String, "Terminal not found")
    }

    @MainActor
    func testMobileSyncActionsPersistEnableDisableState() {
        let suiteName = "MobileSyncActionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let unavailableTailscale = MobileSyncTailscaleDetection(addresses: [])
        let enabled = MobileSyncActions.enable(
            tabManager: nil,
            defaults: defaults,
            tailscale: unavailableTailscale
        )

        XCTAssertTrue(enabled.settings.enabled)
        XCTAssertTrue(MobileSyncSettings.snapshot(defaults: defaults).enabled)
        XCTAssertEqual(enabled.listenerState, .waitingForTailscale)

        let disabled = MobileSyncActions.disable(
            tabManager: nil,
            defaults: defaults,
            tailscale: unavailableTailscale
        )

        XCTAssertFalse(disabled.settings.enabled)
        XCTAssertFalse(MobileSyncSettings.snapshot(defaults: defaults).enabled)
        XCTAssertEqual(disabled.listenerState, .stopped)
    }

    @MainActor
    func testMobileSyncActionsPostChangeNotificationOnlyWhenValueChanges() {
        let suiteName = "MobileSyncActionsNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: MobileSyncSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            defaults.removePersistentDomain(forName: suiteName)
        }

        _ = MobileSyncActions.enable(tabManager: nil, defaults: defaults)
        _ = MobileSyncActions.enable(tabManager: nil, defaults: defaults)
        _ = MobileSyncActions.disable(tabManager: nil, defaults: defaults)

        XCTAssertEqual(notificationCount, 2)
    }

    func testOverlayGeometryUsesTopAlignedEffectiveGrid() {
        let snapshot = TerminalSizeOverlaySnapshot(
            localSize: TerminalGridSize(columns: 100, rows: 40),
            effectiveSize: TerminalGridSize(columns: 80, rows: 24),
            surfaceKind: .iPad,
            deviceName: "iPad",
            activeAttachmentCount: 1
        )

        let geometry = TerminalSizeOverlayGeometry.resolve(
            containerSize: CGSize(width: 1000, height: 800),
            cellSize: CGSize(width: 10, height: 20),
            snapshot: snapshot
        )

        XCTAssertTrue(geometry.isVisible)
        XCTAssertEqual(geometry.containerRect, CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(geometry.activeRect, CGRect(x: 0, y: 320, width: 800, height: 480))
    }

    func testOverlayGeometryIsHiddenWhenEffectiveSizeMatchesLocalSize() {
        let snapshot = TerminalSizeOverlaySnapshot(
            localSize: TerminalGridSize(columns: 100, rows: 40),
            effectiveSize: TerminalGridSize(columns: 100, rows: 40),
            surfaceKind: .iPad,
            deviceName: "iPad",
            activeAttachmentCount: 1
        )

        let geometry = TerminalSizeOverlayGeometry.resolve(
            containerSize: CGSize(width: 1000, height: 800),
            cellSize: CGSize(width: 10, height: 20),
            snapshot: snapshot
        )

        XCTAssertFalse(geometry.isVisible)
        XCTAssertEqual(geometry, .hidden)
    }

    func testSnapshotsFromTabManagerContainSelectedWorkspaceAndTerminal() throws {
        _ = NSApplication.shared
        let manager = TabManager()

        let snapshots = MobileWorkspaceSnapshot.snapshots(from: manager)

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.id, MobileWorkspaceID(workspace.id))
        XCTAssertTrue(snapshot.isSelected)
        XCTAssertEqual(snapshot.terminals.count, 1)
        XCTAssertEqual(snapshot.terminals.first?.workspaceID, snapshot.id)
        XCTAssertEqual(snapshot.terminals.first?.id, MobileTerminalID(try XCTUnwrap(workspace.focusedTerminalPanel).id))
    }

    private func attachment(
        id: String,
        workspaceID: MobileWorkspaceID,
        terminalID: MobileTerminalID,
        size: TerminalGridSize,
        isActive: Bool = true
    ) -> TerminalAttachment {
        TerminalAttachment(
            id: MobileAttachmentID(id),
            clientID: MobileClientID("client-\(id)"),
            deviceID: MobileDeviceID("device-\(id)"),
            workspaceID: workspaceID,
            terminalID: terminalID,
            surfaceKind: .iPad,
            gridSize: size,
            isActive: isActive,
            lastHeartbeatAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private nonisolated func sendableValue<T: Sendable>(_ value: T) -> T {
        value
    }

    private nonisolated func sendMobileSyncRequest(
        port: Int,
        request: [String: Any]
    ) throws -> [String: Any] {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw posixError()
        }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw posixError()
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw posixError()
        }

        let requestData = try JSONSerialization.data(withJSONObject: request)
        let frame = try MobileSyncFrameCodec.encodeFrame(requestData)
        try writeAll(frame, to: socketFD)

        let header = try readExact(byteCount: MobileSyncFrameCodec.headerByteCount, from: socketFD)
        let length = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let payload = try readExact(byteCount: Int(length), from: socketFD)
        guard let response = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw NSError(domain: "MobileSyncModelTests", code: 1)
        }
        return response
    }

    private nonisolated func writeAll(_ data: Data, to socketFD: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.send(
                    socketFD,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written,
                    0
                )
                guard result > 0 else {
                    throw posixError()
                }
                written += result
            }
        }
    }

    private nonisolated func readExact(byteCount: Int, from socketFD: Int32) throws -> Data {
        var data = Data()
        while data.count < byteCount {
            var chunk = [UInt8](repeating: 0, count: byteCount - data.count)
            let received = chunk.withUnsafeMutableBytes { buffer in
                Darwin.recv(socketFD, buffer.baseAddress, buffer.count, 0)
            }
            guard received > 0 else {
                throw posixError()
            }
            data.append(contentsOf: chunk.prefix(received))
        }
        return data
    }

    private nonisolated func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
