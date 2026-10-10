import CmuxiOSFeatureKit
import SwiftUI
import UIKit

/// A UIKit toolbar button keeps XCTest's `isEnabled` state aligned with the
/// SwiftUI form validation. SwiftUI's toolbar accessibility wrapper can stay
/// enabled even when its Button is disabled on iOS 26.
private struct HostEditorToolbarButton: UIViewRepresentable {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func pressed(_ sender: UIButton) {
            action()
        }
    }

    final class Button: UIButton {
        var desiredEnabled = false {
            didSet { scheduleBarButtonItemSync() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleBarButtonItemSync()
        }

        private func scheduleBarButtonItemSync() {
            DispatchQueue.main.async { [weak self] in self?.syncBarButtonItem() }
        }

        private func syncBarButtonItem() {
            guard let window else { return }
            var controllers: [UIViewController] = []
            collectControllers(from: window.rootViewController, into: &controllers)
            let items = controllers.flatMap { controller in
                (controller.navigationItem.leftBarButtonItems ?? [])
                    + (controller.navigationItem.rightBarButtonItems ?? [])
            }
            guard let item = items.first(where: { item in
                guard let customView = item.customView else { return false }
                return contains(self, in: customView)
            }) else { return }
            item.isEnabled = desiredEnabled
            item.accessibilityIdentifier = "ssh.editor.save"
            item.accessibilityTraits = desiredEnabled ? .button : [.button, .notEnabled]
        }

        private func collectControllers(from controller: UIViewController?, into result: inout [UIViewController]) {
            guard let controller else { return }
            result.append(controller)
            collectControllers(from: controller.presentedViewController, into: &result)
            for child in controller.children {
                collectControllers(from: child, into: &result)
            }
        }

        private func contains(_ target: UIView, in view: UIView) -> Bool {
            view === target || view.subviews.contains { contains(target, in: $0) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = Button(type: .system)
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed(_:)), for: .touchUpInside)
        button.accessibilityIdentifier = "ssh.editor.save"
        button.isEnabled = isEnabled
        button.desiredEnabled = isEnabled
        button.accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.setTitle(title, for: .normal)
        button.isEnabled = isEnabled
        if let button = button as? Button {
            button.desiredEnabled = isEnabled
        }
        button.accessibilityIdentifier = "ssh.editor.save"
        button.accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        context.coordinator.action = action
    }
}

/// The add/edit form for an SSH host (low frequency, so SwiftUI).
struct HostEditorView: View {
    @Bindable var model: HostEditorModel

    var body: some View {
        Form {
            Section(SSHText.server) {
                LabeledContent(SSHText.name) {
                    TextField(SSHText.name, text: $model.name, prompt: Text(verbatim: "devbox"))
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("ssh.editor.name")
                }
                LabeledContent(SSHText.address) {
                    TextField(SSHText.address, text: $model.address, prompt: Text(SSHText.addressPrompt))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ssh.editor.address")
                }
                LabeledContent(SSHText.port) {
                    TextField(SSHText.port, text: $model.port, prompt: Text(verbatim: "22"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("ssh.editor.port")
                }
                LabeledContent(SSHText.user) {
                    TextField(SSHText.user, text: $model.user, prompt: Text(verbatim: "root"))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ssh.editor.user")
                }
            }

            Section {
                Picker(SSHText.method, selection: $model.method) {
                    Text(SSHText.methodKey).tag(HostEditorAuthMethod.key)
                    Text(SSHText.methodPassword).tag(HostEditorAuthMethod.password)
                }
                .pickerStyle(.segmented)
                switch model.method {
                case .key:
                    Picker(SSHText.key, selection: $model.keyID) {
                        Text(SSHText.noKey).tag(UUID?.none)
                        ForEach(model.keys) { key in
                            Text(key.label).tag(UUID?.some(key.id))
                        }
                    }
                    Button(SSHText.generateKey) { Task { await model.generateKey() } }
                        .disabled(model.isWorking)
                    if let key = model.selectedKey {
                        Text(key.fingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        PublicKeyActions(publicKeyLine: key.publicKeyLine)
                    }
                case .password:
                    SecureField(model.hasSavedPassword ? SSHText.passwordSaved : SSHText.password, text: $model.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("ssh.editor.password")
                }
            } header: {
                Text(SSHText.authentication)
            } footer: {
                Text(model.method == .key ? SSHText.keyFooter : SSHText.passwordFooter)
            }

            Section {
                Picker(SSHText.jumpHost, selection: $model.jumpHost) {
                    Text(SSHText.noJumpHost).tag(HostID?.none)
                    ForEach(model.jumpCandidates) { host in
                        Text(host.name).tag(HostID?.some(host.id))
                    }
                }
            } header: {
                Text(SSHText.routing)
            } footer: {
                Text(SSHText.jumpFooter)
            }

            if model.method == .key, model.selectedKey != nil {
                Section {
                    if model.jumpHost == nil {
                        SecureField(SSHText.installPassword, text: $model.installPassword)
                            .textContentType(.password)
                        Button(SSHText.install) { Task { await model.installKey() } }
                            .disabled(!model.canInstall)
                    }
                } header: {
                    Text(SSHText.installKey)
                } footer: {
                    Text(model.jumpHost == nil ? SSHText.installFooter : SSHText.installJumpUnsupported)
                }
            }

            if let message = model.message {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(model.isNew ? SSHText.newHost : SSHText.editHost)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(SSHText.cancel) { model.dismiss?() }
            }
            ToolbarItem(placement: .confirmationAction) {
                let saveEnabled = model.canSave
                HostEditorToolbarButton(title: model.isNew ? SSHText.add : SSHText.save,
                                        isEnabled: saveEnabled) { Task { await model.save() } }
            }
        }
        .task { await model.load() }
    }
}
