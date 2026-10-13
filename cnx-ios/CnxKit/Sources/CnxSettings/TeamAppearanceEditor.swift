#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// Team color and icon editor (SPEC 3.4): sheet with a glass X, centered
/// "Team appearance", 72 pt preview, 13 swatches (6 columns, 44 pt), an icon
/// control and a docked "Done". The icon is Automatic (the team's first
/// letter), Custom (one character typed on the system keyboard: a letter,
/// digit, symbol, or an emoji from the globe key's emoji keyboard) or None
/// (color only). Changes apply through `onSave`.
public struct TeamAppearanceEditor: View {
    let team: Team
    let onSave: (TeamAppearance) -> Void
    @State private var appearance: TeamAppearance
    @State private var mode: GlyphMode
    @State private var customText: String
    @FocusState private var customFocused: Bool
    @Environment(\.dismiss) private var dismiss

    enum GlyphMode: String, CaseIterable, Identifiable {
        case automatic, custom, none
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .automatic: "Automatic"
            case .custom: "Custom"
            case .none: "None"
            }
        }
    }

    public init(team: Team, onSave: @escaping (TeamAppearance) -> Void) {
        self.team = team
        self.onSave = onSave
        _appearance = State(initialValue: team.appearance)
        switch team.appearance.glyph {
        case .automatic:
            _mode = State(initialValue: .automatic)
            _customText = State(initialValue: "")
        case .custom(let value):
            _mode = State(initialValue: .custom)
            _customText = State(initialValue: value)
        case .none:
            _mode = State(initialValue: .none)
            _customText = State(initialValue: "")
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    TeamAvatar(name: team.name, colorHex: appearance.colorHex, emoji: appearance.emoji, size: 72)
                        .clipShape(.rect(cornerRadius: 20, style: .continuous))
                        .padding(.top, 12)
                        .animation(theme.motion.snap.animation, value: appearance)
                    iconSection.padding(.top, 20)
                    sectionHeader("Color").padding(.top, 24)
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
                    .padding(.top, 8)
                }
                .padding(.horizontal, theme.metrics.sideMargin)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                PrimaryCapsule("Done") {
                    onSave(appearance)
                    dismiss()
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.bottom, 8)
            }
            .navigationTitle("Team appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(640), .large])
        .cnxNeutralControlTint()
        .cnxSensoryFeedback(.selection, trigger: appearance)
    }

    // MARK: Icon

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Icon")
            VStack(spacing: 0) {
                Picker("Icon", selection: $mode) {
                    ForEach(GlyphMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(12)
                .accessibilityIdentifier("teamAppearance.iconMode")
                if mode == .custom {
                    Divider().padding(.leading, 16)
                    customRow
                        .transition(.opacity)
                }
            }
            .background(theme.colors.surfaceRaised, in: .rect(cornerRadius: theme.metrics.inputRadius, style: .continuous))
            Text(footer)
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(theme.motion.snap.animation, value: mode)
        .onChange(of: mode) { _, newMode in
            applyGlyph()
            customFocused = newMode == .custom
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(theme.type.meta)
            .foregroundStyle(theme.colors.label2)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var customRow: some View {
        HStack(spacing: 12) {
            Text("Character").font(theme.type.rowTitle)
            Spacer()
            TextField("Type one", text: $customText)
                .focused($customFocused)
                .multilineTextAlignment(.trailing)
                .font(customText.isEmpty ? theme.type.rowTitle : .title2)
                .keyboardType(.default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { customFocused = false }
                .frame(maxWidth: 160)
                .accessibilityIdentifier("teamAppearance.character")
                .onChange(of: customText) { old, new in
                    let kept = Self.keptCharacter(old: old, new: new) ?? ""
                    if kept != new { customText = kept }
                    applyGlyph()
                }
        }
        .padding(.horizontal, 16)
        .frame(height: theme.metrics.settingsRowHeight)
    }

    private var footer: LocalizedStringKey {
        switch mode {
        case .automatic: "Shows the first letter of \(team.name)."
        case .custom: "Type any letter, number, symbol, or emoji."
        case .none: "Shows the color only."
        }
    }

    private func applyGlyph() {
        switch mode {
        case .automatic: appearance.glyph = .automatic
        case .none: appearance.glyph = .none
        // An empty custom field previews (and saves) as automatic.
        case .custom: appearance.glyph = customText.isEmpty ? .automatic : .custom(customText)
        }
    }

    /// The one character the field keeps after an edit: the grapheme just
    /// typed (wherever the cursor was), replacing the previous one; nil when
    /// the field was cleared or only whitespace was typed.
    static func keptCharacter(old: String, new: String) -> String? {
        guard new.count > old.count else { return TeamGlyph.character(from: new) }
        let added = new.hasPrefix(old) ? String(new.dropFirst(old.count))
            : new.hasSuffix(old) ? String(new.dropLast(old.count))
            : new
        return TeamGlyph.character(from: added) ?? TeamGlyph.character(from: old)
    }
}
#endif
