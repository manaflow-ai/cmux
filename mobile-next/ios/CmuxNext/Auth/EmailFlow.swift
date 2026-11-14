import CNMBackend
import SwiftUI

struct EmailEntryView: View {
    let mode: AuthMode
    @Binding var path: [AuthStep]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var valid: Bool {
        let parts = email.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !email.contains(" ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuthHeader(back: { dismiss() })
            Text(mode == .signUp ? "Create your account" : "Welcome back")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 18)
            Text(mode == .signUp ? "Enter your email. We'll send you a code to confirm it." : "Enter your email to get a sign-in code.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($focused)
                .onSubmit(submit)
                .font(.system(size: 17))
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(error == nil ? Color.clear : CmuxTheme.danger, lineWidth: 1)
                }
                .padding(.top, 28)
                .accessibilityIdentifier("auth.email")

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(CmuxTheme.danger)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()

            PrimaryActionButton(title: "Continue", enabled: valid, busy: busy, action: submit)
                .accessibilityIdentifier("auth.continue")
                .padding(.bottom, 12)
            Text("By continuing you agree to the cmux Terms and Privacy Policy.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.snappy, value: error)
        .onAppear { focused = true }
    }

    private func submit() {
        guard valid, !busy else { return }
        busy = true
        error = nil
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        Task {
            defer { busy = false }
            do {
                try await model.startEmail(address)
                path.append(.code(address, mode))
            } catch let backendError as BackendError where backendError.code == "email_unavailable" {
                error = String(localized: "Email sign-in isn't available yet. Use Continue with Apple.")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct CodeEntryView: View {
    let email: String
    let mode: AuthMode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var shake = 0
    @State private var resendIn = 30
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuthHeader(back: { dismiss() })
            Text("Check your inbox")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 18)
            Text("Enter the 6-digit code we sent to \(Text(email).foregroundStyle(.primary).fontWeight(.medium))")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            CodeBoxes(code: code, focused: focused, failed: error != nil)
                .modifier(ShakeEffect(shakes: CGFloat(shake)))
                .padding(.top, 30)
                .contentShape(.rect)
                .onTapGesture { focused = true }
                .overlay {
                    TextField("", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .opacity(0.02)
                        .accessibilityIdentifier("auth.code")
                        .onChange(of: code) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { code = digits }
                            if error != nil, !digits.isEmpty { error = nil }
                            if digits.count == 6 { verify() }
                        }
                }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(CmuxTheme.danger)
                    .padding(.top, 10)
            }

            Button {
                resend()
            } label: {
                Text(resendIn > 0 ? "Resend code in \(resendIn)s" : "Resend code")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            .disabled(resendIn > 0)
            .foregroundStyle(resendIn > 0 ? .secondary : .primary)
            .padding(.top, 22)

            Spacer()
            PrimaryActionButton(title: "Continue", enabled: code.count == 6, busy: busy, action: verify)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focused = true }
        .task {
            while resendIn > 0 {
                try? await Task.sleep(for: .seconds(1))
                resendIn -= 1
            }
        }
    }

    private func verify() {
        guard code.count == 6, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.verifyEmail(email, code: code)
            } catch {
                self.error = (error as? BackendError)?.code == "invalid_code"
                    ? String(localized: "That code isn't right. Try again.")
                    : error.localizedDescription
                withAnimation(.linear(duration: 0.4)) { shake += 1 }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                code = ""
            }
        }
    }

    private func resend() {
        resendIn = 30
        Task {
            try? await model.startEmail(email)
            while resendIn > 0 {
                try? await Task.sleep(for: .seconds(1))
                resendIn -= 1
            }
        }
    }
}

struct AuthHeader: View {
    let back: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Spacer()
        }
        .padding(.top, 4)
        .padding(.leading, -6)
    }
}

struct CodeBoxes: View {
    let code: String
    let focused: Bool
    let failed: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                let character = index < code.count ? String(code[code.index(code.startIndex, offsetBy: index)]) : ""
                let active = focused && index == min(code.count, 5)
                Text(character)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(failed ? CmuxTheme.danger : (active ? Color.primary : .clear), lineWidth: active || failed ? 1.5 : 0)
                    }
                    .scaleEffect(character.isEmpty ? 1 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: character)
                if index == 2 { Spacer().frame(width: 4) }
            }
        }
    }
}

struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 6), y: 0))
    }
}

struct PrimaryActionButton: View {
    let title: LocalizedStringKey
    let enabled: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().tint(Color(.systemBackground)) } else { Text(title).font(.system(size: 17, weight: .semibold)) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(Color(.systemBackground))
            .background(Color.primary.opacity(enabled ? 1 : 0.25), in: .rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled || busy)
        .animation(.easeOut(duration: 0.15), value: enabled)
    }
}
