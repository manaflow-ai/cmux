import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Create Team sheet presenter", .serialized)
struct CloudCreateTeamSheetPresenterTests {
    /// Each Cloud surface owns its presenter, and the surface can go away while
    /// its sheet is up, for example when the workspace changes. Cancel must
    /// still close it after that owner disappears.
    @Test func cancelClosesTheSheetAfterTheSurfaceThatOpenedItIsGone() async throws {
        let flow = try await HostAccountFlow.makeForTeamChangeTests(client: TeamChangeAuthClient())
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        var presenter: CloudCreateTeamSheetPresenter? = CloudCreateTeamSheetPresenter()
        presenter?.present(accountFlow: flow) { _ in }
        presenter = nil

        let window = try sheetWindow(excluding: existingWindows)
        defer { close(window) }
        let sheet = try #require(window.contentViewController as? NSHostingController<CloudCreateTeamSheet>)
        #expect(window.isVisible || window.sheetParent != nil)

        // Cancel's action.
        sheet.rootView.onCancel()
        try await waitUntilClosed(window)

        #expect(window.sheetParent == nil, "The sheet stayed attached after Cancel.")
        #expect(!window.isVisible, "The sheet stayed on screen after Cancel.")
    }

    /// Create closes the sheet without waiting on the server. Return reaches
    /// both the field's submit and the default button, and only one team is
    /// created.
    @Test func createClosesTheSheetAndForwardsTheNameOnce() async throws {
        let flow = try await HostAccountFlow.makeForTeamChangeTests(client: TeamChangeAuthClient())
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let presenter = CloudCreateTeamSheetPresenter()
        var created: [String] = []
        presenter.present(accountFlow: flow) { created.append($0) }

        let window = try sheetWindow(excluding: existingWindows)
        defer { close(window) }
        let sheet = try #require(window.contentViewController as? NSHostingController<CloudCreateTeamSheet>)
        sheet.rootView.onCreate("Launch Crew")
        sheet.rootView.onCreate("Launch Crew")
        try await waitUntilClosed(window)

        #expect(created == ["Launch Crew"])
        #expect(window.sheetParent == nil, "The sheet stayed attached after Create.")
        #expect(!window.isVisible, "The sheet stayed on screen after Create.")
    }

    @Test func floatingSheetOwnsCloseShortcutAndResetsPresenter() async throws {
        let flow = try await HostAccountFlow.makeForTeamChangeTests(client: TeamChangeAuthClient())
        let presenter = CloudCreateTeamSheetPresenter(resolveHostWindow: { _ in nil })
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        var created: [String] = []
        presenter.present(accountFlow: flow) { created.append($0) }
        let window = try sheetWindow(excluding: existingWindows)
        defer { close(window) }
        let oldSheet = try #require(window.contentViewController as? NSHostingController<CloudCreateTeamSheet>)

        #expect(window.sheetParent == nil, "The regression must exercise the standalone window.")
        #expect(window.isVisible)
        #expect(window.identifier?.rawValue == "cmux.cloudCreateTeam")
        #expect(cmuxWindowShouldOwnCloseShortcut(window))
        window.performClose(nil)
        try await waitUntilClosed(window)
        #expect(window.sheetParent == nil)
        #expect(!window.isVisible)
        oldSheet.rootView.onCreate("Closed Team")
        #expect(created.isEmpty)

        presenter.present(accountFlow: flow) { created.append($0) }
        let reopened = try sheetWindow(excluding: existingWindows.union([ObjectIdentifier(window)]))
        defer { close(reopened) }
        #expect(reopened !== window)
        #expect(reopened.sheetParent == nil)
        #expect(reopened.isVisible)

        // Late actions from the closed session must not dismiss or submit the
        // next presentation.
        oldSheet.rootView.onCancel()
        oldSheet.rootView.onCreate("Stale Team")
        #expect(reopened.isVisible)
        #expect(created.isEmpty)

        let newSheet = try #require(reopened.contentViewController as? NSHostingController<CloudCreateTeamSheet>)
        newSheet.rootView.onCreate("Launch Crew")
        #expect(!reopened.isVisible)
        #expect(created == ["Launch Crew"])
    }

    private func sheetWindow(excluding existingWindows: Set<ObjectIdentifier>) throws -> NSWindow {
        try #require(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
                && $0.contentViewController is NSHostingController<CloudCreateTeamSheet>
        })
    }

    private func waitUntilClosed(_ window: NSWindow) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while window.isVisible || window.sheetParent != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func close(_ window: NSWindow) {
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }
}
