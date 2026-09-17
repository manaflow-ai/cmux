import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockSocketLifecycleTests {
    @Test(
        "Dock terminal creation injects input into an interactive shell",
        arguments: ["surface.create", "pane.create"]
    )
    @MainActor
    func dockTerminalCreationInjectsInitialInput(method: String) throws {
        try withDockEnabled {
            try withSocketAppContext { _, _, windowID in
                let initialInput = " printf '  preserved  '\t\r"
                var params: [String: Any] = [
                    "placement": "dock",
                    "type": "terminal",
                    "initial_input": initialInput,
                    "focus": false,
                ]
                if method == "pane.create" {
                    params["direction"] = "right"
                }

                let result = try v2Result(method: method, params: params)
                let surfaceID = try #require(
                    (result["dock_surface_id"] as? String).flatMap(UUID.init(uuidString:))
                )
                let dock = try #require(AppDelegate.shared?.existingWindowDock(forWindowId: windowID))
                let panel = try #require(dock.panels[surfaceID] as? TerminalPanel)
                #expect(panel.surface.debugInitialInputForTesting() == initialInput)
                #expect(panel.surface.debugInitialCommand() == nil)
                #expect(panel.surface.debugWaitAfterCommand() == false)
            }
        }
    }
}
