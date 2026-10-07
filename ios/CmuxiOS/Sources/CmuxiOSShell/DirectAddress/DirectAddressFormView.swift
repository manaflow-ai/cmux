import CmuxiOSFeatureKit
public import SwiftUI

/// The "Add direct address" form (lane B4). Present it in a navigation
/// stack; `onDone` runs after a committed save or on cancel.
public struct DirectAddressFormView: View {
    @Bindable var model: DirectAddressFormModel
    let onDone: @MainActor () -> Void

    public init(model: DirectAddressFormModel, onDone: @escaping @MainActor () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        Form {
            Section {
                TextField(DirectAddressText.name, text: $model.draft.name, prompt: Text(DirectAddressText.namePlaceholder))
                    .accessibilityIdentifier("shell.direct.name")
                TextField(DirectAddressText.address, text: $model.draft.address, prompt: Text(DirectAddressText.addressPlaceholder))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("shell.direct.address")
                TextField(DirectAddressText.port, text: $model.draft.port, prompt: Text(String(DirectAddressDraft.defaultPort)))
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("shell.direct.port")
                TextField(DirectAddressText.hostKey, text: $model.draft.hostKey, prompt: Text(DirectAddressText.hostKeyPlaceholder), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityIdentifier("shell.direct.hostKey")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.visibleIssues, id: \.self) { issue in
                        Text(DirectAddressText.issue(issue)).foregroundStyle(.red)
                    }
                    if let refusal = model.refusal {
                        Text(DirectAddressText.refused(refusal)).foregroundStyle(.red)
                    }
                    Text(DirectAddressText.footer)
                }
            }
        }
        .navigationTitle(DirectAddressText.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(DirectAddressText.cancel, action: onDone)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(DirectAddressText.save) {
                    Task {
                        if await model.save() { onDone() }
                    }
                }
                .disabled(!model.canSave)
                .accessibilityIdentifier("shell.direct.save")
            }
        }
    }
}
