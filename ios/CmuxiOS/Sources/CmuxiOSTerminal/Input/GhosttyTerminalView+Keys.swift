import UIKit

/// The hardware keyboard (ghostty-next section 5, KB2): Ctrl, Alt (as Meta)
/// and special keys go to Ghostty's encoder with their physical key; plain
/// printable keys go to the text system so input methods keep working.
/// Navigation keys are repeatable key commands, because UIKit repeats a held
/// key for key commands and the text system, never for `pressesBegan`.
extension GhosttyTerminalView {
    /// Keys and modifier sets the navigation key commands cover.
    private static let navigationInputs: [(input: String, usage: UInt16)] = [
        (UIKeyCommand.inputUpArrow, TerminalHIDUsage.up), (UIKeyCommand.inputDownArrow, TerminalHIDUsage.down),
        (UIKeyCommand.inputLeftArrow, TerminalHIDUsage.left), (UIKeyCommand.inputRightArrow, TerminalHIDUsage.right),
        (UIKeyCommand.inputHome, TerminalHIDUsage.home), (UIKeyCommand.inputEnd, TerminalHIDUsage.end),
        (UIKeyCommand.inputPageUp, TerminalHIDUsage.pageUp), (UIKeyCommand.inputPageDown, TerminalHIDUsage.pageDown),
        (UIKeyCommand.inputDelete, TerminalHIDUsage.forwardDelete),
    ]

    private static let navigationModifierSets: [UIKeyModifierFlags] = {
        let base: [UIKeyModifierFlags] = [.shift, .control, .alternate]
        return (0..<8).map { bits in
            base.enumerated().reduce(into: UIKeyModifierFlags()) { flags, item in
                if bits & (1 << item.offset) != 0 { flags.insert(item.element) }
            }
        }
    }()

    static func isNavigation(_ usage: UInt16) -> Bool {
        navigationInputs.contains { $0.usage == usage }
    }

    /// The navigation key commands (none while an input method composes).
    func navigationKeyCommands() -> [UIKeyCommand]? {
        guard input.markedText == nil else { return nil }
        return Self.navigationInputs.flatMap { entry in
            Self.navigationModifierSets.map { flags in
                let command = UIKeyCommand(input: entry.input, modifierFlags: flags, action: #selector(navigationKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                command.repeatBehavior = .repeatable
                return command
            }
        }
    }

    @objc private func navigationKey(_ command: UIKeyCommand) {
        guard let usage = Self.navigationInputs.first(where: { $0.input == command.input })?.usage else { return }
        var mods = TerminalKeyMods(command.modifierFlags)
        let sticky = input.sticky.consume()
        if sticky.control { mods.insert(.control) }
        if sticky.alternate { mods.insert(.alternate) }
        let event = TerminalKeyEvent(keyCode: TerminalHIDUsage.ghosttyKeyCode(usage), mods: mods)
        perform([.key(event), .key(event.released)])
    }

    /// Sends the presses the router handles; returns the ones for UIKit.
    func beginPresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            let usage = UInt16(truncatingIfNeeded: key.keyCode.rawValue)
            // Navigation keys arrive through their key commands.
            if Self.isNavigation(usage) { continue }
            switch input.pressBegan(usage: usage, mods: TerminalKeyMods(key.modifierFlags), characters: key.characters,
                                    unmodified: key.charactersIgnoringModifiers) {
            case .system:
                unhandled.insert(press)
            case .handled(let actions):
                handledPresses[ObjectIdentifier(press)] = actions
                perform(actions)
            }
        }
        return unhandled
    }

    /// Sends the releases of presses the router handled; returns the others.
    func endPresses(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let actions = handledPresses.removeValue(forKey: ObjectIdentifier(press)) {
                perform(input.pressEnded(actions))
            } else if let key = press.key, Self.isNavigation(UInt16(truncatingIfNeeded: key.keyCode.rawValue)) {
                continue
            } else {
                unhandled.insert(press)
            }
        }
        return unhandled
    }
}
