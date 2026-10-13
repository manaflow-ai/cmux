import AuthenticationServices
import SwiftUI
import VisionKit

enum LegalLinks {
    static let terms = URL(string: "https://cmux.com/terms-of-service")!
    static let privacy = URL(string: "https://cmux.com/privacy-policy")!
    static let download = URL(string: "https://cmux.com")!
}

/// Launch and sign-in: the cmux mark, one line, Sign in with Apple.
struct SignInScreen: View {
    let app: AppModel
    @State private var error: String?
    @State private var showDevLogin = false
    @State private var working = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            CmuxMark().frame(width: 72, height: 72)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.86)
                .onLongPressGesture(minimumDuration: 1.5) { showDevLogin = true }
                .accessibilityHidden(true)
            Group {
                Text(String(localized: "cmux"))
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)
                Text(String(localized: "Your Mac's terminals and agents,\nin your pocket."))
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            Spacer()
            VStack(spacing: 14) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handle(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 54)
                .clipShape(Capsule())
                .disabled(working)
                .overlay {
                    if working {
                        Capsule().fill(.white)
                        ProgressView().tint(.black)
                    }
                }
                Text(legalText)
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    .tint(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .opacity(appeared || reduceMotion ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.3), value: error)
        .sheet(isPresented: $showDevLogin) { DevLoginSheet(app: app) }
        .onAppear { withAnimation(.smooth(duration: 0.6).delay(0.05)) { appeared = true } }
    }

    private var legalText: AttributedString {
        let raw = String(localized: "By continuing you agree to the [Terms](\(LegalLinks.terms.absoluteString)) and [Privacy Policy](\(LegalLinks.privacy.absoluteString)).")
        var value = (try? AttributedString(markdown: raw)) ?? AttributedString(raw)
        for run in value.runs where run.link != nil { value[run.range].underlineStyle = .single }
        return value
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
                error = String(localized: "Sign in with Apple didn't return a token.")
                Haptics.warning()
                return
            }
            let name = credential.fullName.flatMap { PersonNameComponentsFormatter().string(from: $0) }
            working = true
            error = nil
            Task {
                defer { working = false }
                do {
                    try await app.signInWithApple(identityToken: token, name: name)
                    Haptics.success()
                } catch {
                    Haptics.warning()
                    self.error = error.localizedDescription
                }
            }
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled {
                Haptics.warning()
                error = failure.localizedDescription
            }
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

/// Where the pairing flow starts.
enum PairingEntry: Hashable {
    /// Instructions, then the QR scanner.
    case intro
    /// Straight to the 4 + 4 code boxes.
    case manual
    /// For people without cmux on a Mac yet.
    case setup
}

/// Empty state when no Mac is paired (Codex "Connect your computer").
struct ConnectMacEmptyState: View {
    let onStart: (PairingEntry) -> Void

    var body: some View {
        StateMessageView(
            systemImage: "laptopcomputer.and.iphone",
            title: String(localized: "Connect your Mac"),
            message: String(localized: "Open cmux on your Mac and get a pairing code to see its terminals and agents here.")
        ) {
            Button(String(localized: "Scan QR code")) { onStart(.intro) }
                .buttonStyle(.primaryCapsule)
                .accessibilityIdentifier("pair.start")
            Button(String(localized: "Enter code manually")) { onStart(.manual) }
                .font(.body)
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("pair.manualEntry")
            Button(String(localized: "Don't have cmux on a Mac?")) { onStart(.setup) }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .padding(.top, 6)
                .accessibilityIdentifier("pair.setup")
        }
    }
}

struct ConnectingState: View {
    let hostName: String?
    let path: String?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.regular)
            WorkingText(text: hostName.map { String(localized: "Connecting to \($0)…") } ?? String(localized: "Connecting…"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OfflineState: View {
    let hostName: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        LoadFailedView(
            title: String(localized: "Couldn't reach \(hostName)"),
            message: String(localized: "Make sure the Mac is awake, online and running cmux."),
            onRetry: onRetry
        )
    }
}

/// Pair a Mac, Codex style: intro → QR scanner (or 4 + 4 code) → connected.
/// Pushed steps keep the interactive swipe back.
struct PairingFlow: View {
    let app: AppModel
    var entry: PairingEntry = .intro
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var showManual = false
    @State private var pairedName: String?

    enum Step: Hashable { case intro, scan }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .intro: PairIntroView { path.append(.scan) }
                    case .scan: PairScanView(onCode: pair) { showManual = true }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(role: .close) { dismiss() } }
                }
        }
        .sheet(isPresented: $showManual) {
            PairCodeSheet(app: app) { finish() }
                .presentationDetents([.height(380)])
                .presentationCornerRadius(32)
        }
        .overlay {
            if let pairedName {
                PairedView(hostName: pairedName) { dismiss() }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.smooth(duration: 0.35), value: pairedName)
        .preferredColorScheme(.dark)
        .onAppear {
            if entry == .manual { showManual = true }
            #if DEBUG
            // Agent screenshots without UI automation: CMUX_NATIVE_DEBUG_SCREEN=pair-scan|paired.
            switch ProcessInfo.processInfo.environment["CMUX_NATIVE_DEBUG_SCREEN"] {
            case "pair-scan": path = [.scan]
            case "paired": pairedName = app.connection?.host.name ?? "MacBook Pro"
            default: break
            }
            #endif
        }
    }

    @ViewBuilder
    private var root: some View {
        switch entry {
        case .setup:
            SetupMacView(email: app.user?.email) { path.append(.intro) }
        case .intro, .manual:
            PairIntroView { path.append(.scan) }
        }
    }

    private func pair(_ code: String) {
        Task {
            do {
                try await app.pair(code: code)
                finish()
            } catch {
                Haptics.warning()
                showManual = true
            }
        }
    }

    private func finish() {
        showManual = false
        Haptics.success()
        pairedName = app.connection?.host.name ?? String(localized: "your Mac")
    }
}

/// Step 1: where to find the code on the Mac.
struct PairIntroView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 44, weight: .light))
                        .symbolEffect(.bounce, options: .nonRepeating)
                        .padding(.bottom, 10)
                        .accessibilityHidden(true)
                    Text(String(localized: "Get a pairing code"))
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "Make sure cmux is open on your Mac."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(String(localized: "In cmux on your Mac, open Settings › iPhone and click Pair iPhone. Or run this in a terminal:"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.top, 10)
                    Text(verbatim: "cmux-native-host pair-code")
                        .font(.system(.footnote, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.elevated))
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(String(localized: "Continue"), action: onContinue)
                .buttonStyle(.primaryCapsuleWide)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .accessibilityIdentifier("pair.continue")
        }
        .background(Theme.background)
    }
}

/// Step 2: rounded camera viewport with corner guides (Codex), plus a way
/// out to the manual code.
struct PairScanView: View {
    let onCode: (String) -> Void
    let onManual: () -> Void
    @State private var scanned = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 36, style: .continuous).fill(Theme.elevated)
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    QRScanner { code in
                        guard !scanned else { return }
                        scanned = true
                        Haptics.success()
                        onCode(code)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera").font(.title2)
                        Text(String(localized: "Camera unavailable"))
                            .font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                }
                ScanCorners()
                    .stroke(Color(red: 1, green: 0.8, blue: 0.1), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .padding(22)
                    .accessibilityHidden(true)
            }
            .frame(width: 260, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Camera viewfinder"))
            Text(String(localized: "Scan QR code to pair"))
                .font(.headline)
                .padding(.top, 28)
            Text(String(localized: "Point your camera at the code shown on your Mac."))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.horizontal, 36)
            Spacer()
            Button(String(localized: "Pair manually instead"), action: onManual)
                .buttonStyle(.outlineCapsule)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .accessibilityIdentifier("pair.manual")
        }
        .background(Theme.background)
    }
}

/// Four L-shaped corner guides.
struct ScanCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.16
        let radius: CGFloat = 14
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addArc(tangent1End: corner, tangent2End: CGPoint(x: corner.x + dx * length, y: corner.y), radius: radius)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// For people with no Mac running cmux yet (Codex "Set up Codex").
struct SetupMacView: View {
    let email: String?
    let onInstalled: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "laptopcomputer.and.arrow.down")
                        .font(.system(size: 44, weight: .light))
                        .symbolEffect(.bounce, options: .nonRepeating)
                        .padding(.top, 40)
                        .accessibilityHidden(true)
                    Text(String(localized: "Set up cmux on your Mac"))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "This app connects to cmux running on your Mac."))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 22) {
                        row("terminal", String(localized: "Run terminals and coding agents on your Mac, then follow and answer them from here."))
                        row("qrcode", email.map { String(localized: "Install cmux, open Settings › iPhone and pair this phone. Use the same account (\($0)).") }
                            ?? String(localized: "Install cmux, open Settings › iPhone and pair this phone."))
                    }
                    .padding(.top, 34)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 12) {
                Button(String(localized: "I have cmux on my Mac"), action: onInstalled)
                    .buttonStyle(.primaryCapsuleWide)
                    .accessibilityIdentifier("pair.setup.installed")
                ShareLink(item: LegalLinks.download, subject: Text(String(localized: "Download cmux for Mac")), message: Text(String(localized: "Install cmux on your Mac, then pair your iPhone."))) {
                    Text(String(localized: "Send me the download link"))
                }
                .buttonStyle(.outlineCapsule)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Theme.background)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Final step: the connection confirmation with a drawn checkmark.
struct PairedView: View {
    let hostName: String
    let onDone: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Theme.success.opacity(0.16)).frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .symbolEffect(.drawOn, isActive: !shown)
            }
            .accessibilityHidden(true)
            Text(String(localized: "Connected"))
                .font(.title2.weight(.semibold))
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text(String(localized: "\(hostName) is paired with this iPhone."))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 36)
            Spacer()
            Button(String(localized: "Done"), action: onDone)
                .buttonStyle(.primaryCapsuleWide)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .accessibilityIdentifier("pair.done")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear { shown = true }
    }
}

/// 4 + 4 code boxes (XXXX-XXXX), like Codex's "Pair manually".
struct PairCodeSheet: View {
    let app: AppModel
    let onPaired: () -> Void
    @State private var code = ""
    @State private var error: String?
    @State private var pairing = false
    @State private var shake = 0
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(String(localized: "Close"))
                Spacer()
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    Task { @MainActor in code = clean(first) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            Text(String(localized: "Pair manually")).font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(String(localized: "Enter the pairing code shown on your Mac.")).font(.subheadline).foregroundStyle(.secondary)
            ZStack {
                TextField("", text: $code)
                    .focused($focused)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .opacity(0.01)
                    .onChange(of: code) { _, value in
                        let cleaned = clean(value)
                        if cleaned != code { code = cleaned; return }
                        if !cleaned.isEmpty { error = nil }
                        Haptics.selection()
                        if cleaned.count == 8 { pair() }
                    }
                    .accessibilityLabel(String(localized: "Pairing code"))
                    .accessibilityValue(code.isEmpty ? String(localized: "Empty") : code.map(String.init).joined(separator: " "))
                    .accessibilityIdentifier("pair.codeField")
                HStack(spacing: 6) {
                    boxes(0..<4)
                    Text(verbatim: "–").foregroundStyle(.secondary).accessibilityHidden(true)
                    boxes(4..<8)
                }
                .frame(maxWidth: .infinity)
                .keyframeAnimator(initialValue: CGFloat(0), trigger: shake) { content, offset in
                    content.offset(x: offset)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(-12, duration: 0.07)
                        SpringKeyframe(10, duration: 0.07)
                        SpringKeyframe(-6, duration: 0.07)
                        SpringKeyframe(0, duration: 0.1)
                    }
                }
                .contentShape(.rect)
                .onTapGesture { focused = true }
                .accessibilityHidden(true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(Theme.danger)
                    .transition(.opacity)
            }
            Button(action: pair) {
                if pairing { ProgressView().tint(Color(uiColor: .systemBackground)) } else { Text(String(localized: "Pair")) }
            }
            .buttonStyle(.primaryCapsuleWide)
            .disabled(code.count < 8 || pairing)
            .accessibilityIdentifier("pair.submit")
        }
        .padding(20)
        .animation(.smooth(duration: 0.2), value: error)
        .onAppear { focused = true }
    }

    private func clean(_ value: String) -> String {
        String(value.uppercased().filter { Self.alphabet.contains($0) }.prefix(8))
    }

    private func boxes(_ range: Range<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(range, id: \.self) { index in
                let chars = Array(code)
                let filled = index < chars.count
                Text(filled ? String(chars[index]) : "")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: 38).frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(filled ? 0.16 : 0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(error != nil ? Theme.danger.opacity(0.7)
                                      : index == chars.count && focused ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5))
                    .scaleEffect(filled ? 1 : 0.97)
                    .animation(.snappy(duration: 0.18), value: filled)
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
                onPaired()
            } catch {
                Haptics.warning()
                self.error = error.localizedDescription
                shake += 1
                code = ""
            }
        }
    }
}

/// QR scanning with VisionKit; accepts `cmux-native://pair?code=XXXX-XXXX` or a bare code.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning { try? controller.startScanning() }
    }

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
