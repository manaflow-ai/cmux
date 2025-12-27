import SwiftUI
import Sentry

struct SignInView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var email = ""
    @State private var code = ""
    @State private var showCodeEntry = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Logo
                Image(systemName: "terminal.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("cmux")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Sign in to continue")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if !showCodeEntry {
                    emailEntryView
                } else {
                    codeEntryView
                }

                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Email Entry

    private var emailEntryView: some View {
        VStack(spacing: 16) {
            TextField("Email", text: $email)
                .textFieldStyle(.plain)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await sendCode() }
            } label: {
                if authManager.isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .background(email.isEmpty ? Color.gray : Color.blue)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(email.isEmpty || authManager.isLoading)
        }
    }

    // MARK: - Code Entry

    private var codeEntryView: some View {
        VStack(spacing: 16) {
            Text("Check your email")
                .font(.headline)

            Text("We sent a code to \(email)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("000000", text: $code)
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onChange(of: code) { _, newValue in
                    // Limit to 6 digits
                    if newValue.count > 6 {
                        code = String(newValue.prefix(6))
                    }
                    // Auto-submit when 6 digits entered
                    if newValue.count == 6 {
                        Task { await verifyCode() }
                    }
                }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await verifyCode() }
            } label: {
                if authManager.isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Verify")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .background(code.count == 6 ? Color.blue : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(code.count != 6 || authManager.isLoading)

            Button("Use a different email") {
                withAnimation {
                    showCodeEntry = false
                    code = ""
                    error = nil
                }
            }
            .font(.subheadline)
            .foregroundStyle(.blue)
        }
    }

    // MARK: - Actions

    private func sendCode() async {
        error = nil

        #if DEBUG
        // Dev shortcut: enter "42" to auto-login with test credentials
        if email == "42" {
            do {
                try await authManager.signInWithPassword(email: "l@l.com", password: "abc123")
                return
            } catch let err {
                error = err.localizedDescription
                SentrySDK.capture(error: err)
                return
            }
        }
        #endif

        do {
            try await authManager.sendCode(to: email)
            withAnimation {
                showCodeEntry = true
            }
        } catch let err {
            error = err.localizedDescription
            SentrySDK.capture(error: err)
        }
    }

    private func verifyCode() async {
        error = nil
        do {
            try await authManager.verifyCode(code)
            // Auth state will update automatically via @Published
        } catch let err {
            error = err.localizedDescription
            SentrySDK.capture(error: err)
            code = ""
        }
    }
}

#Preview {
    SignInView()
}
