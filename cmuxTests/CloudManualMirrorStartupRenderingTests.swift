import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cloud attach replay must survive the short interval before a native pane
/// binds its ``TerminalSurface``. The prompt intentionally has no newline, the
/// same shape as the partial-line report in #3079.
@Suite("Cloud manual mirror startup rendering")
struct CloudManualMirrorStartupRenderingTests {
    @Test @MainActor
    func partialPromptReceivedBeforeSurfaceBindingIsRendered() async throws {
        let fixture = try CloudRestoreReplayFixture(bindSurface: false)
        defer { fixture.close() }

        try await fixture.attachBeforeSurfaceBinding(replay: Data("prompt$ ".utf8))
        try await fixture.deliver(
            Data("ready".utf8), event: "output", marker: "ready", waitForSurface: false
        )
        fixture.bindSurface()
        try await fixture.waitForText("prompt$ ready")
    }
}
