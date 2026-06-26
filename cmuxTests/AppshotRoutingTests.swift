import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for the pure appshot logic: the single-line prompt formatting and
/// the 60-second recency routing decision. The capture itself (ScreenCaptureKit
/// + Accessibility) is integration-only and exercised manually.
///
/// Prompt assertions are locale-neutral (paths, interpolated names, structural
/// invariants, and presence/absence-by-behavior) so they don't depend on the
/// English wording of the localized strings.
@Suite struct AppshotRoutingTests {

    private func capture(
        app: String = "Safari",
        title: String = "Example Window",
        image: String? = nil,
        text: String? = nil,
        screenRecordingDenied: Bool = false,
        accessibilityDenied: Bool = false
    ) -> AppshotCapture {
        AppshotCapture(
            appName: app,
            windowTitle: title,
            imagePath: image,
            textPath: text,
            screenRecordingDenied: screenRecordingDenied,
            accessibilityDenied: accessibilityDenied
        )
    }

    // MARK: - promptText

    @Test func promptReferencesBothFilesWhenImageAndText() throws {
        let prompt = try #require(
            capture(image: "/tmp/cmux-appshots/a.png", text: "/tmp/cmux-appshots/a.txt").promptText()
        )
        #expect(prompt.contains("/tmp/cmux-appshots/a.png"))
        #expect(prompt.contains("/tmp/cmux-appshots/a.txt"))
        #expect(prompt.contains("Safari"))
        #expect(prompt.contains("Example Window"))
        #expect(!prompt.contains("\n"), "prompt must be a single line")
    }

    @Test func promptImageOnlyConditionallyAddsAccessibilityHint() throws {
        // Locale-neutral: the denied variant adds an extra hint, so it differs
        // from and is longer than the granted variant.
        let denied = try #require(capture(image: "/tmp/a.png", text: nil, accessibilityDenied: true).promptText())
        let granted = try #require(capture(image: "/tmp/a.png", text: nil, accessibilityDenied: false).promptText())
        #expect(denied != granted)
        #expect(denied.count > granted.count)
        #expect(denied.contains("/tmp/a.png"))
        #expect(!denied.contains(".txt"))
        #expect(!denied.contains("\n"))
    }

    @Test func promptTextOnlyConditionallyAddsScreenRecordingHint() throws {
        let denied = try #require(capture(image: nil, text: "/tmp/a.txt", screenRecordingDenied: true).promptText())
        let granted = try #require(capture(image: nil, text: "/tmp/a.txt", screenRecordingDenied: false).promptText())
        #expect(denied != granted)
        #expect(denied.count > granted.count)
        #expect(denied.contains("/tmp/a.txt"))
        #expect(!denied.contains("\n"))
    }

    @Test func promptIsNilWhenNothingCaptured() {
        #expect(capture(image: nil, text: nil).promptText() == nil)
    }

    @Test func promptCollapsesMultilineTitleToSingleLine() throws {
        let prompt = try #require(
            capture(title: "Line1\nLine2\nLine3", image: "/tmp/a.png", text: "/tmp/a.txt").promptText()
        )
        #expect(!prompt.contains("\n"))
        #expect(prompt.contains("Line1 Line2 Line3"))
    }

    @Test func promptStripsControlCharactersFromHostileTitle() throws {
        // A hostile window title (e.g. a web page can set its title) must not
        // smuggle a terminal escape sequence into the staged single-line prompt.
        let prompt = try #require(
            capture(title: "Tab\u{1B}[31mEvil\u{07}\u{08}", image: "/tmp/a.png", text: "/tmp/a.txt").promptText()
        )
        #expect(!prompt.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(!prompt.contains("\n"))
        #expect(prompt.contains("/tmp/a.png"))
    }

    @Test func sanitizerStripsShellMetacharactersFromAttackerLabel() {
        // The captured (attacker-influenceable) window/app label is the security
        // boundary: it is sanitized so it can't inject a command — including via
        // history expansion (`!`) — if the staged line is run in a plain shell.
        let sanitized = AppshotCapture.singleLine("$(rm -rf ~) `whoami` !! !$ a;b|c&d>e<f{g}h\\i", max: 500)
        for metacharacter in ["`", "$", ";", "|", "&", "<", ">", "(", ")", "{", "}", "\\", "!"] {
            #expect(!sanitized.contains(metacharacter), "shell metacharacter \(metacharacter) survived sanitization")
        }
        #expect(!sanitized.contains("\n"))
        #expect(sanitized.contains("rm -rf"), "non-metacharacter words should be preserved as context")
    }

    // MARK: - routing

    @Test func routesToLastRouteWithinWindowWhenSurfaceExists() {
        let workspace = UUID()
        let panel = UUID()
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: workspace, panelId: panel, at: now.addingTimeInterval(-30))
        )
        let route = state.resolvedRoute(now: now, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: false)
        #expect(route == .append(workspaceId: workspace, panelId: panel))
    }

    @Test func lastRouteWinsOverInteractiveAgentSoConsecutiveAppshotsStack() {
        let routed = (workspace: UUID(), panel: UUID())
        let interactive = (workspace: UUID(), panel: UUID())
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: routed.workspace, panelId: routed.panel, at: now.addingTimeInterval(-50)),
            lastInteractiveAgent: AppshotAgentRef(workspaceId: interactive.workspace, panelId: interactive.panel, at: now.addingTimeInterval(-1))
        )
        let route = state.resolvedRoute(now: now, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: true)
        #expect(route == .append(workspaceId: routed.workspace, panelId: routed.panel))
    }

    @Test func fallsThroughToInteractiveAgentWhenLastRouteIsStale() {
        let interactive = (workspace: UUID(), panel: UUID())
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: UUID(), panelId: UUID(), at: now.addingTimeInterval(-120)),
            lastInteractiveAgent: AppshotAgentRef(workspaceId: interactive.workspace, panelId: interactive.panel, at: now.addingTimeInterval(-10))
        )
        let route = state.resolvedRoute(now: now, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: true)
        #expect(route == .append(workspaceId: interactive.workspace, panelId: interactive.panel))
    }

    @Test func newThreadWhenEverythingIsStale() {
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: UUID(), panelId: UUID(), at: now.addingTimeInterval(-200)),
            lastInteractiveAgent: AppshotAgentRef(workspaceId: UUID(), panelId: UUID(), at: now.addingTimeInterval(-61))
        )
        let route = state.resolvedRoute(now: now, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: true)
        #expect(route == .newThread)
    }

    @Test func newThreadWhenRecentTargetNoLongerExists() {
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: UUID(), panelId: UUID(), at: now.addingTimeInterval(-5))
        )
        let route = state.resolvedRoute(now: now, lastRouteSurfaceExists: false, lastInteractiveSurfaceExists: false)
        #expect(route == .newThread)
    }

    @Test func newThreadWhenStateIsEmpty() {
        let route = AppshotRoutingState().resolvedRoute(
            now: Date(), lastRouteSurfaceExists: false, lastInteractiveSurfaceExists: false
        )
        #expect(route == .newThread)
    }

    @Test func recencyBoundaryIsInclusive() {
        let workspace = UUID()
        let panel = UUID()
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: workspace, panelId: panel, at: now.addingTimeInterval(-60))
        )
        let route = state.resolvedRoute(now: now, window: 60, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: false)
        #expect(route == .append(workspaceId: workspace, panelId: panel))
    }
}
