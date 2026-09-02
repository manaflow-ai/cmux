import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Closing a cloud terminal pane: the stored action decides detach vs kill vs
/// prompt, and only a remembered non-cancel answer writes the setting back.
@Suite
struct CloudTerminalClosePolicyTests {
    @Test func storedActionDecidesWithoutPrompting() {
        #expect(CloudTerminalClosePolicy.resolution(for: .detach) == .detach)
        #expect(CloudTerminalClosePolicy.resolution(for: .kill) == .kill)
        #expect(CloudTerminalClosePolicy.resolution(for: .ask) == .prompt)
    }

    @Test func rememberPersistsOnlyDetachOrKill() {
        #expect(CloudTerminalClosePolicy.actionToRemember(decision: .detach, remember: true) == .detach)
        #expect(CloudTerminalClosePolicy.actionToRemember(decision: .kill, remember: true) == .kill)
        #expect(CloudTerminalClosePolicy.actionToRemember(decision: .cancel, remember: true) == nil)
        #expect(CloudTerminalClosePolicy.actionToRemember(decision: .kill, remember: false) == nil)
    }

    @Test func promptButtonsMapDetachKillCancel() {
        #expect(CloudTerminalClosePolicy.decision(forButtonIndex: 0) == .detach)
        #expect(CloudTerminalClosePolicy.decision(forButtonIndex: 1) == .kill)
        #expect(CloudTerminalClosePolicy.decision(forButtonIndex: 2) == .cancel)
        #expect(CloudTerminalClosePolicy.decision(forButtonIndex: 7) == .cancel)
    }

    @Test func promptNamesOneTerminalAndCountsSeveral() {
        let one = CloudTerminalClosePrompt(terminalNames: ["claude"], machineName: "vivid-newt")
        #expect(one.title.contains("claude"))
        #expect(one.message.contains("vivid-newt"))

        let several = CloudTerminalClosePrompt(terminalNames: ["claude", "bun test", " "], machineName: "vivid-newt")
        #expect(several.title.contains("2"))
        #expect(!several.title.contains("claude"))
        #expect(several.message.contains("vivid-newt"))

        let unnamed = CloudTerminalClosePrompt(terminalNames: ["  "], machineName: "vivid-newt")
        #expect(unnamed.title.contains("terminal"))
    }

    @Test func rememberedChoiceRoundTripsThroughTheStore() {
        let defaults = UserDefaults(suiteName: "CloudTerminalClosePolicyTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = CloudTerminalCloseStore(defaults: defaults)
        #expect(store.action == .ask)
        if let remembered = CloudTerminalClosePolicy.actionToRemember(decision: .kill, remember: true) {
            store.setAction(remembered)
        }
        #expect(CloudTerminalCloseStore(defaults: defaults).action == .kill)
        #expect(CloudTerminalClosePolicy.resolution(for: CloudTerminalCloseStore(defaults: defaults).action) == .kill)
    }
}
