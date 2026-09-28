import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Create Team sheet presenter")
struct CloudCreateTeamSheetPresenterTests {
    /// Each Cloud surface owns its presenter, and the surface can go away while
    /// its sheet is up, for example when the workspace changes. The sheet has
    /// no close button, so Cancel still has to close it.
    @Test func cancelClosesTheSheetAfterTheSurfaceThatOpenedItIsGone() async throws {
        let flow = try await HostAccountFlow.makeForTeamChangeTests(client: TeamChangeAuthClient())
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        var presenter: CloudCreateTeamSheetPresenter? = CloudCreateTeamSheetPresenter()
        presenter?.present(accountFlow: flow)
        presenter = nil

        let window = try #require(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
                && $0.contentViewController is NSHostingController<CloudCreateTeamSheet>
        })
        defer {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        let sheet = try #require(window.contentViewController as? NSHostingController<CloudCreateTeamSheet>)
        #expect(window.isVisible || window.sheetParent != nil)

        // Cancel's action.
        sheet.rootView.onFinish()
        let deadline = ContinuousClock.now + .seconds(2)
        while window.isVisible || window.sheetParent != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(window.sheetParent == nil, "The sheet stayed attached after Cancel.")
        #expect(!window.isVisible, "The sheet stayed on screen after Cancel.")
    }
}
