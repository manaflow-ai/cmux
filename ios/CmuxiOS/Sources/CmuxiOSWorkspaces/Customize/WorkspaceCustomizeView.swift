import SwiftUI

/// The customize sheet (HIG: Sheets, Color): a form with the name, a
/// palette of the Mac's workspace colors and a grid of SF Symbol icons.
struct WorkspaceCustomizeView: View {
    @Bindable var model: WorkspaceCustomizeModel
    @ScaledMetric(relativeTo: .body) private var swatch: CGFloat = 32

    var body: some View {
        Form {
            Section(WorkspacesText.customizeName) {
                TextField(WorkspacesText.renamePlaceholder, text: $model.title)
                    .textInputAutocapitalization(.never)
                    .disabled(!model.canRename)
                    .accessibilityIdentifier("workspaces.customize.name")
            }
            Section(WorkspacesText.customizeColor) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: swatch + 12))], spacing: 12) {
                    colorButton(nil)
                    ForEach(WorkspaceLook.palette, id: \.self) { colorButton($0) }
                }
                .padding(.vertical, 4)
                .disabled(!model.canCustomize)
            }
            Section(WorkspacesText.customizeIcon) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: swatch + 12))], spacing: 12) {
                    iconButton(nil)
                    ForEach(WorkspaceLook.icons, id: \.self) { iconButton($0) }
                }
                .padding(.vertical, 4)
                .disabled(!model.canCustomize)
            }
        }
        .navigationTitle(WorkspacesText.customizeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(WorkspacesText.cancel) { model.cancel?() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(WorkspacesText.save) { model.save?(model) }
                    .disabled(!model.hasChanges)
                    .accessibilityIdentifier("workspaces.customize.save")
            }
        }
    }

    private func colorButton(_ token: String?) -> some View {
        let selected = model.color == token
        return Button {
            model.color = token
        } label: {
            ZStack {
                Circle()
                    .fill(token.flatMap { WorkspaceLook.color($0) }.map { Color(uiColor: $0) } ?? Color(uiColor: .tertiarySystemFill))
                    .frame(width: swatch, height: swatch)
                if token == nil {
                    Image(systemName: "slash.circle").foregroundStyle(.secondary)
                }
                if selected {
                    Circle().strokeBorder(Color.primary, lineWidth: 2).frame(width: swatch + 8, height: swatch + 8)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(token.map(WorkspacesText.colorName) ?? WorkspacesText.customizeNone)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func iconButton(_ name: String?) -> some View {
        let selected = model.icon == name
        let tint = WorkspaceLook.color(model.color).map { Color(uiColor: $0) } ?? Color.accentColor
        return Button {
            model.icon = name
        } label: {
            Image(systemName: name ?? "slash.circle")
                .font(.title3)
                .foregroundStyle(name == nil ? Color.secondary : tint)
                .frame(width: swatch + 8, height: swatch + 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(uiColor: .tertiarySystemFill) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        // A symbol reads its system description; "None" needs a label.
        .accessibilityLabel(name == nil ? Text(WorkspacesText.customizeNone) : Text(Image(systemName: name ?? "")))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
