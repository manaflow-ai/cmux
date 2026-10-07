import CmuxiOSSettingsCore
import SwiftUI

/// Chooses the active team. The owner persists the choice first; the picker
/// shows the owner's value and is disabled while a switch runs.
struct TeamPicker: View {
    let model: AccountSettingsModel

    var body: some View {
        Picker(selection: selection) {
            ForEach(model.snapshot.teams) { team in
                Text(team.name).tag(Optional(team.id))
            }
        } label: {
            HStack {
                Label(SettingsText.team, systemImage: "person.2")
                if model.snapshot.isChangingTeam {
                    ProgressView()
                        .accessibilityLabel(SettingsText.teamChanging)
                }
            }
        }
        .disabled(model.snapshot.isChangingTeam)
        .accessibilityIdentifier("shell.settings.team")
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.snapshot.selectedTeamID },
            set: { id in
                guard let id else { return }
                Task { await model.selectTeam(id) }
            }
        )
    }
}
