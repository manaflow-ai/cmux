import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit tests for the pure appshot logic: the single-line prompt formatting and
/// the 60-second recency routing decision. The capture itself (ScreenCaptureKit
/// + Accessibility) is integration-only and exercised manually.
final class AppshotRoutingTests: XCTestCase {

    // MARK: - promptText

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

    func testPromptReferencesBothFilesWhenImageAndText() throws {
        let prompt = try XCTUnwrap(
            capture(image: "/tmp/cmux-appshots/a.png", text: "/tmp/cmux-appshots/a.txt").promptText()
        )
        XCTAssertTrue(prompt.contains("/tmp/cmux-appshots/a.png"))
        XCTAssertTrue(prompt.contains("/tmp/cmux-appshots/a.txt"))
        XCTAssertTrue(prompt.contains("Safari"))
        XCTAssertTrue(prompt.contains("Example Window"))
        XCTAssertFalse(prompt.contains("\n"), "prompt must be a single line so a single Return submits it")
    }

    func testPromptImageOnlyShowsAccessibilityHintWhenDenied() throws {
        let prompt = try XCTUnwrap(
            capture(image: "/tmp/a.png", text: nil, accessibilityDenied: true).promptText()
        )
        XCTAssertTrue(prompt.contains("/tmp/a.png"))
        XCTAssertFalse(prompt.contains(".txt"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Accessibility"))
        XCTAssertFalse(prompt.contains("\n"))
    }

    func testPromptImageOnlyOmitsHintWhenAccessibilityWasGranted() throws {
        // Accessibility granted but the app exposed no readable text.
        let prompt = try XCTUnwrap(
            capture(image: "/tmp/a.png", text: nil, accessibilityDenied: false).promptText()
        )
        XCTAssertFalse(prompt.contains("Grant cmux Accessibility"))
    }

    func testPromptTextOnlyShowsScreenRecordingHintWhenDenied() throws {
        let prompt = try XCTUnwrap(
            capture(image: nil, text: "/tmp/a.txt", screenRecordingDenied: true).promptText()
        )
        XCTAssertTrue(prompt.contains("/tmp/a.txt"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Screen Recording"))
        XCTAssertFalse(prompt.contains("\n"))
    }

    func testPromptIsNilWhenNothingCaptured() {
        XCTAssertNil(capture(image: nil, text: nil).promptText())
    }

    func testPromptCollapsesMultilineTitleToSingleLine() throws {
        let prompt = try XCTUnwrap(
            capture(title: "Line1\nLine2\nLine3", image: "/tmp/a.png", text: "/tmp/a.txt").promptText()
        )
        XCTAssertFalse(prompt.contains("\n"))
        XCTAssertTrue(prompt.contains("Line1 Line2 Line3"))
    }

    func testPromptStripsControlCharactersFromHostileTitle() throws {
        // A hostile window title (e.g. a web page can set its title) must not
        // smuggle a terminal escape sequence into the staged single-line prompt.
        let prompt = try XCTUnwrap(
            capture(title: "Tab\u{1B}[31mEvil\u{07}\u{08}", image: "/tmp/a.png", text: "/tmp/a.txt").promptText()
        )
        XCTAssertFalse(prompt.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertFalse(prompt.contains("\n"))
        XCTAssertTrue(prompt.contains("/tmp/a.png"))
    }

    // MARK: - routing

    func testRoutesToLastRouteWithinWindowWhenSurfaceExists() {
        let workspace = UUID()
        let panel = UUID()
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: workspace, panelId: panel, at: now.addingTimeInterval(-30))
        )
        let route = AppshotRouteResolver.resolve(
            now: now, state: state, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: false
        )
        XCTAssertEqual(route, .append(workspaceId: workspace, panelId: panel))
    }

    func testLastRouteWinsOverInteractiveAgentSoConsecutiveAppshotsStack() {
        let routed = (workspace: UUID(), panel: UUID())
        let interactive = (workspace: UUID(), panel: UUID())
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: routed.workspace, panelId: routed.panel, at: now.addingTimeInterval(-50)),
            lastInteractiveAgent: AppshotAgentRef(workspaceId: interactive.workspace, panelId: interactive.panel, at: now.addingTimeInterval(-1))
        )
        let route = AppshotRouteResolver.resolve(
            now: now, state: state, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: true
        )
        XCTAssertEqual(route, .append(workspaceId: routed.workspace, panelId: routed.panel))
    }

    func testFallsThroughToInteractiveAgentWhenLastRouteIsStale() {
        let interactive = (workspace: UUID(), panel: UUID())
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: UUID(), panelId: UUID(), at: now.addingTimeInterval(-120)),
            lastInteractiveAgent: AppshotAgentRef(workspaceId: interactive.workspace, panelId: interactive.panel, at: now.addingTimeInterval(-10))
        )
        let route = AppshotRouteResolver.resolve(
            now: now, state: state, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: true
        )
        XCTAssertEqual(route, .append(workspaceId: interactive.workspace, panelId: interactive.panel))
    }

    func testNewThreadWhenEverythingIsStale() {
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: UUID(), panelId: UUID(), at: now.addingTimeInterval(-200)),
            lastInteractiveAgent: AppshotAgentRef(workspaceId: UUID(), panelId: UUID(), at: now.addingTimeInterval(-61))
        )
        let route = AppshotRouteResolver.resolve(
            now: now, state: state, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: true
        )
        XCTAssertEqual(route, .newThread)
    }

    func testNewThreadWhenRecentTargetNoLongerExists() {
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: UUID(), panelId: UUID(), at: now.addingTimeInterval(-5))
        )
        let route = AppshotRouteResolver.resolve(
            now: now, state: state, lastRouteSurfaceExists: false, lastInteractiveSurfaceExists: false
        )
        XCTAssertEqual(route, .newThread)
    }

    func testNewThreadWhenStateIsEmpty() {
        let route = AppshotRouteResolver.resolve(
            now: Date(), state: AppshotRoutingState(), lastRouteSurfaceExists: false, lastInteractiveSurfaceExists: false
        )
        XCTAssertEqual(route, .newThread)
    }

    func testRecencyBoundaryIsInclusive() {
        let workspace = UUID()
        let panel = UUID()
        let now = Date()
        let state = AppshotRoutingState(
            lastRoute: AppshotAgentRef(workspaceId: workspace, panelId: panel, at: now.addingTimeInterval(-60))
        )
        let route = AppshotRouteResolver.resolve(
            now: now, window: 60, state: state, lastRouteSurfaceExists: true, lastInteractiveSurfaceExists: false
        )
        XCTAssertEqual(route, .append(workspaceId: workspace, panelId: panel))
    }
}
