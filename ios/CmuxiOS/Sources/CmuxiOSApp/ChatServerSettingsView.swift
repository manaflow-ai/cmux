import SwiftUI

/// The Chat Server settings sheet (a grouped form, HIG "Settings" and
/// "Pickers"): cmux Cloud or Self-Hosted, and for a self-hosted server its
/// tailnet address with a reminder that the Tailscale app must be connected.
struct ChatServerSettingsView: View {
    @Bindable var model: ChatServerSettingsModel
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section {
                Picker(selection: $model.mode) {
                    Text(String(localized: "settings.chatServer.hosted", defaultValue: "cmux Cloud", bundle: .module))
                        .tag(ChatServerSettingsModel.Mode.hosted)
                    Text(String(localized: "settings.chatServer.selfHosted", defaultValue: "Self-Hosted", bundle: .module))
                        .tag(ChatServerSettingsModel.Mode.selfHosted)
                } label: {
                    Text(String(localized: "settings.chatServer.title", defaultValue: "Chat Server", bundle: .module))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                if model.mode == .hosted {
                    Text(String(localized: "settings.chatServer.hostedFooter",
                                defaultValue: "Messages go through the cmux cloud with your cmux account.", bundle: .module))
                }
            }
            if model.mode == .selfHosted {
                Section {
                    TextField(String(localized: "settings.chatServer.addressPlaceholder",
                                     defaultValue: "http://mini.tail1234.ts.net:7320", bundle: .module),
                              text: $model.address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text(String(localized: "settings.chatServer.addressHeader", defaultValue: "Server Address", bundle: .module))
                } footer: {
                    if let problem = model.problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text(String(localized: "settings.chatServer.tailscaleFooter",
                                    defaultValue: "Your own cmux chat server on your tailnet. The Tailscale app must be connected on this iPhone.",
                                    bundle: .module))
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings.chatServer.title", defaultValue: "Chat Server", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "settings.chatServer.cancel", defaultValue: "Cancel", bundle: .module), action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "settings.chatServer.save", defaultValue: "Save", bundle: .module), action: save)
            }
        }
    }

    private func save() {
        if model.save() { onDone() }
    }
}
