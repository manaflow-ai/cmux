// SPDX-License-Identifier: MIT
//
// Shared reusable in-test terminal fixture (Errata E8).
//
// `TerminalFixture` is the canonical surface area referenced across
// Phase 0 (TerminalController extracts), Phase 1 (GhosttyCellsBridge,
// readText, no-env behavior), and Phase 2 (raw-output round-trip,
// backpressure, cells snapshot). Do not add alternate fixtures in
// other test files — Phase 1/2 tasks consume this file as-is.
//
// The constructor surface is locked here:
//
//   * `makeWithLines(_:)`            — preload printable lines
//   * `makeAltScreen()`              — flip to the alt screen
//   * `makeWithBytes(_:)`            — feed arbitrary bytes
//   * `spawn(command:args:)`         — fork+exec a child PTY
//   * `spawnAndCapturedEnvironment(command:args:)`
//                                    — fork+exec plus capture the env
//                                      the child saw (used by the
//                                      Task 0.25 D9 no-env-leak test)
//   * `fakeRawSource(for:)`          — backing spy for the Phase 2
//                                      raw-output extension
//
// Phase 0 ships these entrypoints; the underlying `MakeFixture` body
// is intentionally a `fatalError` placeholder until Task 0.24.a wires
// the real construction path against the `TerminalController` test
// seams it introduces. Consumers in Phase 0/1/2 must not be invoked
// before that wiring lands.

import AppKit
import CmuxTerminalAccess
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Reusable in-test terminal surface. Constructed off-`MainActor` and
/// drives a real ghostty surface so cell-grid / raw-output / write
/// tests can run without spinning up a full `cmuxApp` instance.
///
/// Errata E8 — the constructor set below is the canonical surface
/// area referenced across Phase 0/1/2. Do not add alternate fixtures
/// in other test files.
public struct TerminalFixture: Sendable {
    /// Live `TerminalPanel` wrapping the fixture's ghostty surface.
    public let panel: TerminalPanel
    /// Stable transport-neutral handle for the fixture's surface.
    public let handle: SurfaceHandle

    /// Preload the surface with the given printable lines joined by
    /// `\n`. Convenience over ``makeWithBytes(_:)``.
    public static func makeWithLines(_ lines: [String]) async throws -> TerminalFixture {
        try await makeWithBytes(Data(lines.joined(separator: "\n").utf8))
    }

    /// Flip the surface to the alt screen (the buffer `vim`/`less` use)
    /// and write a single visible cell so the grid is non-empty.
    public static func makeAltScreen() async throws -> TerminalFixture {
        // ESC[?1049h enters the alt screen; payload "X" so the grid has a cell.
        try await makeWithBytes(Data("\u{1B}[?1049hX".utf8))
    }

    /// Feed arbitrary bytes into a freshly-allocated surface. The
    /// surface is not attached to any real PTY — bytes are written
    /// directly into ghostty's input pipeline.
    public static func makeWithBytes(_ bytes: Data) async throws -> TerminalFixture {
        try await MakeFixture.build(initialBytes: bytes)
    }

    /// Fork+exec a child PTY running `command args...`. The fixture
    /// drives the child for the duration of the test; teardown is
    /// handled by the surface's normal lifecycle.
    public static func spawn(command: String, args: [String]) async throws -> TerminalFixture {
        try await MakeFixture.spawn(command: command, args: args)
    }

    /// Variant of ``spawn(command:args:)`` that also captures the
    /// env dict the child was launched with. Task 0.25 uses this to
    /// assert that the HTTP control bearer token is **not** present
    /// among the env entries (D9 / spec §5.2).
    public static func spawnAndCapturedEnvironment(
        command: String, args: [String]
    ) async throws -> (TerminalFixture, [String: String]) {
        try await MakeFixture.spawnAndCapture(command: command, args: args)
    }

    /// Allocate a ``RawSourceSpy`` keyed by `handle`. Phase 2's
    /// raw-output protocol extension (Task 2.15) tees every written
    /// byte slice into the spy so the test can assert what arrived.
    public func fakeRawSource(for handle: SurfaceHandle) -> RawSourceSpy {
        RawSourceSpy(handle: handle)
    }
}

/// Test-side spy backing the Phase 2 raw-output protocol extension
/// declared in Task 2.15. Records every byte slice the service tees
/// into the spy and exposes them for assertions.
public final class RawSourceSpy: @unchecked Sendable {
    /// Handle the spy is bound to.
    public let handle: SurfaceHandle
    private let lock = NSLock()
    private var slices: [Data] = []

    /// Create a spy for `handle`. Owned by the test, not the bridge.
    public init(handle: SurfaceHandle) { self.handle = handle }

    /// Snapshot of every slice the bridge has pushed so far.
    public func recorded() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return slices
    }

    /// Append a byte slice as observed by the bridge.
    public func push(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        slices.append(data)
    }
}

/// Private construction back-end for ``TerminalFixture``.
///
/// Phase 0 leaves every member as a `fatalError` placeholder; Task
/// 0.24.a replaces them with real construction code that reuses the
/// `#if DEBUG` test seams (`makeForTests`,
/// `spawnHeadlessTerminalForTests`, `feedRawForTests`,
/// `tearDownForTests`, `lastChildEnvForTests`) introduced on
/// ``TerminalController`` in the same task. Until then, every
/// fixture entrypoint traps when invoked — Phase 0's tests that
/// already passed before 0.23a do not call into the fixture, and the
/// Phase 1/2 tests that depend on it land after the real construction
/// path is in place.
private enum MakeFixture {
    static func build(initialBytes: Data) async throws -> TerminalFixture {
        fatalError(
            "TerminalFixture.makeWithBytes is unimplemented in Phase 0; "
            + "Task 0.24.a wires the real construction path."
        )
    }

    static func spawn(command: String, args: [String]) async throws -> TerminalFixture {
        fatalError(
            "TerminalFixture.spawn is unimplemented in Phase 0; "
            + "Task 0.24.a wires the real fork/exec path."
        )
    }

    static func spawnAndCapture(
        command: String, args: [String]
    ) async throws -> (TerminalFixture, [String: String]) {
        fatalError(
            "TerminalFixture.spawnAndCapturedEnvironment is unimplemented "
            + "in Phase 0; Task 0.24.a wires the env-capture seam."
        )
    }
}
