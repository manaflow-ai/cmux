import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal search navigation")
struct TerminalSearchNavigationTests {
    @Test("Find Next and Find Previous dispatch Ghostty navigation actions")
    func findCommandsDispatchNavigationActions() {
        var dispatchedActions: [String] = []

        for direction in TerminalSearchNavigation.allCases {
            let performed = direction.perform { action in
                dispatchedActions.append(action)
                return true
            }
            #expect(performed)
        }

        #expect(dispatchedActions == [
            "navigate_search:next",
            "navigate_search:previous",
        ])
        #expect(dispatchedActions.allSatisfy { !$0.hasPrefix("search:") })
    }
}
