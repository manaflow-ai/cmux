public import CmuxTextConfirmCore
public import SwiftUI

/// Settings > "Confirm risky actions asked by text" (home-messaging.md sections 19 and 21).
public struct TextConfirmSettingsView: View {
    @Bindable var model: TextConfirmSettingsModel

    public init(model: TextConfirmSettingsModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                ForEach(TextConfirmLevel.allCases, id: \.self) { level in
                    Button { model.pick(level) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Self.description(level)).foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if model.state.level == level { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                    }
                    .disabled(!model.state.selectable.contains(level) || model.busy)
                    .accessibilityAddTraits(model.state.level == level ? .isSelected : [])
                }
            } header: {
                Text("textConfirm.title", bundle: .module)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("textConfirm.simSwapRisk", bundle: .module)
                    if let name = model.state.lockedBy {
                        Text(String(localized: "textConfirm.lockedBy", defaultValue: "Locked by {name}", bundle: .module)
                            .replacingOccurrences(of: "{name}", with: name))
                    }
                    if !model.presenceKeyReady { Text("textConfirm.cooldown", bundle: .module) }
                    if let message = model.message { Text(message).foregroundStyle(.red) }
                }
            }
        }
        .alert(Text("textConfirm.raiseTitle", bundle: .module), isPresented: Binding(
            get: { model.pendingLowering != nil }, set: { if !$0 { model.pendingLowering = nil } })) {
            Button(role: .destructive) { model.confirmLowering() } label: { Text("textConfirm.raiseConfirm", bundle: .module) }
            Button(role: .cancel) { model.pendingLowering = nil } label: { Text("textConfirm.cancel", bundle: .module) }
        } message: {
            Text("textConfirm.raiseBody", bundle: .module)
        }
    }

    static func description(_ level: TextConfirmLevel) -> String {
        switch level {
        case .strict: String(localized: "textConfirm.strict", bundle: .module)
        case .destructiveOnly: String(localized: "textConfirm.destructiveOnly", bundle: .module)
        case .off: String(localized: "textConfirm.off", bundle: .module)
        }
    }
}
