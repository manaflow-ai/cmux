import AuthenticationServices
import SwiftUI
import VisionKit

/// Launch and sign-in: the cmux mark, one line, Sign in with Apple.
struct SignInScreen: View {
    let app: AppModel
    @State private var error: String?
    @State private var showDevLogin = false
    @State private var working = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            CmuxMark().frame(width: 72, height: 72)
                .onLongPressGesture(minimumDuration: 1.5) { showDevLogin = true }
            Text(String(localized: "cmux"))
                .font(.system(size: 34, weight: .semibold, design: .default))
                .padding(.top, 20)
            Text(String(localized: "Your Mac's terminals and agents,\nin your pocket."))
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            VStack(spacing: 12) {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handle(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 54)
                .clipShape(Capsule())
                .disabled(working)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                }
                Text(String(localized: "By continuing you agree to the Terms and Privacy Policy."))
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDevLogin) { DevLoginSheet(app: app) }
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                error = String(localized: "Sign in with Apple didn't return a token.")
                return
            }
            let name = credential.fullName.flatMap { PersonNameComponentsFormatter().string(from: $0) }
            working = true
            Task {
                defer { working = false }
                do { try await app.signInWithApple(identityToken: token, name: name) } catch { self.error = error.localizedDescription }
            }
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled { error = failure.localizedDescription }
        }
    }
}

/// Test-account login for agents and CI (hidden: long-press the mark).
struct DevLoginSheet: View {
    let app: AppModel
    @State private var email = ""
    @State private var secret = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("name@test.cmux.dev", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress)
                SecureField(String(localized: "Secret"), text: $secret)
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle(String(localized: "Test account"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Sign In")) {
                        Task {
                            do { try await app.signInDev(email: email, secret: secret); dismiss() } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
        }
    }
}

/// The cmux chevron mark.
struct CmuxMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(white: 0.1))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .overlay {
                Image(systemName: "chevron.right")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: Connect a Mac (Codex flow)

/// Empty state when no Mac is paired.
struct ConnectMacEmptyState: View {
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.system(size: 30, weight: .light))
            Text(String(localized: "Connect your Mac")).font(.headline).padding(.top, 4)
            Text(String(localized: "Pair the Mac running cmux to see its terminals and agents here."))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: onConnect) {
                Text(String(localized: "Connect a Mac")).font(.body.weight(.semibold))
                    .padding(.horizontal, 22).frame(height: 44)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .background(Capsule().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .accessibilityIdentifier("pair.start")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConnectingState: View {
    let hostName: String?
    let path: String?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(hostName.map { String(localized: "Connecting to \($0)…") } ?? String(localized: "Connecting…"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OfflineState: View {
    let hostName: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 30, weight: .light))
            Text(String(localized: "Couldn't reach \(hostName)")).font(.headline).padding(.top, 4)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Text(String(localized: "Make sure the Mac is awake and cmux is running."))
                .font(.footnote).foregroundStyle(.tertiary)
            Button(action: onRetry) {
                Text(String(localized: "Retry")).font(.body.weight(.semibold))
                    .padding(.horizontal, 26).frame(height: 44)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .background(Capsule().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pair a Mac: instructions → scan the QR or type the 8-symbol code.
struct PairingFlow: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showManual = false
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "desktopcomputer").font(.system(size: 44, weight: .light))
                Text(String(localized: "Get a pairing code")).font(.title3.weight(.semibold)).padding(.top, 18)
                Text(String(localized: "On your Mac, open cmux and choose Settings › Phone › Pair iPhone, or run:"))
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 36).padding(.top, 8)
                Text("cmux-native-host pair-code")
                    .font(.system(.footnote, design: .monospaced))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.elevated))
                    .padding(.top, 14)
                    .textSelection(.enabled)
                Spacer()
                VStack(spacing: 12) {
                    if DataScannerViewController.isSupported {
                        Button { scanning = true } label: {
                            Text(String(localized: "Scan QR code")).font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .background(Capsule().fill(Color.primary))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { showManual = true } label: {
                        Text(String(localized: "Enter code manually")).font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pair.manual")
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
            }
            .sheet(isPresented: $showManual) {
                PairCodeSheet(app: app) { dismiss() }
                    .presentationDetents([.height(360)])
            }
            .fullScreenCover(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    Task { try? await app.pair(code: code); dismiss() }
                }
                .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// 4 + 4 code boxes (XXXX-XXXX), like Codex's "Pair manually".
struct PairCodeSheet: View {
    let app: AppModel
    let onPaired: () -> Void
    @State private var code = ""
    @State private var error: String?
    @State private var pairing = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(role: .close) { dismiss() }.buttonStyle(.glass)
                Spacer()
            }
            Text(String(localized: "Pair manually")).font(.title3.weight(.semibold))
            Text(String(localized: "Enter the pairing code shown on your Mac.")).font(.subheadline).foregroundStyle(.secondary)
            ZStack {
                TextField("", text: $code)
                    .focused($focused)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .opacity(0.01)
                    .onChange(of: code) { _, value in
                        let cleaned = String(value.uppercased().filter { Self.alphabet.contains($0) }.prefix(8))
                        if cleaned != code { code = cleaned }
                        if cleaned.count == 8 { pair() }
                    }
                    .accessibilityIdentifier("pair.codeField")
                HStack(spacing: 8) {
                    boxes(0..<4)
                    Text("–").foregroundStyle(.secondary)
                    boxes(4..<8)
                }
                .onTapGesture { focused = true }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            Button(action: pair) {
                Group {
                    if pairing { ProgressView() } else { Text(String(localized: "Pair")).font(.body.weight(.semibold)) }
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .background(Capsule().fill(Color.primary.opacity(code.count == 8 ? 1 : 0.35)))
            }
            .buttonStyle(.plain)
            .disabled(code.count < 8 || pairing)
            .accessibilityIdentifier("pair.submit")
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func boxes(_ range: Range<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(range, id: \.self) { index in
                let chars = Array(code)
                Text(index < chars.count ? String(chars[index]) : "")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .frame(width: 36, height: 48)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.elevated))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(index == chars.count && focused ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5))
            }
        }
    }

    private func pair() {
        guard code.count == 8, !pairing else { return }
        pairing = true
        error = nil
        Task {
            defer { pairing = false }
            do {
                try await app.pair(code: String(code.prefix(4)) + "-" + String(code.suffix(4)))
                Haptics.success()
                onPaired()
            } catch {
                Haptics.warning()
                self.error = error.localizedDescription
                code = ""
            }
        }
    }
}

/// QR scanning with VisionKit; accepts `cmux-native://pair?code=XXXX-XXXX` or a bare code.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                guard !done, let payload = barcode.payloadStringValue else { continue }
                let code = URLComponents(string: payload)?.queryItems?.first { $0.name == "code" }?.value ?? payload
                guard code.filter({ $0.isLetter || $0.isNumber }).count == 8 else { continue }
                done = true
                onCode(code)
            }
        }
    }
}
