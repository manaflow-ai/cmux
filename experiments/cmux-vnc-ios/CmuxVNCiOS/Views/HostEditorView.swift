import CmuxVNC
import SwiftUI

/// Adds or edits a saved computer.
struct HostEditorView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var host: SavedHost
    @State private var password = ""
    @State private var passwordChanged = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $host.name)
                    TextField("Address", text: $host.address, prompt: Text("mac-mini.local, 100.64.0.5:5901"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if !host.address.isEmpty, VNCEndpoint.parse(host.address) == nil {
                        Text("Use host, host:port, or vnc://host:port.").foregroundStyle(.red)
                    } else if let endpoint = host.endpoint {
                        Text("Connects to \(endpoint.label).")
                    }
                }
                Section {
                    TextField("User name", text: $host.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onChange(of: password) { passwordChanged = true }
                } header: {
                    Text("Sign-in")
                } footer: {
                    Text("A Mac asks for an account on that Mac. Other VNC servers usually ask for a VNC password only. Passwords stay in this iPhone's keychain.")
                }
                Section("Session") {
                    Toggle("Draw cursor on this device", isOn: $host.options.localCursor)
                    Toggle("Show stream stats", isOn: $host.options.showStats)
                }
            }
            .navigationTitle(host.name.isEmpty ? "Computer" : host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.upsert(host, password: passwordChanged ? password : nil)
                        dismiss()
                    }
                    .disabled(host.endpoint == nil)
                }
            }
        }
    }
}
