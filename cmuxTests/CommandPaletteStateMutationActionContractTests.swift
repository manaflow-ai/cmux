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
@Suite("State mutation command palette action contracts")
struct CommandPaletteStateMutationActionContractTests {
    @Test("Toggle actions declare optional Boolean setters")
    func toggleActionsDeclareOptionalBooleanSetters() throws {
        let contracts: [([CmuxActionArgumentDefinition], String)] = [
            (ContentView.commandPaletteSidebarVisibilityArguments, "visible"),
            (ContentView.commandPaletteEnabledToggleArguments, "enabled"),
            (ContentView.commandPalettePinnedToggleArguments, "pinned"),
            (ContentView.commandPaletteUnreadToggleArguments, "unread"),
        ]

        for (arguments, expectedName) in contracts {
            let argument = try #require(arguments.first)
            #expect(arguments.count == 1)
            #expect(argument.name == expectedName)
            #expect(argument.valueType == .boolean)
            #expect(!argument.required)
        }
    }

    @Test("Omitted values toggle while explicit values are idempotent")
    func toggleValueResolutionPreservesInteractiveBehavior() {
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(source: .commandPalette),
            argumentName: "enabled",
            currentValue: false
        ) == true)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(source: .automation),
            argumentName: "enabled",
            currentValue: true
        ) == false)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            ),
            argumentName: "enabled",
            currentValue: true
        ) == true)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "false"]
            ),
            argumentName: "enabled",
            currentValue: false
        ) == false)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "maybe"]
            ),
            argumentName: "enabled",
            currentValue: false
        ) == nil)
    }
}
