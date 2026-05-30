// SPDX-License-Identifier: MIT
//
// Task 1.22a / Errata E6 — single locked Phase 1 helper that Phase 2
// SSE / cells / backpressure tests consume.
//
// The constructor surface is LOCKED here:
//
//   * `start(...)`                                      — stub-backed env
//   * `startWithLiveSurface(command:args:ringCapacity:)` — live PTY env
//   * `shutdown()`                                       — teardown
//   * `settings`, `server`, `fixture`, `port`, `token`,
//     `baseURL`, `surfaceHandle`                         — exposed for tests
//
// Phase 2 tasks 2.20–2.32 only USE this helper; they do not redefine
// any of these constructors. Changing the helper signature requires
// updating the Phase 2 plan first.
//
// The boot path for `start(...)` works today against the
// ``StubTerminalAccessService`` so Phase 1's lifecycle / smoke
// tests can run without a live PTY. `startWithLiveSurface` defers
// to ``TerminalFixture/spawn(command:args:)``; that helper is still
// a Phase 0 placeholder (Task 0.24a deferred), so any consumer that
// invokes it today will trap with the placeholder's `fatalError`.
// This is by design — the helper SHIPS in Phase 1 with the locked
// signature so Phase 2's plan can reference the symbol, and the
// fallback path lights up when Task 0.24a lands.

import CmuxTerminalAccess
import Foundation
@testable import cmux

/// Shared HTTP control test environment.
final class HTTPControlTestEnv: @unchecked Sendable {
    /// Persisted settings backing the listener. Created in a per-env
    /// temp directory + unique `UserDefaults` suite so multiple envs
    /// can run concurrently without bleeding state.
    let settings: HTTPControlSettings
    /// Live HTTP server bound to a loopback ephemeral port.
    let server: HTTPControlServer
    /// Optional ``TerminalFixture`` backing the env. `nil` for
    /// stub-only envs created via ``start(...)``.
    let fixture: TerminalFixture?
    /// Surface handle exposed by the env — for stub envs this is the
    /// stub's seeded handle; for live envs the fixture's handle.
    let surfaceHandle: SurfaceHandle
    /// TCP port the server is listening on.
    var port: Int { Int(server.boundPort) }
    /// Bearer token the env's auth was wired to expect.
    let token: String
    /// Loopback HTTP base URL.
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    /// Temp directory the settings were rooted at; removed in
    /// ``shutdown()``.
    let supportDirectory: URL
    /// User defaults instance the settings were bound to.
    let defaults: UserDefaults
    /// `UserDefaults` suite name (used in ``shutdown()`` to remove
    /// the persistent domain).
    let defaultsSuiteName: String

    private init(
        settings: HTTPControlSettings,
        server: HTTPControlServer,
        fixture: TerminalFixture?,
        surfaceHandle: SurfaceHandle,
        token: String,
        supportDirectory: URL,
        defaults: UserDefaults,
        defaultsSuiteName: String
    ) {
        self.settings = settings
        self.server = server
        self.fixture = fixture
        self.surfaceHandle = surfaceHandle
        self.token = token
        self.supportDirectory = supportDirectory
        self.defaults = defaults
        self.defaultsSuiteName = defaultsSuiteName
    }

    /// Boots a stub-backed env: a ``StubTerminalAccessService`` is
    /// pre-seeded with one ``SurfaceInfo``, the HTTP server is
    /// constructed with the same auth + allowlist factory as
    /// production, and ``HTTPControlServer/startTCP(port:)`` is
    /// called with `0` so the kernel picks a free port.
    ///
    /// Phase 2 backpressure / SSE tests pass `ringCapacity` and the
    /// open-burst knobs through this entry point; the parameters
    /// match the locked signature spec'd in plan §1.22a.
    static func start(
        heartbeatSeconds: TimeInterval = 20,
        maxStreamsPerSurface: Int = 8,
        ringCapacity: Int = 512,
        streamOpenBurst: Int = 4,
        streamOpenRefillPerSecond: Double = 1.0
    ) async throws -> HTTPControlTestEnv {
        let stubHandle: SurfaceHandle = .ref(kind: "surface", ordinal: 1)
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([
            SurfaceInfo(
                handle: stubHandle,
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
        let (settings, server, token, supportDir, defaults, suite) = try boot(
            service: stub,
            heartbeat: heartbeatSeconds,
            cap: maxStreamsPerSurface,
            ring: ringCapacity,
            openBurst: streamOpenBurst,
            openRefill: streamOpenRefillPerSecond
        )
        return HTTPControlTestEnv(
            settings: settings,
            server: server,
            fixture: nil,
            surfaceHandle: stubHandle,
            token: token,
            supportDirectory: supportDir,
            defaults: defaults,
            defaultsSuiteName: suite
        )
    }

    /// Boots a live-PTY env: spawns the requested child via
    /// ``TerminalFixture/spawn(command:args:)``, injects the panel
    /// into ``AppSurfaceProvider/shared`` via ``testInject``, and
    /// wires a ``DefaultTerminalAccessService`` over it.
    ///
    /// `TerminalFixture.spawn` is a Phase 0 placeholder until
    /// Task 0.24a lands; calling this entry point before then will
    /// `fatalError` from the fixture body. The signature is shipped
    /// here so Phase 2's plan can already reference it.
    static func startWithLiveSurface(
        command: String,
        args: [String],
        ringCapacity: Int = 512
    ) async throws -> HTTPControlTestEnv {
        let fixture = try await TerminalFixture.spawn(command: command, args: args)
        let handle = fixture.handle
        AppSurfaceProvider.shared.testInject(panel: fixture.panel, handle: handle)
        let service = DefaultTerminalAccessService(
            provider: AppSurfaceProvider.shared,
            audit: NoOpAuditLog()
        )
        let (settings, server, token, supportDir, defaults, suite) = try boot(
            service: service,
            heartbeat: 20,
            cap: 8,
            ring: ringCapacity,
            openBurst: 4,
            openRefill: 1.0
        )
        return HTTPControlTestEnv(
            settings: settings,
            server: server,
            fixture: fixture,
            surfaceHandle: handle,
            token: token,
            supportDirectory: supportDir,
            defaults: defaults,
            defaultsSuiteName: suite
        )
    }

    /// Stops the server, removes the temp support directory, and
    /// purges the unique `UserDefaults` suite. Tests call this in
    /// `defer` blocks.
    func shutdown() async {
        server.stop()
        try? FileManager.default.removeItem(at: supportDirectory)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }

    // MARK: - Boot helpers

    private static func boot(
        service: any TerminalAccessService,
        heartbeat: TimeInterval,
        cap: Int,
        ring: Int,
        openBurst: Int,
        openRefill: Double
    ) throws -> (
        HTTPControlSettings,
        HTTPControlServer,
        String,
        URL,
        UserDefaults,
        String
    ) {
        // `heartbeat`, `cap`, `ring`, `openBurst`, `openRefill` are
        // wired in Phase 2 once the streaming layer ships; they
        // appear in the locked signature today so the helper API is
        // stable for Phase 2 consumers.
        _ = (heartbeat, cap, ring, openBurst, openRefill)

        let suite = "cmux.http.env.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw HTTPControlTestEnvError.userDefaultsSuiteUnavailable
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-http-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let settings = HTTPControlSettings(supportDirectory: dir, defaults: defaults)
        settings.enabled = true
        settings.transport = .tcp
        settings.tcpPort = 0
        let token = try settings.ensureToken()

        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: service)
        HTTPControlRoutes.registerScreenRead(into: &table, service: service)
        HTTPControlRoutes.registerInputWrite(
            into: &table,
            service: service,
            allowRaw: { [settings] in settings.allowRawInput }
        )
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: token),
            hostAllowlistFor: { port in HostAllowlist(port: Int(port)) },
            isEnabled: { [settings] in settings.enabled }
        )
        _ = try server.startTCP(port: 0)
        return (settings, server, token, dir, defaults, suite)
    }
}

/// Failure modes for ``HTTPControlTestEnv``.
enum HTTPControlTestEnvError: Error {
    /// `UserDefaults(suiteName:)` returned nil — likely an invalid
    /// suite name on the running platform.
    case userDefaultsSuiteUnavailable
}
