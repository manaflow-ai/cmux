import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CommandPaletteBrowserHistoryActionTests {
    @Test func destructiveHistoryActionDeclaresRequiredBooleanForce() throws {
        #expect(ContentView.commandPaletteBrowserHistoryClearArguments.count == 1)
        let argument = try #require(ContentView.commandPaletteBrowserHistoryClearArguments.first)

        #expect(argument.name == "force")
        #expect(argument.valueType == .boolean)
        #expect(argument.required)
    }

    @Test func browserHistoryAutomationRequiresExplicitTrue() {
        #expect(!ContentView.commandPaletteShouldClearBrowserHistory(
            CmuxActionInvocation(source: .automation)
        ))
        #expect(!ContentView.commandPaletteShouldClearBrowserHistory(
            CmuxActionInvocation(source: .automation, arguments: ["force": "false"])
        ))
        #expect(ContentView.commandPaletteShouldClearBrowserHistory(
            CmuxActionInvocation(source: .automation, arguments: ["force": "true"])
        ))
        #expect(ContentView.commandPaletteShouldClearBrowserHistory(
            CmuxActionInvocation(source: .commandPalette)
        ))
    }
}
