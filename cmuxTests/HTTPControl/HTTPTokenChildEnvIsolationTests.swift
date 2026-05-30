// SPDX-License-Identifier: MIT
//
// Task 1.17 / D9 — the HTTP control bearer token must NEVER end up in
// a spawned terminal child's environment. The token lives in
// <supportDirectory>/http-control-token (mode 0600) and is read only
// by the HTTP listener.
//
// This test is the behavioral regression guard for the comment-only
// invariant in ``AppSurfaceProvider``: if any future change copies the
// token (or a value derived from ``HTTPControlSettings``) into the
// env dict passed to fork/exec, this test will fail.
//
// Phase 0 deferred Task 0.24a, so the canonical ``TerminalFixture``
// `spawnAndCapturedEnvironment` entry point is still a placeholder.
// Until that lands, we exercise the same invariant directly: create
// the HTTPControlSettings token, fork+exec `/usr/bin/env` ourselves
// with the **current** process environment (which is what a
// `TerminalController.spawn` call would inherit when the token is
// kept out of the env dict by construction), and assert the child's
// stdout never mentions the token.
//
// When Task 0.24a wires `TerminalFixture.spawnAndCapturedEnvironment`,
// this test should be migrated to call into the shared fixture so it
// also exercises the controller's env-build path.

import Foundation
import Testing
@testable import cmux

@Suite struct HTTPTokenChildEnvIsolationTests {
    @Test func tokenAbsentFromSpawnedChildEnvironment() throws {
        // Configure HTTP control with a unique, recognisable token.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suiteName = "cmux.http.env.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        let token = try settings.ensureToken()
        // Token must be non-empty and unique to this run.
        #expect(token.count > 16)

        // Sanity: the token file lives on disk at 0600; the env path
        // is the only way it could leak into a child.
        let attrs = try FileManager.default.attributesOfItem(
            atPath: settings.tokenFilePath.path
        )
        #expect((attrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

        // Spawn `/usr/bin/env` with the current process environment.
        // If any code path under HTTPControlSettings or the singleton
        // AppSurfaceProvider had exported the token via setenv or
        // similar (it must not — see D9 comment block in
        // ``AppSurfaceProvider``), the child's stdout would contain
        // the token string verbatim.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let envText = String(decoding: data, as: UTF8.self)

        // D9: no env entry whose VALUE matches the token must exist.
        #expect(
            !envText.contains(token),
            "HTTP token leaked into child env: token=\(token.prefix(6))…"
        )
        // D9: no env entry whose NAME starts with CMUX_HTTP_TOKEN
        // (the canonical leak shape we forbid) must exist.
        #expect(!envText.contains("CMUX_HTTP_TOKEN="))
        // Defensive: nothing with the obvious "http-control-token"
        // sentinel either.
        #expect(!envText.contains("HTTP_CONTROL_TOKEN="))
    }
}
