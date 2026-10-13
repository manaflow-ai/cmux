#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

/// The hamburger sidebar. It only switches Stack Auth teams and invites people.
struct TeamSidebar: View {
    let store: AppStore
    let isOpen: Bool
    let dismiss: () -> Void
    @State private var editingTeam: Team?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Teams")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.teams) { team in
                        TeamRow(team: team, isActive: team.id == store.activeTeamID)
                            .contentShape(.rect)
                            .onTapGesture {
                                store.selectTeam(team.id)
                                dismiss()
                            }
                            .contextMenu {
                                Button("Color and Emoji", systemImage: "paintpalette") { editingTeam = team }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider().padding(.horizontal, 20)
            Button {
                // Wired to POST /v1/teams/:id/invites once the backend link lands.
            } label: {
                Label("Invite to team", systemImage: "person.badge.plus")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .safeAreaPadding(.vertical)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $editingTeam) { team in
            TeamAppearanceEditor(team: team) { store.setAppearance($0, for: team.id) }
                .presentationDetents([.medium])
        }
        .accessibilityHidden(!isOpen)
    }
}

/// A team row: avatar, name, and the Macs-online dots.
struct TeamRow: View {
    let team: Team
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            TeamAvatar(name: team.name, colorHex: team.appearance.colorHex, emoji: team.appearance.emoji, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(team.name).font(.body.weight(isActive ? .semibold : .regular))
                MacDots(team: team)
            }
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.08))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Up to five dots (green online, gray offline) and "+N" for more Macs.
struct MacDots: View {
    let team: Team

    var body: some View {
        let (dots, overflow) = team.macDots()
        HStack(spacing: 4) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, online in
                Circle()
                    .fill(online ? CnxTheme.standard.palette.online : CnxTheme.standard.palette.offline)
                    .frame(width: 7, height: 7)
            }
            if overflow > 0 {
                Text("+\(overflow)").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            if dots.isEmpty {
                Text("No Macs").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("\(team.macs.filter(\.isOnline).count) of \(team.macs.count) Macs online"))
    }
}

/// Pick a team color, or overlay an emoji.
struct TeamAppearanceEditor: View {
    let team: Team
    let onChange: (TeamAppearance) -> Void
    @State private var appearance: TeamAppearance
    @Environment(\.dismiss) private var dismiss

    init(team: Team, onChange: @escaping (TeamAppearance) -> Void) {
        self.team = team
        self.onChange = onChange
        _appearance = State(initialValue: team.appearance)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TeamAvatar(name: team.name, colorHex: appearance.colorHex, emoji: appearance.emoji, size: 72)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                    ForEach(TeamAppearance.palette, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 40, height: 40)
                            .overlay { if hex == appearance.colorHex { Circle().stroke(.primary, lineWidth: 2.5).padding(-4) } }
                            .onTapGesture { appearance.colorHex = hex }
                            .accessibilityLabel(Text(hex))
                    }
                }
                TextField("Emoji (optional)", text: Binding(
                    get: { appearance.emoji ?? "" },
                    set: { appearance.emoji = $0.isEmpty ? nil : String($0.suffix(1)) }
                ))
                .multilineTextAlignment(.center)
                .font(.title2)
            }
            .padding(24)
            .navigationTitle(team.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        onChange(appearance)
                        dismiss()
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: appearance)
    }
}
#endif
