#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// Team color and emoji editor (SPEC 3.4): medium sheet, glass X, centered
/// "Team appearance", 72 pt preview, 13 swatches (6 columns, 44 pt), emoji row,
/// docked "Done". Changes apply optimistically through `onSave`.
public struct TeamAppearanceEditor: View {
    let team: Team
    let onSave: (TeamAppearance) -> Void
    @State private var appearance: TeamAppearance
    @State private var emojiInput = ""
    @FocusState private var emojiFocused: Bool
    @Environment(\.dismiss) private var dismiss

    public init(team: Team, onSave: @escaping (TeamAppearance) -> Void) {
        self.team = team
        self.onSave = onSave
        _appearance = State(initialValue: team.appearance)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TeamAvatar(name: team.name, colorHex: appearance.colorHex, emoji: appearance.emoji, size: 72)
                    .clipShape(.rect(cornerRadius: 20, style: .continuous))
                    .padding(.top, 12)
                    .animation(theme.motion.snap.animation, value: appearance)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 12), count: 6), spacing: 14) {
                    ForEach(theme.colors.teamPalette) { color in
                        let selected = color.dark.caseInsensitiveCompare(appearance.colorHex) == .orderedSame
                        Button {
                            appearance.colorHex = color.dark
                        } label: {
                            Circle()
                                .fill(color.token)
                                .frame(width: 44, height: 44)
                                .padding(3)
                                .overlay {
                                    Circle().strokeBorder(theme.colors.label, lineWidth: 3).opacity(selected ? 1 : 0)
                                }
                                .frame(width: 50, height: 50)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(color.name))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.top, 24)
                emojiRow.padding(.top, 20)
                Spacer(minLength: 12)
                PrimaryCapsule("Done") {
                    onSave(appearance)
                    dismiss()
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, theme.metrics.sideMargin)
            .navigationTitle("Team appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(600), .large])
        .tint(theme.colors.label.color)
        .cnxSensoryFeedback(.selection, trigger: appearance)
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) {
            switch DemoDirector.shared.command {
            case .editorColor(let hex): appearance.colorHex = hex
            case .editorEmoji(let emoji): appearance.emoji = emoji
            case .editorDone:
                onSave(appearance)
                dismiss()
            default: break
            }
        }
        #endif
    }

    private var emojiRow: some View {
        HStack(spacing: 12) {
            Text("Emoji").font(theme.type.rowTitle)
            Spacer()
            Text(appearance.emoji ?? "None")
                .font(appearance.emoji == nil ? theme.type.rowSubtitle : .title2)
                .foregroundStyle(appearance.emoji == nil ? theme.colors.label2 : theme.colors.label)
            Button("Choose") { emojiFocused = true }
                .font(theme.type.rowTitle.weight(.semibold))
            if appearance.emoji != nil {
                Button("Remove", role: .destructive) { appearance.emoji = nil }
                    .font(theme.type.rowTitle)
            }
            // The system emoji keyboard on a hidden field, restricted to one grapheme.
            TextField("", text: $emojiInput)
                .focused($emojiFocused)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .onChange(of: emojiInput) { _, value in
                    guard let last = value.last else { return }
                    if last.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x2000 }) {
                        appearance.emoji = String(last)
                        emojiFocused = false
                    }
                    emojiInput = ""
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: theme.metrics.settingsRowHeight)
        .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.inputRadius, style: .continuous))
    }
}
#endif
