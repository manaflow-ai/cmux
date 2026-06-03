#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

/// Editor for the terminal input-accessory shortcut bar: toggle which shortcuts
/// appear and drag to reorder them. The modifier keys (⌃ ⌥ ⌘) and zoom controls
/// are structural and not listed here. Backed by ``TerminalAccessoryConfiguration``,
/// so edits apply to the live bar immediately.
struct TerminalShortcutsSettingsView: View {
    private var configuration: TerminalAccessoryConfiguration { .shared }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(configuration.displayOrder, id: \.self) { action in
                        Toggle(isOn: binding(for: action)) {
                            Text(action.settingsDisplayName)
                        }
                        .accessibilityIdentifier("TerminalShortcutToggle.\(action.rawValue)")
                    }
                    .onMove { configuration.moveActions(from: $0, to: $1) }
                } header: {
                    Text(L10n.string("mobile.shortcuts.header", defaultValue: "Shortcut Buttons"))
                } footer: {
                    Text(L10n.string(
                        "mobile.shortcuts.footer",
                        defaultValue: "Choose which shortcuts appear on the terminal keyboard bar, and drag to reorder them. The modifier keys and zoom controls are always shown."
                    ))
                }

                Section {
                    Button(role: .destructive) {
                        configuration.resetToDefaults()
                    } label: {
                        Text(L10n.string("mobile.shortcuts.reset", defaultValue: "Reset to Defaults"))
                    }
                    .accessibilityIdentifier("TerminalShortcutsResetButton")
                }
            }
            .navigationTitle(L10n.string("mobile.shortcuts.title", defaultValue: "Terminal Shortcuts"))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .accessibilityIdentifier("TerminalShortcutsEditButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("TerminalShortcutsDoneButton")
                }
            }
        }
    }

    private func binding(for action: TerminalInputAccessoryAction) -> Binding<Bool> {
        Binding(
            get: { configuration.isEnabled(action) },
            set: { configuration.setEnabled(action, $0) }
        )
    }
}
#endif
