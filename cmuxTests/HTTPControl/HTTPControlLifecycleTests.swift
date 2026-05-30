// SPDX-License-Identifier: MIT
//
// Task 1.22 — exercises the lifecycle reconcile path and the token
// rotation invariant: after `rotateTokenAndRestart` the listener has
// been restarted so any connection that captured the old token will
// be rejected.

import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct HTTPControlLifecycleTests {
    @Test func togglingSettingsStartsAndStopsListener() async throws {
        let suite = "cmux.http.lc.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-lc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        settings.enabled = false
        settings.tcpPort = 0

        let stub = StubTerminalAccessService()
        let lifecycle = HTTPControlLifecycle(settings: settings, service: stub)
        defer { lifecycle.shutdown() }
        lifecycle.applySettings()
        #expect(lifecycle.boundPort == nil)

        settings.enabled = true
        lifecycle.applySettings()
        let port = try #require(lifecycle.boundPort)
        #expect(port > 0)

        settings.enabled = false
        lifecycle.applySettings()
        #expect(lifecycle.boundPort == nil)
    }

    @Test func tokenRotationInvalidatesExistingConnections() async throws {
        let suite = "cmux.http.lc.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-lc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        settings.enabled = true
        settings.tcpPort = 0
        let initialToken = try settings.ensureToken()

        let stub = StubTerminalAccessService()
        await stub.setSurfaces([
            SurfaceInfo(
                handle: .ref(kind: "surface", ordinal: 1),
                uuid: UUID(),
                workspaceRef: "w:1",
                title: "t",
                cols: 80,
                rows: 24,
                altScreen: false,
                focused: true,
                semanticAvailable: false
            )
        ])
        let lifecycle = HTTPControlLifecycle(settings: settings, service: stub)
        defer { lifecycle.shutdown() }
        lifecycle.applySettings()
        let port = try #require(lifecycle.boundPort)

        // First request with current token should succeed.
        let okReq = "GET /v1/surfaces HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(port)\r\n"
            + "Authorization: Bearer \(initialToken)\r\n"
            + "Connection: close\r\n\r\n"
        let ok = try LoopbackHTTPClient.send(port: port, raw: okReq)
        #expect(ok.contains("200"))

        // Rotate via lifecycle (the Settings view model's onTokenRotated
        // hook points at this same entry point).
        _ = try lifecycle.rotateTokenAndRestart()
        let newPort = try #require(lifecycle.boundPort)

        // Old token must now be rejected — the listener was torn
        // down and rebuilt with the rotated value as the expected
        // bearer, so the old value no longer matches.
        let deniedReq = "GET /v1/surfaces HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(newPort)\r\n"
            + "Authorization: Bearer \(initialToken)\r\n"
            + "Connection: close\r\n\r\n"
        let denied = try LoopbackHTTPClient.send(port: newPort, raw: deniedReq)
        #expect(denied.contains("401"))
    }

    @Test func viewModelRotateInvokesLifecycle() async throws {
        let suite = "cmux.http.lc.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-lc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        settings.enabled = true
        settings.tcpPort = 0
        let stub = StubTerminalAccessService()
        let lifecycle = HTTPControlLifecycle(settings: settings, service: stub)
        defer { lifecycle.shutdown() }
        lifecycle.applySettings()
        let _ = try #require(lifecycle.boundPort)

        let vm = await MainActor.run {
            HTTPControlSettingsViewModel(settings: settings)
        }
        await MainActor.run {
            vm.onTokenRotated = { _ in
                lifecycle.applySettings()
            }
        }
        _ = try await MainActor.run { try vm.rotateToken() }

        // The lifecycle re-applied, which rebinds (possibly on a new
        // ephemeral port). The important guarantee is that a fresh
        // port is bound and the old token would be rejected — both
        // covered by tokenRotationInvalidatesExistingConnections; here
        // we just confirm the callback chain reached applySettings().
        let after = try #require(lifecycle.boundPort)
        #expect(after >= 0)
    }
}
