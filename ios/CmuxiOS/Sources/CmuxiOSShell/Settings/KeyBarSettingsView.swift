import CmuxiOSSettingsCore
import SwiftUI

/// The key bar's keys: reorder or remove the shown keys, add hidden ones,
/// reset to the default bar. At least one key always stays.
struct KeyBarSettingsView: View {
    let store: TerminalPreferencesStore

    var body: some View {
        let shown = store.preferences.keyBarKeys
        let hidden = KeyBarKeyID.allCases.filter { !shown.contains($0) }
        List {
            Section {
                ForEach(shown) { key in
                    Label(SettingsText.title(of: key), systemImage: SettingsText.symbol(of: key))
                }
                .onMove { from, to in store.update { $0.keyBarKeys.move(fromOffsets: from, toOffset: to) } }
                .onDelete { offsets in store.update { $0.keyBarKeys.remove(atOffsets: offsets) } }
                .deleteDisabled(shown.count <= 1)
            } header: {
                Text(SettingsText.keyBarShown)
            } footer: {
                Text(SettingsText.keyBarFooter)
            }
            if !hidden.isEmpty {
                Section(SettingsText.keyBarHidden) {
                    ForEach(hidden) { key in
                        Button {
                            store.update { $0.keyBarKeys.append(key) }
                        } label: {
                            Label(SettingsText.title(of: key), systemImage: SettingsText.symbol(of: key))
                        }
                        .foregroundStyle(.primary)
                        .accessibilityHint(SettingsText.keyBarAddHint)
                    }
                }
            }
            Section {
                Button(SettingsText.keyBarReset) { store.update { $0.keyBarKeys = KeyBarKeyID.defaultOrder } }
                    .disabled(shown == KeyBarKeyID.defaultOrder)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(SettingsText.keyBar)
    }
}
