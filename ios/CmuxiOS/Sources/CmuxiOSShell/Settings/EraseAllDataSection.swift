import CmuxiOSSettingsCore
import SwiftUI

/// The last Settings section: Erase All Data opens the typed confirmation.
struct EraseAllDataSection: View {
    let makeModel: @MainActor () -> EraseAllDataModel?
    @State private var model: EraseAllDataModel?

    var body: some View {
        Section {
            Button(role: .destructive) {
                model = makeModel()
            } label: {
                Label(SettingsText.eraseAllData, systemImage: "trash.slash")
            }
            .accessibilityIdentifier("shell.settings.erase")
        } footer: {
            Text(SettingsText.eraseFooter)
        }
        .sheet(item: Binding(get: { model.map(EraseSheetItem.init) }, set: { if $0 == nil { model = nil } })) { item in
            NavigationStack { EraseAllDataView(model: item.model) }
                .interactiveDismissDisabled(item.model.phase == .erasing)
        }
    }
}

/// Identifies one presentation of the erase sheet.
struct EraseSheetItem: Identifiable {
    let model: EraseAllDataModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
}
