import CmuxiOSFeatureKit
import CmuxiOSOnboardingCore
import SwiftUI

/// Step 9 (optional): add an SSH host record through `HostsStore`.
struct SSHHostStep: View {
    let model: OnboardingModel
    @State private var entry = SSHShortcutEntry()
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingStepScaffold(title: OnboardingText.sshTitle, message: OnboardingText.sshBody) {
            VStack(spacing: 0) {
                field(OnboardingText.hostField, prompt: OnboardingText.hostPrompt, text: $entry.host, keyboard: .URL)
                    .focused($focused)
                Divider().padding(.leading, 14)
                field(OnboardingText.userField, prompt: "", text: $entry.user, keyboard: .asciiCapable)
                Divider().padding(.leading, 14)
                field(OnboardingText.portField, prompt: "22", text: $entry.port, keyboard: .numberPad)
            }
            .background(OnboardingColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let error {
                Text(verbatim: error)
                    .font(.footnote)
                    .foregroundStyle(OnboardingColors.secondaryText)
            }
        } footer: {
            Button(OnboardingText.addHost) { Task { await add() } }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .disabled(entry.draft == nil || saving)
                .accessibilityIdentifier("onboarding.ssh.add")
            Button(OnboardingText.skip) { model.skipStep() }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .accessibilityIdentifier("onboarding.ssh.skip")
        }
    }

    private func field(_ label: String, prompt: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(verbatim: prompt))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }

    private func add() async {
        guard let draft = entry.draft else {
            error = OnboardingText.sshInvalid
            return
        }
        saving = true
        defer { saving = false }
        do {
            switch try await model.dependencies.hosts.add(draft, key: IntentKey()) {
            case .committed:
                focused = false
                model.choose("added")
                model.advance()
            case .refused(_, let reason):
                error = reason
            }
        } catch FeatureSourceError.offline {
            error = OnboardingText.offlineError
        } catch {
            self.error = error.localizedDescription
        }
    }
}
