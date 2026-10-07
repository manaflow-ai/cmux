import CmuxiOSSettingsCore
import CmuxTerminalRenderCore
import SwiftUI

/// Settings > Terminal: theme, font, cursor and key bar of this device, with
/// a live preview. Every change reaches open terminals through the store.
struct TerminalSettingsView: View {
    let store: TerminalPreferencesStore
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                TerminalPreviewView(preferences: store.preferences)
                    .listRowInsets(EdgeInsets())
            } footer: {
                if store.preferences.theme == .matchMac { Text(SettingsText.matchMacFooter) }
            }
            Section(SettingsText.theme) {
                Picker(SettingsText.theme, selection: binding(\.theme)) {
                    ForEach(TerminalThemeChoice.allCases) { choice in
                        Text(SettingsText.title(of: choice)).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("shell.settings.terminal.theme")
            }
            Section {
                Picker(SettingsText.fontFamily, selection: binding(\.font)) {
                    ForEach(TerminalFontChoice.allCases) { font in
                        Text(SettingsText.title(of: font)).tag(font)
                    }
                }
                .accessibilityIdentifier("shell.settings.terminal.font")
                Stepper(value: binding(\.fontSize), in: TerminalPreferences.fontSizeRange, step: 1) {
                    LabeledContent(SettingsText.fontSize, value: SettingsText.points(store.preferences.fontSize))
                }
                .accessibilityValue(SettingsText.points(store.preferences.fontSize))
                .accessibilityIdentifier("shell.settings.terminal.fontSize")
                Toggle(SettingsText.followDynamicType, isOn: binding(\.followsDynamicType))
            } header: {
                Text(SettingsText.font)
            } footer: {
                Text(SettingsText.fontFooter)
            }
            Section(SettingsText.cursor) {
                Picker(SettingsText.cursorShape, selection: binding(\.cursorStyle)) {
                    ForEach(TerminalCursorStyle.allCases, id: \.self) { style in
                        Text(SettingsText.title(of: style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("shell.settings.terminal.cursor")
                Toggle(SettingsText.cursorBlink, isOn: binding(\.cursorBlink))
            }
            Section {
                NavigationLink {
                    KeyBarSettingsView(store: store)
                } label: {
                    LabeledContent(SettingsText.keyBar, value: SettingsText.keyCount(store.preferences.keyBarKeys.count))
                }
                .accessibilityIdentifier("shell.settings.terminal.keyBar")
            }
            Section {
                Toggle(SettingsText.composer, isOn: binding(\.composerEnabled))
                    .accessibilityIdentifier("shell.settings.terminal.composer")
            } footer: {
                Text(SettingsText.composerFooter)
            }
            Section {
                Button(SettingsText.resetTerminal, role: .destructive) { confirmingReset = true }
            }
        }
        .navigationTitle(SettingsText.terminal)
        .confirmationDialog(SettingsText.resetTerminalConfirm, isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(SettingsText.resetTerminal, role: .destructive) { store.reset() }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } }
        )
    }
}
