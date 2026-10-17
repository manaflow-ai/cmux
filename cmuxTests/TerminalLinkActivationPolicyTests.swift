import AppKit
import CmuxTerminalCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal link activation policy")
struct TerminalLinkActivationPolicyTests {
    @Test("plain clicks remain terminal input")
    func plainClickDoesNotReserveMouseReporting() {
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: 0,
            commandModifierRawValue: NSEvent.ModifierFlags.command.rawValue,
            capsLockModifierRawValue: NSEvent.ModifierFlags.capsLock.rawValue,
            isInsideBounds: true
        ))
    }

    @Test("Command-click reserves the link gesture")
    func commandClickReservesMouseReporting() {
        #expect(TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: NSEvent.ModifierFlags.command.rawValue,
            commandModifierRawValue: NSEvent.ModifierFlags.command.rawValue,
            capsLockModifierRawValue: NSEvent.ModifierFlags.capsLock.rawValue,
            isInsideBounds: true
        ))
    }

    @Test("only the exact Command-click chord is reserved")
    func extraModifiersRemainTerminalInput() {
        let command = NSEvent.ModifierFlags.command.rawValue
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: command | NSEvent.ModifierFlags.shift.rawValue,
            commandModifierRawValue: command,
            capsLockModifierRawValue: NSEvent.ModifierFlags.capsLock.rawValue,
            isInsideBounds: true
        ))
        #expect(!TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: command | NSEvent.ModifierFlags.option.rawValue,
            commandModifierRawValue: command,
            capsLockModifierRawValue: NSEvent.ModifierFlags.capsLock.rawValue,
            isInsideBounds: true
        ))
    }

    @Test("Caps Lock does not change Command-click authorization")
    func capsLockDoesNotChangeCommandClickAuthorization() {
        let command = NSEvent.ModifierFlags.command.rawValue
        let capsLock = NSEvent.ModifierFlags.capsLock.rawValue
        #expect(TerminalLinkActivationPolicy().permitsCommandClick(
            modifierFlagsRawValue: command | capsLock,
            commandModifierRawValue: command,
            capsLockModifierRawValue: capsLock,
            isInsideBounds: true
        ))
    }
}
