import Foundation
@preconcurrency import AVFoundation
import CMUXMobileCore
import Observation
import OSLog
import StackAuth
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

#if DEBUG
private let mobileShellUILog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell-ui"
)
#endif

public struct CMUXMobileAppView: View {
    @State private var store: CMUXMobileShellStore

    public init(store: CMUXMobileShellStore = .preview()) {
        _store = State(initialValue: store)
    }

    public var body: some View {
        CMUXMobileRootView(store: store)
    }
}

struct CMUXMobileRootView: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var authManager = AuthManager.shared
    @State private var pendingAttachURL: String?
    @State private var didConsumeUITestAttachURL = false
    @State private var didAuthenticateWithAttachTicket = false
    @State private var isShowingAddDeviceSheet = true
    #if os(iOS)
    @State private var addDeviceSheetDetent: PresentationDetent = .large
    #endif

    var body: some View {
        Group {
            if shouldShowRestoringSession {
                RestoringSessionView()
            } else if !isAuthenticated {
                SignInView()
            } else if store.connectionState != .connected {
                DisconnectedWorkspaceShellView(
                    showAddDevice: showAddDevice,
                    signOut: signOut
                )
                .sheet(isPresented: $isShowingAddDeviceSheet) {
                    PairingView(
                        pairingCode: $store.pairingCode,
                        connectionError: store.connectionError,
                        connectPairingCode: {
                            await store.connectPairingInput()
                        },
                        connectManualHost: { name, host, port in
                            await store.connectManualHost(name: name, host: host, port: port)
                        },
                        cancelPairing: store.cancelPairing,
                        cancel: { isShowingAddDeviceSheet = false }
                    )
                    #if os(iOS)
                    .presentationDetents([.medium, .large], selection: $addDeviceSheetDetent)
                    .presentationDragIndicator(.visible)
                    #endif
                }
                .onAppear {
                    showAddDevice()
                }
            } else {
                WorkspaceShellView(store: store)
            }
        }
        .animation(.snappy(duration: 0.18), value: isAuthenticated)
        .animation(.snappy(duration: 0.18), value: store.phase)
        .onAppear {
            syncShellAuthentication(isAuthenticated)
            store.resumeForegroundRefresh()
            connectUITestAttachURLIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.resumeForegroundRefresh()
        }
        .onOpenURL { url in
            let rawURL = url.absoluteString
            if MobileRootAuthGate.isAttachURL(url) {
                connectAttachURL(rawURL)
                return
            }

            guard isAuthenticated else {
                pendingAttachURL = rawURL
                return
            }
            Task {
                await store.connectPairingURL(rawURL)
            }
        }
        .onChange(of: isAuthenticated) { _, isAuthenticated in
            syncShellAuthentication(isAuthenticated)
            guard isAuthenticated else {
                return
            }
            if let rawURL = pendingAttachURL {
                pendingAttachURL = nil
                Task {
                    await store.connectPairingURL(rawURL)
                }
                return
            }
            connectUITestAttachURLIfNeeded()
            if store.connectionState != .connected {
                let stackUserID = authManager.currentUser?.id
                Task {
                    await store.reconnectActiveMacIfAvailable(stackUserID: stackUserID)
                }
            }
        }
        .onChange(of: authManager.isRestoringSession) { _, isRestoringSession in
            syncShellAuthentication(isAuthenticated, isRestoringSession: isRestoringSession)
        }
        .onChange(of: store.connectionState) { _, connectionState in
            if connectionState == .connected {
                isShowingAddDeviceSheet = false
            } else {
                clearAttachTicketAuthenticationIfNeeded()
            }
        }
        .onChange(of: store.hasActiveUnexpiredAttachTicket) { _, hasActiveUnexpiredAttachTicket in
            if !hasActiveUnexpiredAttachTicket {
                clearAttachTicketAuthenticationIfNeeded()
            }
        }
    }

    private var isAuthenticated: Bool {
        MobileRootAuthGate.isAuthenticated(
            stackAuthenticated: authManager.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication
        )
    }

    private var shouldShowRestoringSession: Bool {
        MobileRootAuthGate.shouldShowRestoringSession(
            stackAuthenticated: authManager.isAuthenticated,
            attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
            isRestoringSession: authManager.isRestoringSession
        )
    }

    private var hasActiveAttachTicketAuthentication: Bool {
        didAuthenticateWithAttachTicket && store.hasActiveUnexpiredAttachTicket
    }

    private func syncShellAuthentication(
        _ isAuthenticated: Bool,
        isRestoringSession: Bool? = nil
    ) {
        MobileRootAuthGate.syncShellAuthentication(
            stackAuthenticated: isAuthenticated,
            isRestoringSession: isRestoringSession ?? authManager.isRestoringSession,
            store: store
        )
    }

    private func showAddDevice() {
        #if os(iOS)
        addDeviceSheetDetent = .large
        #endif
        isShowingAddDeviceSheet = true
    }

    private func connectAttachURL(_ rawURL: String) {
        didAuthenticateWithAttachTicket = true
        syncShellAuthentication(true)
        Task {
            let result = await store.connectPairingURLResult(rawURL)
            guard MobileRootAuthGate.shouldClearAttachTicketAuthentication(
                pairingResult: result,
                connectionState: store.connectionState,
                hasActiveUnexpiredTicket: store.hasActiveUnexpiredAttachTicket
            ) else { return }
            didAuthenticateWithAttachTicket = false
            syncShellAuthentication(authManager.isAuthenticated)
        }
    }

    private func clearAttachTicketAuthenticationIfNeeded() {
        guard didAuthenticateWithAttachTicket,
              store.connectionState != .connected || !store.hasActiveUnexpiredAttachTicket else {
            return
        }
        didAuthenticateWithAttachTicket = false
        syncShellAuthentication(authManager.isAuthenticated)
    }

    private func signOut() {
        Task {
            await authManager.signOut()
            didAuthenticateWithAttachTicket = false
            store.signOut()
        }
    }

    private func connectUITestAttachURLIfNeeded() {
        #if DEBUG
        guard UITestConfig.mockDataEnabled,
              !didConsumeUITestAttachURL,
              isAuthenticated,
              let attachURL = UITestConfig.attachURL else {
            return
        }
        didConsumeUITestAttachURL = true
        Task {
            await store.connectPairingURL(attachURL)
        }
        #endif
    }
}

enum MobileRootAuthGate {
    static func isAuthenticated(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool = false
    ) -> Bool {
        stackAuthenticated || attachTicketAuthenticated
    }

    static func shouldShowRestoringSession(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool = false,
        isRestoringSession: Bool
    ) -> Bool {
        isRestoringSession && !isAuthenticated(
            stackAuthenticated: stackAuthenticated,
            attachTicketAuthenticated: attachTicketAuthenticated
        )
    }

    static func isAttachURL(_ url: URL) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("cmux-ios") == .orderedSame else {
            return false
        }
        return url.host?.caseInsensitiveCompare("attach") == .orderedSame
    }

    static func shouldClearAttachTicketAuthentication(
        pairingResult: MobilePairingURLConnectionResult,
        connectionState: MobileConnectionState,
        hasActiveUnexpiredTicket: Bool
    ) -> Bool {
        switch pairingResult {
        case .connected:
            return connectionState != .connected || !hasActiveUnexpiredTicket
        case .failed:
            return true
        case .superseded:
            return connectionState != .connected || !hasActiveUnexpiredTicket
        }
    }

    @MainActor
    static func syncShellAuthentication(
        stackAuthenticated: Bool,
        isRestoringSession: Bool = false,
        store: CMUXMobileShellStore
    ) {
        if stackAuthenticated {
            store.signIn()
        } else if !isRestoringSession {
            store.signOut()
        }
    }
}

private struct DisconnectedWorkspaceShellView: View {
    let showAddDevice: () -> Void
    let signOut: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.devices.emptyTitle", defaultValue: "No devices"),
                    systemImage: "desktopcomputer.and.iphone"
                )
            } description: {
                Text(L10n.string("mobile.devices.emptyDescription", defaultValue: "Add a Mac to start syncing terminal workspaces."))
            } actions: {
                Button(action: showAddDevice) {
                    Text(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("MobileShowAddDeviceButton")
            }
            .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
            .mobileInlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    signOutButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addDeviceToolbarButton
                }
                #else
                ToolbarItem {
                    signOutButton
                }
                ToolbarItem {
                    addDeviceToolbarButton
                }
                #endif
            }
            .accessibilityIdentifier("MobileDisconnectedWorkspaceShell")
        }
    }

    private var signOutButton: some View {
        Button(action: signOut) {
            Text(L10n.string("mobile.signOut", defaultValue: "Sign Out"))
        }
        .accessibilityIdentifier("MobileSignOutButton")
    }

    private var addDeviceToolbarButton: some View {
        Button(action: showAddDevice) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
        .accessibilityIdentifier("MobileShowAddDeviceToolbarButton")
    }
}

struct SignInView: View {
    @State private var authManager = AuthManager.shared
    @State private var email = ""
    @State private var code = ""
    @State private var showCodeEntry = false
    @State private var error: String?
    @State private var isAppleSigningIn = false
    @State private var isGoogleSigningIn = false
    @State private var shouldAutofocusCode = false
    @State private var shouldAutofocusEmail = false
    @FocusState private var isEmailFocused: Bool
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    signInEntrySwitcher
                }
            }
            .mobileInlineNavigationTitle()
        }
    }

    @ViewBuilder
    private var signInEntrySwitcher: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                signInEntryContent
            }
        } else {
            signInEntryContent
        }
        #else
        signInEntryContent
        #endif
    }

    @ViewBuilder
    private var signInEntryContent: some View {
        if showCodeEntry {
            codeEntryView
        } else {
            emailEntryView
        }
    }

    private var emailEntryView: some View {
        authCard {
            VStack(spacing: 20) {
                brandHeader

                Button {
                    Task {
                        await signInWithApple()
                    }
                } label: {
                    Label(L10n.string("mobile.signIn.apple", defaultValue: "Sign in with Apple"), systemImage: "apple.logo")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .contentShape(.capsule)
                }
                .disabled(isAuthInProgress)
                .mobileGlassButton()
                .accessibilityIdentifier("signin.apple")

                Button {
                    Task {
                        await signInWithGoogle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image("GoogleLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(L10n.string("mobile.signIn.google", defaultValue: "Sign in with Google"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(.capsule)
                }
                .disabled(isAuthInProgress)
                .mobileGlassButton()
                .accessibilityIdentifier("signin.google")

                DividerLabel(text: L10n.string("mobile.signIn.emailDivider", defaultValue: "or continue with email"))

                VStack(spacing: 12) {
                    GlassInputPill(height: 50, alignment: .leading) {
                        TextField(L10n.string("mobile.signIn.emailPlaceholder", defaultValue: "Email address"), text: $email)
                            .textFieldStyle(.plain)
                            .mobileEmailTextInput()
                            .focused($isEmailFocused)
                            .accessibilityIdentifier("Email")
                    } onTap: {
                        isEmailFocused = true
                    }

                    Button {
                        let autofocusCodeOnSuccess = isEmailFocused
                        Task {
                            await sendCode(autofocusCodeOnSuccess: autofocusCodeOnSuccess)
                        }
                    } label: {
                        Text(L10n.string("mobile.signIn.emailCode", defaultValue: "Email me a code"))
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .contentShape(.capsule)
                    }
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAuthInProgress)
                    .mobileGlassProminentButton()
                    .accessibilityIdentifier("signin.emailCode")
                }

                if let error {
                    errorText(error)
                }
            }
        }
        .opacity(isAuthInProgress ? 0.6 : 1.0)
        .onAppear {
            guard shouldAutofocusEmail else { return }
            isEmailFocused = true
            shouldAutofocusEmail = false
        }
    }

    private var codeEntryView: some View {
        authCard {
            VStack(spacing: 18) {
                brandHeader

                VStack(spacing: 6) {
                    Text(L10n.string("mobile.signIn.checkEmail", defaultValue: "Check your email"))
                        .font(.headline)
                    Text(String(format: L10n.string("mobile.signIn.sentCodeFormat", defaultValue: "We sent a code to %@"), email))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                GlassInputPill(height: 60, alignment: .center) {
                    TextField(L10n.string("mobile.signIn.codePlaceholder", defaultValue: "000000"), text: $code)
                        .textFieldStyle(.plain)
                        .mobileOneTimeCodeInput()
                        .multilineTextAlignment(.center)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .focused($isCodeFocused)
                        .onChange(of: code) { _, newValue in
                            switch SignInCodeInputPolicy.action(for: newValue) {
                            case let .assign(normalizedCode):
                                code = normalizedCode
                            case .verify:
                                Task {
                                    await verifyCode()
                                }
                            case .none:
                                break
                            }
                        }
                        .accessibilityIdentifier("signin.code")
                } onTap: {
                    isCodeFocused = true
                }
                .onAppear {
                    guard shouldAutofocusCode else { return }
                    isCodeFocused = true
                    shouldAutofocusCode = false
                }

                if let error {
                    errorText(error)
                }

                Button {
                    Task {
                        await verifyCode()
                    }
                } label: {
                    Text(L10n.string("mobile.signIn.verifyCode", defaultValue: "Verify code"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .contentShape(.capsule)
                }
                .disabled(code.count != 6 || isAuthInProgress)
                .mobileGlassProminentButton()
                .accessibilityIdentifier("signin.verifyCode")

                Button {
                    let autofocusEmailOnReturn = isCodeFocused
                    withAnimation(.snappy(duration: 0.18)) {
                        shouldAutofocusEmail = autofocusEmailOnReturn
                        showCodeEntry = false
                        code = ""
                        error = nil
                    }
                } label: {
                    Text(L10n.string("mobile.signIn.useDifferentEmail", defaultValue: "Use a different email"))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var isAuthInProgress: Bool {
        authManager.isLoading || isAppleSigningIn || isGoogleSigningIn
    }

    private func sendCode(autofocusCodeOnSuccess: Bool) async {
        error = nil
        do {
            try await authManager.sendCode(to: email)
            guard !authManager.isAuthenticated else {
                return
            }
            shouldAutofocusCode = autofocusCodeOnSuccess
            withAnimation(.snappy(duration: 0.18)) {
                showCodeEntry = true
            }
        } catch {
            shouldAutofocusCode = false
            self.error = detailedErrorMessage(error)
        }
    }

    private func verifyCode() async {
        error = nil
        do {
            try await authManager.verifyCode(code)
        } catch {
            self.error = detailedErrorMessage(error)
            code = ""
        }
    }

    private func signInWithApple() async {
        error = nil
        isAppleSigningIn = true
        defer { isAppleSigningIn = false }
        do {
            try await authManager.signInWithApple()
        } catch {
            if case AuthError.cancelled = error {
                return
            }
            if let stackError = error as? StackAuthErrorProtocol, stackError.code == "oauth_cancelled" {
                return
            }
            self.error = detailedErrorMessage(error)
        }
    }

    private func signInWithGoogle() async {
        error = nil
        isGoogleSigningIn = true
        defer { isGoogleSigningIn = false }
        do {
            try await authManager.signInWithGoogle()
        } catch {
            if case AuthError.cancelled = error {
                return
            }
            if let stackError = error as? StackAuthErrorProtocol, stackError.code == "oauth_cancelled" {
                return
            }
            self.error = detailedErrorMessage(error)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier("signin.error")
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        let displayError = AuthManager.displaySafeAuthError(error)
        if let stackError = displayError as? StackAuthErrorProtocol {
            switch stackError.code {
            case "SCHEMA_ERROR":
                return L10n.string("auth.error.invalid_email", defaultValue: "Please enter a valid email address.")
            case "USER_EMAIL_ALREADY_EXISTS":
                return L10n.string("auth.error.email_exists", defaultValue: "An account with this email already exists. Try signing in instead.")
            case "VERIFICATION_CODE_ERROR", "INVALID_OTP":
                return L10n.string("auth.error.invalid_code", defaultValue: "Invalid code. Please check and try again.")
            case "OTP_EXPIRED":
                return L10n.string("auth.error.code_expired", defaultValue: "Code expired. Please request a new one.")
            case "RATE_LIMIT":
                return L10n.string("auth.error.rate_limit", defaultValue: "Too many attempts. Please wait a moment and try again.")
            case "EMAIL_PASSWORD_MISMATCH":
                return L10n.string("auth.error.wrong_password", defaultValue: "Incorrect email or password.")
            case "USER_NOT_FOUND":
                return L10n.string("auth.error.user_not_found", defaultValue: "No account found with this email.")
            case "PASSKEY_AUTHENTICATION_FAILED", "PASSKEY_WEBAUTHN_ERROR":
                return L10n.string("auth.error.passkey_failed", defaultValue: "Passkey authentication failed. Please try again.")
            case "INVALID_TOTP_CODE":
                return L10n.string("auth.error.invalid_mfa", defaultValue: "Incorrect verification code. Please try again.")
            case "REDIRECT_URL_NOT_WHITELISTED":
                return L10n.string("auth.error.config", defaultValue: "Sign in is temporarily unavailable. Please try again later.")
            case "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN":
                return L10n.string("auth.error.oauth_linked", defaultValue: "This account is already linked to another sign-in method.")
            case "INVALID_APPLE_CREDENTIALS":
                return L10n.string("auth.error.apple_config", defaultValue: "Apple Sign In is not available yet. Please use another sign-in method.")
            case "oauth_cancelled":
                return ""
            default:
                break
            }
        }

        if let authError = displayError as? AuthError {
            return authError.localizedDescription
        }

        let nsError = displayError as NSError
        if nsError.domain == NSURLErrorDomain {
            return L10n.string("auth.error.network", defaultValue: "Could not connect to the server. Check your internet connection and try again.")
        }

        #if DEBUG
        var debug = "\(displayError.localizedDescription)\n\(String(reflecting: type(of: displayError)))"
        if let stackError = displayError as? StackAuthErrorProtocol {
            debug += "\ncode: \(stackError.code)\nmessage: \(stackError.message)"
            if let details = stackError.details {
                debug += "\ndetails: \(details)"
            }
        }
        return debug
        #else
        return L10n.string("auth.error.generic", defaultValue: "Something went wrong. Please try again.")
        #endif
    }

    private func authCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }
            )
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image("CmuxLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text(L10n.string("mobile.signIn.title", defaultValue: "cmux"))
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }

    private func dismissKeyboard() {
        #if os(iOS)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.endEditing(true)
            }
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

enum SignInCodeInputChangeAction: Equatable {
    case assign(String)
    case verify
    case none
}

enum SignInCodeInputPolicy {
    static let maximumCodeLength = 6

    static func action(for value: String) -> SignInCodeInputChangeAction {
        let normalized = normalizedCode(value)
        guard normalized == value else {
            return .assign(normalized)
        }
        return shouldVerifyAfterChange(normalized) ? .verify : .none
    }

    static func normalizedCode(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumCodeLength))
    }

    static func shouldVerifyAfterChange(_ normalizedCode: String) -> Bool {
        normalizedCode.count == maximumCodeLength
    }
}

struct RestoringSessionView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    Image("CmuxLogo")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)

                    ProgressView(L10n.string("mobile.signIn.restoring", defaultValue: "Restoring session"))
                        .controlSize(.regular)
                }
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("MobileRestoringSessionView")
            }
            .mobileInlineNavigationTitle()
        }
    }
}

private struct DividerLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            dividerLine
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.primary.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
                .layoutPriority(1)
            dividerLine
        }
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(PlatformPalette.separator.opacity(0.4))
            .frame(height: 1)
    }
}

private struct GameOfLifeHeader: View {
    private let columns = 36
    private let rows = 52
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GameOfLifeGrid(columns: columns, rows: rows)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)

                LinearGradient(
                    colors: [
                        PlatformPalette.systemBackground.opacity(0.0),
                        PlatformPalette.systemBackground.opacity(colorScheme == .dark ? 0.82 : 0.70),
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
    }
}

private struct GameOfLifeGrid: View {
    let columns: Int
    let rows: Int

    @State private var cells: [Bool] = []
    @State private var stepCount = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let tick = Int(time / 0.08)

            GeometryReader { _ in
                Canvas { context, size in
                    let cellWidth = size.width / CGFloat(columns)
                    let cellHeight = size.height / CGFloat(rows)
                    let cellSize = min(cellWidth, cellHeight) * 0.52
                    let yOffset = (cellHeight - cellSize) * 0.5
                    let xOffset = (cellWidth - cellSize) * 0.5
                    let scale = max(1, displayScale)

                    func snapToPixel(_ value: CGFloat) -> CGFloat {
                        (value * scale).rounded(.toNearestOrAwayFromZero) / scale
                    }

                    for row in 0..<rows {
                        for col in 0..<columns where isAlive(row: row, col: col) {
                            let baseOpacity = colorScheme == .dark ? 0.10 : 0.16
                            let flicker = baseOpacity + 0.10 * sin(time * 2.0 + Double(row * 3 + col) * 0.22)
                            let rect = CGRect(
                                x: snapToPixel(CGFloat(col) * cellWidth + xOffset),
                                y: snapToPixel(CGFloat(row) * cellHeight + yOffset),
                                width: snapToPixel(cellSize),
                                height: snapToPixel(cellSize)
                            )
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: rect.width * 0.5),
                                with: .color(PlatformPalette.gameOfLifeCell(colorScheme: colorScheme).opacity(max(0.0, flicker)))
                            )
                        }
                    }
                }
            }
            .onChange(of: tick) { _, _ in
                step()
            }
            .onAppear {
                if cells.isEmpty {
                    seed()
                }
            }
        }
    }

    private func index(row: Int, col: Int) -> Int {
        row * columns + col
    }

    private func isAlive(row: Int, col: Int) -> Bool {
        let wrappedRow = (row + rows) % rows
        let wrappedCol = (col + columns) % columns
        let idx = index(row: wrappedRow, col: wrappedCol)
        if idx < cells.count {
            return cells[idx]
        }
        return false
    }

    private func seed() {
        var rng = SystemRandomNumberGenerator()
        cells = (0..<(rows * columns)).map { _ in
            Double.random(in: 0...1, using: &rng) < 0.22
        }
        stepCount = 0
    }

    private func step() {
        guard !cells.isEmpty else {
            seed()
            return
        }

        var next = cells
        var aliveCount = 0

        for row in 0..<rows {
            for col in 0..<columns {
                let idx = index(row: row, col: col)
                let neighbors = neighborCount(row: row, col: col)
                let alive = cells[idx]
                let nextAlive = (alive && (neighbors == 2 || neighbors == 3)) || (!alive && neighbors == 3)
                next[idx] = nextAlive
                if nextAlive {
                    aliveCount += 1
                }
            }
        }

        stepCount += 1

        if aliveCount < max(6, (rows * columns) / 22) || stepCount > 120 {
            seed()
            return
        }

        cells = next
    }

    private func neighborCount(row: Int, col: Int) -> Int {
        var count = 0
        for dr in -1...1 {
            for dc in -1...1 where dr != 0 || dc != 0 {
                if isAlive(row: row + dr, col: col + dc) {
                    count += 1
                }
            }
        }
        return count
    }
}

private struct GlassInputPill<Content: View>: View {
    let height: CGFloat
    let alignment: Alignment
    let content: Content
    let onTap: () -> Void

    init(
        height: CGFloat,
        alignment: Alignment,
        @ViewBuilder content: () -> Content,
        onTap: @escaping () -> Void
    ) {
        self.height = height
        self.alignment = alignment
        self.content = content()
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: alignment)
        .frame(height: height)
        .mobileGlassPill()
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct PairingView: View {
    @Binding var pairingCode: String
    let connectionError: String?
    let connectPairingCode: () async -> Void
    let connectManualHost: (String, String, Int) async -> Void
    let cancelPairing: () -> Void
    let cancel: () -> Void
    @State private var isShowingScanner = false
    @State private var deviceName = UITestConfig.addDeviceName
        ?? L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac")
    @State private var host = UITestConfig.addDeviceHost ?? ""
    @State private var port = UITestConfig.addDevicePort ?? "\(CmxMobileDefaults.defaultHostPort)"
    @State private var authManager = AuthManager.shared
    @State private var validationError: String?
    @State private var isPairing = false
    @State private var pairingTaskID: UUID?
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var focusedField: AddDeviceField?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac"),
                        text: $deviceName
                    )
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .addDeviceInputBehavior(.text)
                    .accessibilityIdentifier("MobileAddDeviceNameField")

                    TextField(
                        L10n.string("mobile.addDevice.hostPlaceholder", defaultValue: "your-mac.tailnet.ts.net"),
                        text: $host
                    )
                    .focused($focusedField, equals: .host)
                    .submitLabel(.next)
                    .addDeviceInputBehavior(.url)
                    .accessibilityIdentifier("MobileAddDeviceHostField")

                    TextField(
                        L10n.string("mobile.addDevice.portPlaceholder", defaultValue: "58465"),
                        text: $port
                    )
                    .focused($focusedField, equals: .port)
                    .submitLabel(.done)
                    .addDeviceInputBehavior(.number)
                    .accessibilityIdentifier("MobileAddDevicePortField")
                } header: {
                    Text(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
                } footer: {
                    Text(L10n.string("mobile.addDevice.help", defaultValue: "Enter a Tailscale, LAN, or local host and port. QR/link pairing from that computer is still the safest setup path."))
                }
                .overlay(alignment: .topLeading) {
                    #if DEBUG
                    if UITestConfig.mockDataEnabled {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.string("mobile.addDevice.formAccessibilityLabel", defaultValue: "Add device form"))
                            .accessibilityIdentifier("MobileAddDeviceForm")
                    }
                    #endif
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: authManager.isAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark")
                            .font(.title3)
                            .foregroundStyle(authManager.isAuthenticated ? .green : .orange)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("mobile.addDevice.accountTitle", defaultValue: "This device"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(signedInAccountText)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("MobileAddDeviceSignedInAccount")

                            Text(L10n.string("mobile.addDevice.accountHelp", defaultValue: "Manual pairing uses this account. If it does not match the Mac, scan a QR/link from the Mac."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }

                #if os(iOS)
                Section {
                    Button {
                        isShowingScanner = true
                    } label: {
                        Label(L10n.string("mobile.pairing.scan", defaultValue: "Scan QR Code"), systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("MobileScanQRCodeButton")
                }
                #endif

                if let manualRouteWarningText {
                    Section {
                        Label {
                            Text(manualRouteWarningText)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("MobileManualRouteWarning")
                    }
                }

                if let errorText {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(errorText)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("MobilePairingError")
                            Text(signedInAccountText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("MobilePairingErrorSignedInAccount")
                        }
                    }
                }
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .safeAreaInset(edge: .bottom) {
                Button {
                    pair()
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        if isPairing {
                            ProgressView()
                        } else {
                            Text(L10n.string("mobile.addDevice.pair", defaultValue: "Pair"))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .disabled(isPairing || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("MobilePairButton")
                .padding(.horizontal)
                .padding(.bottom, 8)
                .padding(.top, 24)
                .background {
                    PlatformPalette.systemBackground
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
            .mobileInlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    cancelButton
                }
                #else
                ToolbarItem {
                    cancelButton
                }
                #endif
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingScanner) {
            MobilePairingScannerSheet { scannedCode in
                pairingCode = scannedCode
                isShowingScanner = false
                startPairingTask {
                    await connectPairingCode()
                }
            }
        }
        #endif
    }

    private var cancelButton: some View {
        Button {
            pairingTask?.cancel()
            pairingTaskID = nil
            pairingTask = nil
            isPairing = false
            cancelPairing()
            cancel()
        } label: {
            Text(L10n.string("mobile.common.cancel", defaultValue: "Cancel"))
        }
    }

    private var errorText: String? {
        validationError ?? connectionError
    }

    private var manualRouteWarningText: String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              !trimmedHost.hasPrefix("cmux-ios://"),
              MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning(trimmedHost) else {
            return nil
        }
        return L10n.string(
            "mobile.addDevice.manualRouteWarning",
            defaultValue: "This will connect directly to that address. Use this only on a trusted LAN, VPN, or device you control."
        )
    }

    private var signedInAccountText: String {
        guard authManager.isAuthenticated else {
            return L10n.string(
                "mobile.addDevice.notSignedIn",
                defaultValue: "Not signed in on this device."
            )
        }
        guard let email = authManager.currentUser?.primaryEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            return L10n.string(
                "mobile.addDevice.signedInUnknown",
                defaultValue: "Signed in, email unavailable."
            )
        }
        let format = L10n.string(
            "mobile.addDevice.signedInFormat",
            defaultValue: "Signed in as %@"
        )
        return String(format: format, email)
    }

    private func pair() {
        validationError = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        }
        if trimmedHost.hasPrefix("cmux-ios://") {
            pairingCode = trimmedHost
            startPairingTask {
                await connectPairingCode()
            }
            return
        }
        guard MobileShellRouteAuthPolicy.normalizedManualHost(trimmedHost) != nil else {
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        }
        guard let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(parsedPort) else {
            validationError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            return
        }

        startPairingTask {
            await connectManualHost(deviceName, trimmedHost, parsedPort)
        }
    }

    private func startPairingTask(_ operation: @escaping @MainActor () async -> Void) {
        pairingTask?.cancel()
        let taskID = UUID()
        pairingTaskID = taskID
        isPairing = true
        let task = Task { @MainActor in
            defer {
                if pairingTaskID == taskID {
                    isPairing = false
                    pairingTaskID = nil
                    pairingTask = nil
                }
            }
            await operation()
        }
        pairingTask = task
    }
}

private enum AddDeviceField: Hashable {
    case name
    case host
    case port
}

private enum AddDeviceInputKind {
    case text
    case url
    case number
}

#if os(iOS)
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationStatus {
                case .authorized:
                    QRCodeScannerView { code in
                        onCode(code)
                    }
                    .ignoresSafeArea(edges: .bottom)
                case .notDetermined:
                    ProgressView()
                        .task {
                            await requestCameraAccess()
                        }
                case .denied, .restricted:
                    ContentUnavailableView(
                        L10n.string("mobile.pairing.cameraDenied", defaultValue: "Camera Access Required"),
                        systemImage: "camera.fill"
                    )
                @unknown default:
                    ContentUnavailableView(
                        L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
                        systemImage: "camera.fill"
                    )
                }
            }
            .navigationTitle(L10n.string("mobile.pairing.scannerTitle", defaultValue: "Scan QR Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.string("mobile.pairing.scannerCancel", defaultValue: "Cancel"))
                    }
                    .accessibilityIdentifier("MobileScannerCancelButton")
                }
            }
        }
    }

    @MainActor
    private func requestCameraAccess() async {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        authorizationStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
    }
}

struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        private var didScan = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didScan,
                  let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  metadata.type == .qr,
                  let value = metadata.stringValue,
                  value.hasPrefix("cmux-ios://") else {
                return
            }
            didScan = true
            onCode(value)
        }
    }
}

final class QRCodeScannerViewController: UIViewController {
    private let coordinator: QRCodeScannerView.Coordinator
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.cmux.mobile.qr-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false

    init(coordinator: QRCodeScannerView.Coordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureSession() {
        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            showUnavailable()
            return
        }
        captureSession.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            showUnavailable()
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(coordinator, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        isConfigured = true
    }

    private func startSession() {
        guard isConfigured else { return }
        sessionQueue.async { [captureSession] in
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    private func stopSession() {
        guard isConfigured else { return }
        sessionQueue.async { [captureSession] in
            guard captureSession.isRunning else { return }
            captureSession.stopRunning()
        }
    }

    private func showUnavailable() {
        let label = UILabel()
        label.text = L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable")
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
#else
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void

    var body: some View {
        ContentUnavailableView(
            L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
            systemImage: "camera.fill"
        )
    }
}
#endif

struct WorkspaceShellView: View {
    @Bindable var store: CMUXMobileShellStore
    @State private var compactNavigationPath: [MobileWorkspacePreview.ID] = []
    @State private var pendingCompactCreateNavigationWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
    @State private var hasPresentedSplitDetail = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var usesCompactStack: Bool {
        #if os(iOS)
        MobileWorkspaceShellLayoutPolicy.usesCompactStack(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if usesCompactStack {
                stackLayout
            } else {
                splitLayout
            }
        }
        .onChange(of: usesCompactStack) { _, isCompact in
            guard isCompact, hasPresentedSplitDetail, let selectedWorkspaceID = store.selectedWorkspaceID else {
                return
            }
            compactNavigationPath = [selectedWorkspaceID]
        }
        .accessibilityIdentifier("MobileWorkspaceShell")
    }

    private var stackLayout: some View {
        NavigationStack(path: $compactNavigationPath) {
            WorkspaceListView(
                workspaces: store.workspaces,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                navigationStyle: .push,
                selectWorkspace: selectWorkspace,
                createWorkspace: createWorkspaceInCompactStack,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: { Task { await AuthManager.shared.signOut() } }
            )
            .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                workspaceDestination(for: workspaceID, createWorkspace: createWorkspaceInCompactStack)
            }
        }
        .onChange(of: store.selectedWorkspaceID) { _, selectedWorkspaceID in
            if let createdPath = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: selectedWorkspaceID,
                existingWorkspaceIDs: pendingCompactCreateNavigationWorkspaceIDs
            ) {
                pendingCompactCreateNavigationWorkspaceIDs = nil
                compactNavigationPath = createdPath
                autoOpenSelectedWorkspaceForSoakIfNeeded()
                return
            }
            compactNavigationPath = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: selectedWorkspaceID
            )
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        .onChange(of: compactNavigationPath) { _, path in
            guard let selectedWorkspaceID = path.last,
                  store.selectedWorkspaceID != selectedWorkspaceID else {
                return
            }
            store.selectedWorkspaceID = selectedWorkspaceID
        }
        .onChange(of: store.workspaces.map(\.id)) { _, workspaceIDs in
            compactNavigationPath.removeAll { !workspaceIDs.contains($0) }
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        .onAppear {
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            WorkspaceListView(
                workspaces: store.workspaces,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                navigationStyle: .sidebar,
                selectWorkspace: selectWorkspace,
                createWorkspace: store.createWorkspace,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: { Task { await AuthManager.shared.signOut() } }
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            workspaceDestination(
                for: store.selectedWorkspaceID,
                createWorkspace: store.createWorkspace,
                safeAreaContext: splitColumnVisibility == .detailOnly ? .fullWidth : .splitSidebarVisible
            )
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            hasPresentedSplitDetail = true
        }
    }

    private func selectWorkspace(_ id: MobileWorkspacePreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        store.selectedWorkspaceID = id
        if usesCompactStack, compactNavigationPath.last != id {
            compactNavigationPath = [id]
        }
    }

    private func createWorkspaceInCompactStack() {
        let existingWorkspaceIDs = Set(store.workspaces.map(\.id))
        pendingCompactCreateNavigationWorkspaceIDs = existingWorkspaceIDs
        store.createWorkspace()
        if let createdPath = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
            currentPath: compactNavigationPath,
            selectedWorkspaceID: store.selectedWorkspaceID,
            existingWorkspaceIDs: existingWorkspaceIDs
        ) {
            pendingCompactCreateNavigationWorkspaceIDs = nil
            compactNavigationPath = createdPath
        }
    }

    private func autoOpenSelectedWorkspaceForSoakIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE"] == "1",
              compactNavigationPath.isEmpty,
              let selectedWorkspaceID = store.selectedWorkspaceID,
              store.workspaces.contains(where: { $0.id == selectedWorkspaceID }) else {
            return
        }
        compactNavigationPath = [selectedWorkspaceID]
        #endif
    }

    @ViewBuilder
    private func workspaceDestination(
        for workspaceID: MobileWorkspacePreview.ID?,
        createWorkspace: @escaping () -> Void,
        safeAreaContext: MobileTerminalSafeAreaContext = .fullWidth
    ) -> some View {
        WorkspaceDetailContainer(
            store: store,
            workspaceID: workspaceID,
            createWorkspace: createWorkspace,
            safeAreaContext: safeAreaContext
        )
    }
}

enum WorkspaceShellCompactNavigationPolicy {
    static func pathForSelectionChange<ID: Hashable>(
        currentPath: [ID],
        selectedWorkspaceID: ID?
    ) -> [ID] {
        guard !currentPath.isEmpty else {
            return currentPath
        }
        guard let selectedWorkspaceID else {
            return []
        }
        guard currentPath.last != selectedWorkspaceID else {
            return currentPath
        }
        return [selectedWorkspaceID]
    }

    static func pathForCreatedWorkspaceSelection<ID: Hashable>(
        currentPath: [ID],
        selectedWorkspaceID: ID?,
        existingWorkspaceIDs: Set<ID>?
    ) -> [ID]? {
        guard let existingWorkspaceIDs,
              let selectedWorkspaceID,
              !existingWorkspaceIDs.contains(selectedWorkspaceID) else {
            return nil
        }
        guard currentPath.last != selectedWorkspaceID else {
            return currentPath
        }
        return [selectedWorkspaceID]
    }
}

enum MobileWorkspaceShellLayoutPolicy {
    static func usesCompactStack(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        horizontalSizeClass == .compact || verticalSizeClass == .compact
    }
}

enum WorkspaceNavigationStyle {
    case push
    case sidebar
}

private struct WorkspaceDetailContainer: View {
    @Bindable var store: CMUXMobileShellStore
    let workspaceID: MobileWorkspacePreview.ID?
    let createWorkspace: () -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext

    private var workspace: MobileWorkspacePreview? {
        if let workspaceID {
            return store.workspaces.first { $0.id == workspaceID } ?? store.selectedWorkspace
        }
        return store.selectedWorkspace
    }

    var body: some View {
        if let workspace {
            WorkspaceDetailView(
                host: store.connectedHostName,
                workspace: workspace,
                selectedTerminalID: Binding(
                    get: { store.selectedTerminalID },
                    set: { store.selectTerminal($0) }
                ),
                createWorkspace: createWorkspace,
                createTerminal: store.createTerminal,
                reportTerminalViewport: store.reportTerminalViewport,
                sendTerminalInput: store.sendTerminalRawInput,
                safeAreaContext: safeAreaContext
            )
            .onAppear {
                if store.selectedWorkspaceID != workspace.id {
                    store.selectedWorkspaceID = workspace.id
                }
            }
            .task(id: workspace.id) {
                await store.openWorkspace(workspace.id)
            }
        } else {
            ContentUnavailableView(
                L10n.string("mobile.workspace.emptyTitle", defaultValue: "No Workspace"),
                systemImage: "rectangle.stack"
            )
        }
    }
}

struct WorkspaceListView: View {
    let workspaces: [MobileWorkspacePreview]
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let host: String
    let navigationStyle: WorkspaceNavigationStyle
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let createWorkspace: () -> Void
    /// Optional: when present, the toolbar shows a "settings" menu offering
    /// "Rescan QR" (disconnect + re-pair) and "Sign out". When nil (e.g.
    /// previews), the menu is hidden.
    var rescanQR: (() -> Void)?
    var signOut: (() -> Void)?
    @State private var searchText = ""

    private var filteredWorkspaces: [MobileWorkspacePreview] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return workspaces
        }
        return workspaces.filter { workspace in
            workspace.name.localizedCaseInsensitiveContains(query)
                || workspace.previewLine.localizedCaseInsensitiveContains(query)
                || workspace.terminals.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredWorkspaces) { workspace in
                    WorkspaceNavigationRow(
                        workspace: workspace,
                        host: host,
                        isSelected: navigationStyle == .sidebar && selectedWorkspaceID == workspace.id,
                        navigationStyle: navigationStyle,
                        selectWorkspace: selectWorkspace
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
        .mobileInlineNavigationTitle()
        .searchable(text: $searchText)
        .toolbar {
            #if os(iOS)
            if rescanQR != nil || signOut != nil {
                ToolbarItem(placement: .topBarLeading) {
                    settingsMenu
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                newWorkspaceButton
            }
            #else
            ToolbarItem {
                newWorkspaceButton
            }
            #endif
        }
        .accessibilityIdentifier("MobileWorkspaceList")
    }

    private var newWorkspaceButton: some View {
        Button(action: createWorkspace) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    private var settingsMenu: some View {
        Menu {
            if let rescanQR {
                Button {
                    rescanQR()
                } label: {
                    Label(
                        L10n.string("mobile.workspaces.rescan", defaultValue: "Rescan QR"),
                        systemImage: "qrcode.viewfinder"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceRescanQRMenuItem")
            }
            if let signOut {
                Button(role: .destructive) {
                    signOut()
                } label: {
                    Label(
                        L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceSignOutMenuItem")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
    }
}

private struct WorkspaceNavigationRow: View {
    let workspace: MobileWorkspacePreview
    let host: String
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void

    var body: some View {
        Group {
            switch navigationStyle {
            case .push:
                NavigationLink(value: workspace.id) {
                    WorkspaceRow(workspace: workspace, host: host, isSelected: false)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    selectWorkspace(workspace.id)
                })
            case .sidebar:
                Button {
                    selectWorkspace(workspace.id)
                } label: {
                    WorkspaceRow(workspace: workspace, host: host, isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileWorkspaceRow-\(workspace.id.rawValue)")
        .accessibilityLabel(workspace.name)
        .accessibilityValue(workspace.accessibilitySummary(host: host))
    }
}

struct WorkspaceRow: View {
    let workspace: MobileWorkspacePreview
    let host: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkspaceAvatar(workspace: workspace)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(workspace.timestampOrStatus(host: host))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(workspace.previewLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(workspace.statusColor)
                        .frame(width: 7, height: 7)

                    Text(workspace.detailLine(host: host))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, isSelected ? 10 : 0)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }
}

private struct WorkspaceAvatar: View {
    let workspace: MobileWorkspacePreview

    var body: some View {
        ZStack {
            Circle()
                .fill(workspace.avatarGradient)
                .frame(width: 48, height: 48)

            Image(systemName: workspace.avatarSymbolName)
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
    }
}

private extension MobileWorkspacePreview {
    var previewLine: String {
        terminals
            .lazy
            .flatMap(\.lines)
            .reversed()
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? terminals.first?.name
            ?? name
    }

    var statusColor: Color {
        terminals.isEmpty ? .orange : .green
    }

    var avatarSymbolName: String {
        terminals.count > 1 ? "rectangle.stack.fill" : "terminal.fill"
    }

    var avatarGradient: LinearGradient {
        let palettes: [[Color]] = [
            [Color.blue, Color.cyan],
            [Color.green, Color.teal],
            [Color.orange, Color.yellow],
            [Color.gray, Color.blue],
        ]
        let colors = palettes[abs(stableAvatarSeed) % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func timestampOrStatus(host: String) -> String {
        let date = latestActivityDate
        guard date.timeIntervalSince1970 > 1 else {
            return host.isEmpty ? (terminals.first?.name ?? "") : host
        }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }

    func detailLine(host: String) -> String {
        let count = L10n.terminalCount(terminals.count)
        guard !host.isEmpty else {
            return count
        }
        return "\(host), \(count)"
    }

    func accessibilitySummary(host: String) -> String {
        "\(previewLine), \(detailLine(host: host))"
    }

    private var latestActivityDate: Date {
        terminals.map(\.snapshot.generatedAt).max() ?? .distantPast
    }

    private var stableAvatarSeed: Int {
        id.rawValue.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
    }
}

struct WorkspaceDetailView: View {
    let host: String
    let workspace: MobileWorkspacePreview
    @Binding var selectedTerminalID: MobileTerminalPreview.ID?
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    @State private var bottomActionModifierState = MobileTerminalModifierState()
    @State private var terminalFontScale: CGFloat = 1
    @State private var isTerminalKeyboardVisible = false
    @State private var terminalKeyboardOverlap: CGFloat = 0
    @State private var terminalInputFocusRequest = 0
    @State private var isTerminalPickerPresented = false

    private var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == selectedTerminalID } ?? workspace.terminals.first
    }

    var body: some View {
        detailContent()
    }

    private func detailContent() -> some View {
        VStack(spacing: 0) {
            TerminalPreviewSurface(
                terminal: selectedTerminal,
                fontScale: terminalFontScale,
                safeAreaContext: safeAreaContext,
                bottomOverlayHeight: terminalSurfaceBottomOverlayHeight,
                modifierState: $bottomActionModifierState,
                isKeyboardVisible: $isTerminalKeyboardVisible,
                inputFocusRequest: terminalInputFocusRequest,
                sendTerminalInput: sendTerminalInput,
                canDecreaseFont: terminalFontScale > Self.minimumTerminalFontScale,
                canIncreaseFont: terminalFontScale < Self.maximumTerminalFontScale,
                performBottomAction: performBottomAction,
                requestKeyboardFocus: requestTerminalKeyboardFocus,
                onViewportChange: { viewportSize in
                    guard let terminalID = selectedTerminal?.id else { return }
                    reportTerminalViewport(workspace.id, terminalID, viewportSize)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            #if !os(iOS)
            if MobileTerminalBottomBarVisibilityPolicy.showsInlineBar(isKeyboardVisible: isTerminalKeyboardVisible) {
                terminalBottomActionBar(
                    expandsSafeArea: MobileTerminalBottomBarPlacementPolicy.expandsBottomSafeArea(
                        isKeyboardVisible: isTerminalKeyboardVisible,
                        softwareKeyboardOverlap: terminalKeyboardOverlap
                    )
                )
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .overlay(alignment: .bottom) {
            if !isTerminalKeyboardVisible,
               MobileTerminalBottomBarVisibilityPolicy.showsInlineBar(isKeyboardVisible: isTerminalKeyboardVisible) {
                terminalBottomActionBar(
                    expandsSafeArea: inlineBottomBarExpandsSafeArea
                )
            }
        }
        .overlay {
            KeyboardOverlapReporter(overlap: $terminalKeyboardOverlap)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .mobileTerminalSafeAreaExpansion(
            context: safeAreaContext,
            includesBottom: MobileTerminalShellSafeAreaPolicy.expandsBehindBottomSafeArea(
                isKeyboardVisible: isTerminalKeyboardVisible
            )
        )
        .background {
            TerminalPalette.background
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        #else
        .background(TerminalPalette.background)
        #endif
        .navigationTitle(workspace.name)
        .mobileTerminalNavigationChrome()
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                newWorkspaceToolbarButton
                terminalPickerToolbarButton
            }
            #else
            ToolbarItem {
                terminalToolbarButtons
            }
        #endif
        }
    }

    private var inlineBottomBarExpandsSafeArea: Bool {
        inlineBottomBarOverlaysTerminal && MobileTerminalBottomBarPlacementPolicy.expandsBottomSafeArea(
            isKeyboardVisible: isTerminalKeyboardVisible,
            softwareKeyboardOverlap: terminalKeyboardOverlap
        )
    }

    private var inlineBottomBarOverlaysTerminal: Bool {
        !isTerminalKeyboardVisible
            && MobileTerminalBottomBarVisibilityPolicy.showsInlineBar(isKeyboardVisible: isTerminalKeyboardVisible)
    }

    private var terminalSurfaceBottomOverlayHeight: CGFloat {
        #if os(iOS)
        return inlineBottomBarOverlaysTerminal
            ? TerminalInputAccessoryVisualMetrics.barHeight
            : 0
        #else
        return 0
        #endif
    }

    private static let minimumTerminalFontScale: CGFloat = 0.8
    private static let maximumTerminalFontScale: CGFloat = 1.5
    private static let terminalFontScaleStep: CGFloat = 0.1

    private func terminalBottomActionBar(expandsSafeArea: Bool) -> some View {
        TerminalBottomActionBar(
            modifierState: bottomActionModifierState,
            canDecreaseFont: terminalFontScale > Self.minimumTerminalFontScale,
            canIncreaseFont: terminalFontScale < Self.maximumTerminalFontScale,
            safeAreaContext: safeAreaContext,
            expandsSafeArea: expandsSafeArea,
            performAction: performBottomAction
        )
    }

    private func performBottomAction(_ action: MobileTerminalBottomAction) {
        #if DEBUG
        mobileShellUILog.debug("bottom action tapped action=\(action.rawValue, privacy: .public)")
        #endif

        if let modifier = action.modifier {
            bottomActionModifierState.tap(modifier)
            return
        }

        switch action {
        case .hideKeyboard:
            isTerminalKeyboardVisible = false
            dismissKeyboard()
            bottomActionModifierState.clear()
        case .zoomOut:
            terminalFontScale = max(Self.minimumTerminalFontScale, terminalFontScale - Self.terminalFontScaleStep)
            bottomActionModifierState.clear()
        case .zoomIn:
            terminalFontScale = min(Self.maximumTerminalFontScale, terminalFontScale + Self.terminalFontScaleStep)
            bottomActionModifierState.clear()
        default:
            if let input = action.inputText(modifier: bottomActionModifierState.activeModifier) {
                sendTerminalInput(input)
                bottomActionModifierState.consumeAfterInput()
            }
        }
    }

    private func requestTerminalKeyboardFocus() {
        #if DEBUG
        mobileShellUILog.debug("workspace terminal keyboard focus requested")
        #endif
        terminalInputFocusRequest &+= 1
    }

    private func dismissKeyboard() {
        #if os(iOS)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.endEditing(true)
            }
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    @ViewBuilder
    private var terminalToolbarButtons: some View {
        newWorkspaceToolbarButton
        terminalPickerToolbarButton
    }

    private var newWorkspaceToolbarButton: some View {
        Button(action: createWorkspaceFromToolbar) {
            Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityIdentifier("MobileTerminalNewWorkspaceButton")
    }

    private var terminalPickerToolbarButton: some View {
        Button {
            dismissTerminalKeyboardForChrome()
            isTerminalPickerPresented = true
        } label: {
            Label(
                selectedTerminal?.name ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                systemImage: "terminal"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(host)
        .popover(isPresented: $isTerminalPickerPresented, arrowEdge: .top) {
            terminalPickerContent
        }
    }

    private var terminalPickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(workspace.terminals) { terminal in
                Button {
                    selectTerminalFromPicker(terminal.id)
                } label: {
                    Label(
                        terminal.name,
                        systemImage: terminal.id == selectedTerminal?.id ? "checkmark.circle.fill" : "terminal"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
            }

            Divider()
                .padding(.vertical, 4)

            Button(action: createWorkspaceFromTerminalPicker) {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

            Button(action: createTerminalFromToolbar) {
                Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileNewTerminalMenuItem")
        }
        .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    private func createWorkspaceFromToolbar() {
        dismissTerminalKeyboardForChrome()
        createWorkspace()
    }

    private func createWorkspaceFromTerminalPicker() {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        createWorkspace()
    }

    private func createTerminalFromToolbar() {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        createTerminal()
    }

    private func selectTerminalFromPicker(_ terminalID: MobileTerminalPreview.ID) {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        selectedTerminalID = terminalID
    }

    private func dismissTerminalKeyboardForChrome() {
        isTerminalKeyboardVisible = false
        dismissKeyboard()
    }
}

enum MobileTerminalActionModifier: String, Equatable, Sendable {
    case control
    case alternate
    case command
    case shift

    var accessibilityLabel: String {
        switch self {
        case .control:
            return L10n.string("mobile.terminal.action.control.label", defaultValue: "Control")
        case .alternate:
            return L10n.string("mobile.terminal.action.alt.label", defaultValue: "Alt")
        case .command:
            return L10n.string("mobile.terminal.action.command.label", defaultValue: "Command")
        case .shift:
            return L10n.string("mobile.terminal.action.shift.label", defaultValue: "Shift")
        }
    }
}

struct MobileTerminalModifierState: Equatable, Sendable {
    private struct LastTap: Equatable, Sendable {
        var modifier: MobileTerminalActionModifier
        var date: Date
    }

    static let stickyDoubleTapInterval: TimeInterval = 0.4

    private(set) var activeModifier: MobileTerminalActionModifier?
    private(set) var isSticky = false
    private var lastTap: LastTap?

    mutating func tap(
        _ modifier: MobileTerminalActionModifier,
        now: Date = Date()
    ) {
        if activeModifier == modifier, isSticky {
            clear()
            return
        }

        if activeModifier == modifier,
           let lastTap,
           lastTap.modifier == modifier,
           now.timeIntervalSince(lastTap.date) < Self.stickyDoubleTapInterval {
            isSticky = true
            self.lastTap = nil
            return
        }

        let shouldArm = activeModifier != modifier
        clear()
        if shouldArm {
            activeModifier = modifier
            isSticky = false
            lastTap = LastTap(modifier: modifier, date: now)
        }
    }

    mutating func consumeAfterInput() {
        guard !isSticky else { return }
        clear()
    }

    mutating func clear() {
        activeModifier = nil
        isSticky = false
        lastTap = nil
    }
}

enum MobileTerminalInputResolver {
    static func textInput(_ text: String, modifier: MobileTerminalActionModifier?) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        switch modifier {
        case .control:
            return controlSequence(for: normalized) ?? normalized
        case .alternate:
            return "\u{1B}" + normalized
        case .command:
            return commandTextSequence(for: normalized) ?? normalized
        case .shift:
            return normalized.uppercased()
        case nil:
            return normalized
        }
    }

    static func backspaceInput(modifier: MobileTerminalActionModifier?) -> String {
        switch modifier {
        case .command:
            return "\u{15}"
        case .alternate:
            return "\u{1B}\u{7F}"
        case .control, .shift, nil:
            return "\u{7F}"
        }
    }

    static func controlSequence(for text: String) -> String? {
        guard text.count == 1 else { return nil }
        switch text {
        case " ", "2":
            return "\u{00}"
        case "3":
            return "\u{1B}"
        case "4":
            return "\u{1C}"
        case "5":
            return "\u{1D}"
        case "6":
            return "\u{1E}"
        case "7", "/":
            return "\u{1F}"
        case "?":
            return "\u{7F}"
        default:
            break
        }

        guard let scalar = text.uppercased().unicodeScalars.first,
              text.unicodeScalars.count == 1,
              (0x40...0x5F).contains(scalar.value),
              let controlScalar = UnicodeScalar(scalar.value & 0x1F) else {
            return nil
        }
        return String(controlScalar)
    }

    private static func commandTextSequence(for text: String) -> String? {
        guard text.count == 1, let character = text.lowercased().first else {
            return nil
        }
        switch character {
        case "a":
            return "\u{01}"
        case "e":
            return "\u{05}"
        case "k":
            return "\u{0B}"
        case "u":
            return "\u{15}"
        case "w":
            return "\u{17}"
        case "l":
            return "\u{0C}"
        case "c":
            return "\u{03}"
        case "d":
            return "\u{04}"
        default:
            return nil
        }
    }
}

enum MobileTerminalBottomAction: String, CaseIterable, Identifiable, Equatable, Sendable {
    case hideKeyboard
    case control
    case escape
    case tab
    case returnKey
    case alternate
    case command
    case shift
    case zoomOut
    case zoomIn
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case claude
    case codex
    case tilde
    case pipe
    case ctrlC
    case ctrlD
    case ctrlZ
    case ctrlL
    case home
    case end
    case pageUp
    case pageDown

    static let scrollableActionBarCases = allCases.filter { $0 != .hideKeyboard }

    var id: String { rawValue }

    var modifier: MobileTerminalActionModifier? {
        switch self {
        case .control:
            return .control
        case .alternate:
            return .alternate
        case .command:
            return .command
        case .shift:
            return .shift
        default:
            return nil
        }
    }

    var hasTrailingDivider: Bool {
        switch self {
        case .shift, .zoomIn, .rightArrow, .codex, .pipe, .ctrlL:
            return true
        default:
            return false
        }
    }

    var accessibilityIdentifier: String {
        "MobileTerminalAction-\(rawValue)"
    }

    var title: String {
        switch self {
        case .hideKeyboard, .zoomOut, .zoomIn:
            return ""
        case .control:
            return L10n.string("mobile.terminal.action.control", defaultValue: "Ctrl")
        case .alternate:
            return L10n.string("mobile.terminal.action.alt", defaultValue: "Alt")
        case .command:
            return L10n.string("mobile.terminal.action.command", defaultValue: "⌘")
        case .shift:
            return L10n.string("mobile.terminal.action.shift", defaultValue: "⇧")
        case .escape:
            return L10n.string("mobile.terminal.action.escape", defaultValue: "Esc")
        case .tab:
            return L10n.string("mobile.terminal.action.tab", defaultValue: "Tab")
        case .returnKey:
            return L10n.string("mobile.terminal.action.return", defaultValue: "Return")
        case .upArrow:
            return L10n.string("mobile.terminal.action.up", defaultValue: "↑")
        case .downArrow:
            return L10n.string("mobile.terminal.action.down", defaultValue: "↓")
        case .leftArrow:
            return L10n.string("mobile.terminal.action.left", defaultValue: "←")
        case .rightArrow:
            return L10n.string("mobile.terminal.action.right", defaultValue: "→")
        case .claude:
            return L10n.string("mobile.terminal.action.claude", defaultValue: "Claude")
        case .codex:
            return L10n.string("mobile.terminal.action.codex", defaultValue: "Codex")
        case .tilde:
            return L10n.string("mobile.terminal.action.tilde", defaultValue: "~")
        case .pipe:
            return L10n.string("mobile.terminal.action.pipe", defaultValue: "|")
        case .ctrlC:
            return L10n.string("mobile.terminal.action.ctrlC", defaultValue: "^C")
        case .ctrlD:
            return L10n.string("mobile.terminal.action.ctrlD", defaultValue: "^D")
        case .ctrlZ:
            return L10n.string("mobile.terminal.action.ctrlZ", defaultValue: "^Z")
        case .ctrlL:
            return L10n.string("mobile.terminal.action.ctrlL", defaultValue: "^L")
        case .home:
            return L10n.string("mobile.terminal.action.home", defaultValue: "Home")
        case .end:
            return L10n.string("mobile.terminal.action.end", defaultValue: "End")
        case .pageUp:
            return L10n.string("mobile.terminal.action.pageUp", defaultValue: "PgUp")
        case .pageDown:
            return L10n.string("mobile.terminal.action.pageDown", defaultValue: "PgDn")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .hideKeyboard:
            return L10n.string("mobile.terminal.action.hideKeyboard.label", defaultValue: "Hide Keyboard")
        case .control:
            return L10n.string("mobile.terminal.action.control.label", defaultValue: "Control")
        case .alternate:
            return L10n.string("mobile.terminal.action.alt.label", defaultValue: "Alt")
        case .command:
            return L10n.string("mobile.terminal.action.command.label", defaultValue: "Command")
        case .shift:
            return L10n.string("mobile.terminal.action.shift.label", defaultValue: "Shift")
        case .zoomOut:
            return L10n.string("mobile.terminal.action.zoomOut.label", defaultValue: "Zoom Out")
        case .zoomIn:
            return L10n.string("mobile.terminal.action.zoomIn.label", defaultValue: "Zoom In")
        case .escape:
            return L10n.string("mobile.terminal.action.escape.label", defaultValue: "Escape")
        case .tab:
            return L10n.string("mobile.terminal.action.tab.label", defaultValue: "Tab")
        case .returnKey:
            return L10n.string("mobile.terminal.action.return.label", defaultValue: "Return")
        case .upArrow:
            return L10n.string("mobile.terminal.action.up.label", defaultValue: "Up Arrow")
        case .downArrow:
            return L10n.string("mobile.terminal.action.down.label", defaultValue: "Down Arrow")
        case .leftArrow:
            return L10n.string("mobile.terminal.action.left.label", defaultValue: "Left Arrow")
        case .rightArrow:
            return L10n.string("mobile.terminal.action.right.label", defaultValue: "Right Arrow")
        case .claude:
            return L10n.string("mobile.terminal.action.claude.label", defaultValue: "Insert Claude command")
        case .codex:
            return L10n.string("mobile.terminal.action.codex.label", defaultValue: "Insert Codex command")
        case .tilde:
            return L10n.string("mobile.terminal.action.tilde.label", defaultValue: "Tilde")
        case .pipe:
            return L10n.string("mobile.terminal.action.pipe.label", defaultValue: "Pipe")
        case .ctrlC:
            return L10n.string("mobile.terminal.action.ctrlC.label", defaultValue: "Control C")
        case .ctrlD:
            return L10n.string("mobile.terminal.action.ctrlD.label", defaultValue: "Control D")
        case .ctrlZ:
            return L10n.string("mobile.terminal.action.ctrlZ.label", defaultValue: "Control Z")
        case .ctrlL:
            return L10n.string("mobile.terminal.action.ctrlL.label", defaultValue: "Control L")
        case .home:
            return L10n.string("mobile.terminal.action.home.label", defaultValue: "Home")
        case .end:
            return L10n.string("mobile.terminal.action.end.label", defaultValue: "End")
        case .pageUp:
            return L10n.string("mobile.terminal.action.pageUp.label", defaultValue: "Page Up")
        case .pageDown:
            return L10n.string("mobile.terminal.action.pageDown.label", defaultValue: "Page Down")
        }
    }

    var symbolName: String? {
        switch self {
        case .hideKeyboard:
            return "keyboard.chevron.compact.down"
        case .zoomOut:
            return "minus.magnifyingglass"
        case .zoomIn:
            return "plus.magnifyingglass"
        default:
            return nil
        }
    }

    func inputText(modifier: MobileTerminalActionModifier?) -> String? {
        guard let baseText else { return nil }
        switch modifier {
        case .alternate:
            return alternateInputText(baseText: baseText)
        case .command:
            return commandInputText ?? baseText
        case .shift:
            return baseText
        case .control, nil:
            return baseText
        }
    }

    private var baseText: String? {
        switch self {
        case .hideKeyboard, .control, .alternate, .command, .shift, .zoomOut, .zoomIn:
            return nil
        case .escape:
            return "\u{1B}"
        case .tab:
            return "\t"
        case .returnKey:
            return "\r"
        case .tilde:
            return "~"
        case .pipe:
            return "|"
        case .ctrlC:
            return "\u{03}"
        case .ctrlD:
            return "\u{04}"
        case .ctrlZ:
            return "\u{1A}"
        case .ctrlL:
            return "\u{0C}"
        case .upArrow:
            return "\u{1B}[A"
        case .downArrow:
            return "\u{1B}[B"
        case .leftArrow:
            return "\u{1B}[D"
        case .rightArrow:
            return "\u{1B}[C"
        case .claude:
            return "claude --dangerously-skip-permissions\r"
        case .codex:
            return "codex --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort=xhigh --search\r"
        case .home:
            return "\u{1B}[H"
        case .end:
            return "\u{1B}[F"
        case .pageUp:
            return "\u{1B}[5~"
        case .pageDown:
            return "\u{1B}[6~"
        }
    }

    private func alternateInputText(baseText: String) -> String {
        switch self {
        case .leftArrow:
            return "\u{1B}b"
        case .rightArrow:
            return "\u{1B}f"
        default:
            return "\u{1B}" + baseText
        }
    }

    private var commandInputText: String? {
        switch self {
        case .leftArrow:
            return "\u{01}"
        case .rightArrow:
            return "\u{05}"
        default:
            return nil
        }
    }

}

enum TerminalInputAccessoryVisualMetrics {
    static let barHeight: CGFloat = 44
    static let horizontalInset: CGFloat = 16
    static let buttonHeight: CGFloat = 28
    static let buttonMinWidth: CGFloat = 44
    static let buttonHorizontalPadding: CGFloat = 10
    static let buttonCornerRadius: CGFloat = 6
    static let buttonSpacing: CGFloat = 6
    static let hideKeyboardWidth: CGFloat = 32
    static let hideKeyboardSymbolPointSize: CGFloat = 15
    static let nubSize: CGFloat = 34
    static let nubInnerDotSize: CGFloat = 12
    static let nubMaxOffset: CGFloat = 9
    static let nubDeadZone: CGFloat = 8
    static let hideKeyboardForeground = Color(red: 0.7, green: 0.7, blue: 0.7)
    static let buttonBackground = Color(red: 0.35, green: 0.35, blue: 0.35)
    static let selectedButtonBackground = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let nubBackground = Color(red: 0.25, green: 0.25, blue: 0.25).opacity(0.85)
    static let nubInnerDot = Color(red: 0.85, green: 0.85, blue: 0.85)
}

enum MobileTerminalBottomBarPlacementPolicy {
    private static let softwareKeyboardOverlapThreshold: CGFloat = 1

    static func expandsBottomSafeArea(
        isKeyboardVisible: Bool,
        softwareKeyboardOverlap: CGFloat = 0
    ) -> Bool {
        _ = isKeyboardVisible
        return softwareKeyboardOverlap <= softwareKeyboardOverlapThreshold
    }

    static func controlBottomOffset(
        safeAreaBottom: CGFloat,
        expandsSafeArea: Bool
    ) -> CGFloat {
        _ = safeAreaBottom
        _ = expandsSafeArea
        return 0
    }
}

enum MobileTerminalBottomBarVisibilityPolicy {
    static func showsInlineBar(isKeyboardVisible: Bool) -> Bool {
        true
    }
}

enum MobileTerminalShellSafeAreaPolicy {
    static func expandsBehindBottomSafeArea(isKeyboardVisible: Bool) -> Bool {
        !isKeyboardVisible
    }
}

enum TerminalVisibleAreaBorderPolicy {
    static func shouldDraw(viewportFit: MobileTerminalViewportFit?) -> Bool {
        edges(viewportFit: viewportFit).hasVisibleEdge
    }

    static func edges(viewportFit: MobileTerminalViewportFit?) -> TerminalVisibleAreaBorderEdges {
        TerminalVisibleAreaBorderEdges(
            drawRight: viewportFit?.shouldDrawVisibleAreaRightBorder == true,
            drawBottom: viewportFit?.shouldDrawVisibleAreaBottomBorder == true
        )
    }
}

struct TerminalVisibleAreaBorderEdges: Equatable, Sendable {
    var drawRight: Bool
    var drawBottom: Bool

    var hasVisibleEdge: Bool {
        drawRight || drawBottom
    }
}

enum TerminalBottomActionSelectionPolicy {
    static func isArmed(
        action: MobileTerminalBottomAction,
        modifierState: MobileTerminalModifierState
    ) -> Bool {
        guard let modifier = action.modifier else {
            return false
        }
        return modifier == modifierState.activeModifier
    }

    static func isSticky(
        action: MobileTerminalBottomAction,
        modifierState: MobileTerminalModifierState
    ) -> Bool {
        isArmed(action: action, modifierState: modifierState) && modifierState.isSticky
    }
}

private struct TerminalBottomActionBar: View {
    let modifierState: MobileTerminalModifierState
    let canDecreaseFont: Bool
    let canIncreaseFont: Bool
    let safeAreaContext: MobileTerminalSafeAreaContext
    let expandsSafeArea: Bool
    let performAction: (MobileTerminalBottomAction) -> Void

    @ViewBuilder
    var body: some View {
        let content = HStack(spacing: TerminalInputAccessoryVisualMetrics.buttonSpacing) {
            Button {
                performAction(.hideKeyboard)
            } label: {
                TerminalHideKeyboardGlyph()
                    .frame(
                        width: TerminalInputAccessoryVisualMetrics.hideKeyboardWidth,
                        height: TerminalInputAccessoryVisualMetrics.barHeight
                    )
                    .foregroundStyle(TerminalInputAccessoryVisualMetrics.hideKeyboardForeground)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MobileTerminalBottomAction.hideKeyboard.accessibilityLabel)
            .accessibilityIdentifier(MobileTerminalBottomAction.hideKeyboard.accessibilityIdentifier)
            .accessibilityAction {
                performAction(.hideKeyboard)
            }
            .highPriorityGesture(
                TapGesture().onEnded {
                    performAction(.hideKeyboard)
                }
            )
            .padding(.leading, TerminalInputAccessoryVisualMetrics.horizontalInset)

            TerminalArrowNubPad(
                sendArrow: { action in
                    performAction(action)
                }
            )

            ScrollView(.horizontal) {
                HStack(spacing: TerminalInputAccessoryVisualMetrics.buttonSpacing) {
                    ForEach(MobileTerminalBottomAction.scrollableActionBarCases) { action in
                        TerminalBottomActionButton(
                            action: action,
                            isArmed: isArmed(action),
                            isSticky: isSticky(action),
                            isEnabled: isEnabled(action)
                        ) {
                            performAction(action)
                        }
                    }
                }
                .padding(.trailing, TerminalInputAccessoryVisualMetrics.horizontalInset)
                .padding(.vertical, (TerminalInputAccessoryVisualMetrics.barHeight - TerminalInputAccessoryVisualMetrics.buttonHeight) / 2)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TerminalInputAccessoryVisualMetrics.barHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: MobileTerminalBottomBarPlacementPolicy.controlBottomOffset(
            safeAreaBottom: currentBottomInset,
            expandsSafeArea: expandsSafeArea
        ))
        .background {
            TerminalPalette.background
                .ignoresSafeArea(.container, edges: expandsSafeArea ? .bottom : [])
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TerminalPalette.dimForeground.opacity(0.18))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileTerminalBottomActionBar")
        .accessibilityValue(modifierState.accessibilityValue)
        if expandsSafeArea {
            #if os(iOS)
            content.mobileTerminalSafeAreaExpansion(context: safeAreaContext)
            #else
            content
            #endif
        } else {
            content
        }
    }

    private var currentBottomInset: CGFloat {
        #if os(iOS)
        MobileTerminalDeviceSafeArea.bottomInset
        #else
        0
        #endif
    }

    private func isEnabled(_ action: MobileTerminalBottomAction) -> Bool {
        switch action {
        case .zoomOut:
            return canDecreaseFont
        case .zoomIn:
            return canIncreaseFont
        default:
            return true
        }
    }

    private func isArmed(_ action: MobileTerminalBottomAction) -> Bool {
        TerminalBottomActionSelectionPolicy.isArmed(action: action, modifierState: modifierState)
    }

    private func isSticky(_ action: MobileTerminalBottomAction) -> Bool {
        TerminalBottomActionSelectionPolicy.isSticky(action: action, modifierState: modifierState)
    }
}

private struct TerminalHideKeyboardGlyph: View {
    var body: some View {
        Image(systemName: "keyboard.chevron.compact.down")
            .font(.system(size: TerminalInputAccessoryVisualMetrics.hideKeyboardSymbolPointSize, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .frame(width: TerminalInputAccessoryVisualMetrics.hideKeyboardWidth, height: TerminalInputAccessoryVisualMetrics.barHeight)
            .accessibilityHidden(true)
    }
}

private struct TerminalBottomActionButton: View {
    let action: MobileTerminalBottomAction
    let isArmed: Bool
    let isSticky: Bool
    let isEnabled: Bool
    let perform: () -> Void

    var body: some View {
        Button {
            guard isEnabled else { return }
            perform()
        } label: {
            if let symbolName = action.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .medium))
            } else {
                Text(action.title)
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .frame(
            minWidth: TerminalInputAccessoryVisualMetrics.buttonMinWidth,
            minHeight: TerminalInputAccessoryVisualMetrics.buttonHeight
        )
        .padding(.horizontal, TerminalInputAccessoryVisualMetrics.buttonHorizontalPadding)
        .foregroundStyle(isEnabled ? TerminalPalette.foreground : TerminalPalette.dimForeground.opacity(0.48))
        .background(buttonBackground)
        .clipShape(RoundedRectangle(cornerRadius: TerminalInputAccessoryVisualMetrics.buttonCornerRadius, style: .continuous))
        .overlay {
            if isSticky {
                RoundedRectangle(cornerRadius: TerminalInputAccessoryVisualMetrics.buttonCornerRadius, style: .continuous)
                    .stroke(TerminalPalette.foreground.opacity(0.85), lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(
            TapGesture().onEnded {
                guard isEnabled else { return }
                perform()
            }
        )
        .accessibilityLabel(action.accessibilityLabel)
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .accessibilityAddTraits(isArmed ? .isSelected : [])
        .accessibilityAction {
            guard isEnabled else { return }
            perform()
        }
    }

    private var buttonBackground: Color {
        if !isEnabled {
            return TerminalPalette.dimForeground.opacity(0.08)
        }
        if isSticky || isArmed {
            return TerminalInputAccessoryVisualMetrics.selectedButtonBackground
        }
        return TerminalInputAccessoryVisualMetrics.buttonBackground
    }
}

private struct TerminalArrowNubPad: View {
    let sendArrow: (MobileTerminalBottomAction) -> Void

    @GestureState private var dragOffset: CGSize = .zero
    @State private var repeatController = RepeatController()

    private enum Direction: String, CaseIterable {
        case up
        case down
        case left
        case right

        var action: MobileTerminalBottomAction {
            switch self {
            case .up:
                return .upArrow
            case .down:
                return .downArrow
            case .left:
                return .leftArrow
            case .right:
                return .rightArrow
            }
        }

    }

    private static let nubSize = TerminalInputAccessoryVisualMetrics.nubSize
    private static let maxOffset = TerminalInputAccessoryVisualMetrics.nubMaxOffset
    private static let deadZone = TerminalInputAccessoryVisualMetrics.nubDeadZone

    var body: some View {
        ZStack {
            Circle()
                .fill(TerminalInputAccessoryVisualMetrics.nubBackground)
                .overlay {
                    Circle()
                        .fill(TerminalInputAccessoryVisualMetrics.nubInnerDot)
                        .frame(
                            width: TerminalInputAccessoryVisualMetrics.nubInnerDotSize,
                            height: TerminalInputAccessoryVisualMetrics.nubInnerDotSize
                        )
                        .shadow(color: TerminalPalette.foreground.opacity(0.3), radius: 3, x: 0, y: 0)
                }
                .frame(width: Self.nubSize, height: Self.nubSize)
                .offset(clampedOffset(dragOffset))
        }
        .frame(width: Self.nubSize, height: Self.nubSize)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    repeatController.setDirection(direction(for: value.translation), sendArrow: sendArrow)
                }
                .onEnded { _ in
                    repeatController.stop()
                }
        )
        .onDisappear {
            repeatController.stop()
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.string("mobile.terminal.arrowPad.label", defaultValue: "Arrow pad"))
        .accessibilityIdentifier("MobileTerminalArrowNubPad")
        .accessibilityAction(named: Text(MobileTerminalBottomAction.upArrow.accessibilityLabel)) {
            sendArrow(.upArrow)
        }
        .accessibilityAction(named: Text(MobileTerminalBottomAction.downArrow.accessibilityLabel)) {
            sendArrow(.downArrow)
        }
        .accessibilityAction(named: Text(MobileTerminalBottomAction.leftArrow.accessibilityLabel)) {
            sendArrow(.leftArrow)
        }
        .accessibilityAction(named: Text(MobileTerminalBottomAction.rightArrow.accessibilityLabel)) {
            sendArrow(.rightArrow)
        }
    }

    private func direction(for translation: CGSize) -> Direction? {
        let distance = hypot(translation.width, translation.height)
        guard distance > Self.deadZone else {
            return nil
        }
        if abs(translation.width) > abs(translation.height) {
            return translation.width > 0 ? .right : .left
        }
        return translation.height > 0 ? .down : .up
    }

    private func clampedOffset(_ offset: CGSize) -> CGSize {
        CGSize(
            width: min(Self.maxOffset, max(-Self.maxOffset, offset.width)),
            height: min(Self.maxOffset, max(-Self.maxOffset, offset.height))
        )
    }

    private final class RepeatController {
        private static let initialRepeatDelay: TimeInterval = 0.08
        private static let repeatInterval: TimeInterval = 0.08

        private enum TimerKind {
            case initial
            case repeating
        }

        private var activeDirection: Direction?
        private var sendArrow: ((MobileTerminalBottomAction) -> Void)?
        private var initialTimer: Timer?
        private var repeatTimer: Timer?
        private var initialTimerTarget: TimerTarget?
        private var repeatTimerTarget: TimerTarget?

        deinit {
            invalidateTimers()
        }

        func setDirection(
            _ direction: Direction?,
            sendArrow: @escaping (MobileTerminalBottomAction) -> Void
        ) {
            guard direction != activeDirection else { return }
            invalidateTimers()
            activeDirection = direction
            self.sendArrow = sendArrow
            guard let direction else { return }
            sendArrow(direction.action)
            initialTimer = makeTimer(interval: Self.initialRepeatDelay, repeats: false, kind: .initial)
        }

        func stop() {
            activeDirection = nil
            sendArrow = nil
            invalidateTimers()
        }

        private func timerFired(kind: TimerKind) {
            guard let direction = activeDirection, let sendArrow else {
                stop()
                return
            }
            sendArrow(direction.action)
            if kind == .initial {
                initialTimer?.invalidate()
                initialTimer = nil
                initialTimerTarget = nil
                repeatTimer = makeTimer(interval: Self.repeatInterval, repeats: true, kind: .repeating)
            }
        }

        private func invalidateTimers() {
            initialTimer?.invalidate()
            initialTimer = nil
            repeatTimer?.invalidate()
            repeatTimer = nil
            initialTimerTarget = nil
            repeatTimerTarget = nil
        }

        private func makeTimer(
            interval: TimeInterval,
            repeats: Bool,
            kind: TimerKind
        ) -> Timer {
            let target = TimerTarget(controller: self, kind: kind)
            let timer = Timer(
                timeInterval: interval,
                target: target,
                selector: #selector(TimerTarget.fire(_:)),
                userInfo: nil,
                repeats: repeats
            )
            timer.tolerance = interval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            switch kind {
            case .initial:
                initialTimerTarget = target
            case .repeating:
                repeatTimerTarget = target
            }
            return timer
        }

        private final class TimerTarget: NSObject {
            weak var controller: RepeatController?
            let kind: TimerKind

            init(controller: RepeatController, kind: TimerKind) {
                self.controller = controller
                self.kind = kind
            }

            @objc
            func fire(_ timer: Timer) {
                controller?.timerFired(kind: kind)
            }
        }
    }
}

private extension MobileTerminalModifierState {
    var accessibilityValue: String {
        guard let activeModifier else { return "" }
        if isSticky {
            return String(
                format: L10n.string("mobile.terminal.modifier.stickyFormat", defaultValue: "%@ sticky"),
                activeModifier.accessibilityLabel
            )
        }
        return activeModifier.accessibilityLabel
    }
}

private enum TerminalPalette {
    static let background = Color(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x22 / 255.0)
    static let foreground = Color(red: 0xf8 / 255.0, green: 0xf8 / 255.0, blue: 0xf2 / 255.0)
    static let dimForeground = Color(red: 0xc8 / 255.0, green: 0xc8 / 255.0, blue: 0xc0 / 255.0)
}

private enum PlatformPalette {
    static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.white
        #endif
    }

    static var separator: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #elseif os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color.gray
        #endif
    }

    static func gameOfLifeCell(colorScheme: ColorScheme) -> Color {
        #if os(iOS)
        Color(uiColor: colorScheme == .dark ? .systemGray4 : .systemGray2)
        #elseif os(macOS)
        Color(nsColor: colorScheme == .dark ? .systemGray : .secondaryLabelColor)
        #else
        Color.gray
        #endif
    }
}

struct TerminalPreviewSurface: View {
    let terminal: MobileTerminalPreview?
    var fontScale: CGFloat = 1
    var safeAreaContext: MobileTerminalSafeAreaContext = .fullWidth
    var bottomOverlayHeight: CGFloat = 0
    var modifierState: Binding<MobileTerminalModifierState>?
    var isKeyboardVisible: Binding<Bool>?
    var inputFocusRequest = 0
    var sendTerminalInput: (String) -> Void = { _ in }
    var canDecreaseFont = true
    var canIncreaseFont = true
    var performBottomAction: (MobileTerminalBottomAction) -> Void = { _ in }
    var requestKeyboardFocus: () -> Void = {}
    var onViewportChange: (MobileTerminalViewportSize) -> Void = { _ in }
    @Environment(\.displayScale) private var displayScale
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var renderedRows: [MobileTerminalGhosttyRow] {
        guard let terminal else {
            return []
        }
        return terminal.snapshot.visibleRows
    }

    private var columnCount: Int {
        if let columns = terminal?.snapshot.gridSize.columns {
            return max(1, columns)
        }
        return max(1, renderedRows.map(\.cells.count).max() ?? 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let visibleSize = visibleTerminalSize(proxy: proxy)
            let viewportSize = TerminalViewportMetrics.viewportSize(for: visibleSize, fontScale: fontScale)
            let keyboardVisible = isKeyboardVisible?.wrappedValue ?? false
            let metrics = TerminalViewportMetrics(
                size: visibleSize,
                columns: columnCount,
                rows: max(1, renderedRows.count),
                fontScale: fontScale
            )
            let contentInsets = terminalContentInsets(proxy: proxy)
            ZStack(alignment: .topLeading) {
                TerminalPalette.background

                TerminalFittedViewportGrid(
                    rows: renderedRows,
                    columnCount: columnCount,
                    cursor: terminal?.snapshot.cursor,
                    fontScale: fontScale
                )
                .frame(width: visibleSize.width, height: visibleSize.height, alignment: .topLeading)
                .offset(x: contentInsets.leading, y: 0)

                let borderEdges = TerminalVisibleAreaBorderPolicy.edges(viewportFit: terminal?.viewportFit)
                if borderEdges.hasVisibleEdge {
                    TerminalVisibleAreaBorder(
                        edges: borderEdges,
                        metrics: metrics,
                        containerSize: visibleSize,
                        displayScale: displayScale
                    )
                    .offset(x: contentInsets.leading, y: 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in
                        focusTerminalInput()
                    }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        focusTerminalInput()
                    }
            )
            .task(id: viewportReportKey(proxy: proxy, keyboardVisible: keyboardVisible)) {
                onViewportChange(viewportSize)
            }
            .onAppear {
                onViewportChange(viewportSize)
            }
            .onChange(of: visibleSize) { _, _ in
                onViewportChange(viewportSize)
            }
            .onChange(of: fontScale) { _, _ in
                onViewportChange(viewportSize)
            }
            .onChange(of: keyboardVisible) { _, _ in
                onViewportChange(viewportSize)
            }
        }
        .foregroundStyle(TerminalPalette.foreground)
        .overlay {
            #if os(iOS)
            if let modifierState, let isKeyboardVisible {
                TerminalHiddenInputProxy(
                    modifierState: modifierState,
                    isKeyboardVisible: isKeyboardVisible,
                    focusRequest: inputFocusRequest,
                    canDecreaseFont: canDecreaseFont,
                    canIncreaseFont: canIncreaseFont,
                    sendTerminalInput: sendTerminalInput,
                    performBottomAction: performBottomAction
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("MobileTerminalInputProxy")
                .allowsHitTesting(false)
            }
            #endif
            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("MobileTerminalSurface")
                .allowsHitTesting(false)
        }
    }

    private func viewportReportKey(proxy: GeometryProxy, keyboardVisible: Bool) -> String {
        let viewportSize = TerminalViewportMetrics.viewportSize(for: visibleTerminalSize(proxy: proxy), fontScale: fontScale)
        let scaleKey = Int((TerminalViewportMetrics.clampedFontScale(fontScale) * 100).rounded())
        let keyboardKey = keyboardVisible ? "keyboard" : "no-keyboard"
        return "\(terminal?.id.rawValue ?? "none"):\(viewportSize.columns)x\(viewportSize.rows):\(scaleKey):\(keyboardKey)"
    }

    private func focusTerminalInput() {
        #if DEBUG
        mobileShellUILog.debug("terminal surface focus requested")
        #endif
        isKeyboardVisible?.wrappedValue = true
        requestKeyboardFocus()
    }

    private func visibleTerminalSize(proxy: GeometryProxy) -> CGSize {
        let contentInsets = terminalContentInsets(proxy: proxy)
        let reservedBottomHeight = max(0, bottomOverlayHeight)
        return CGSize(
            width: max(1, proxy.size.width - contentInsets.leading - contentInsets.trailing),
            height: max(1, proxy.size.height - reservedBottomHeight)
        )
    }

    private func terminalContentInsets(proxy: GeometryProxy) -> MobileTerminalContentInsets {
        #if os(iOS)
        let safeAreaInsets = MobileTerminalDeviceSafeArea.horizontalInsets(fallback: proxy.safeAreaInsets)
        let symmetricCameraEdge = MobileTerminalDeviceSafeArea.landscapeCameraEdge
        #else
        let safeAreaInsets = proxy.safeAreaInsets
        let symmetricCameraEdge = MobileTerminalLandscapeCameraEdge.trailing
        #endif
        return MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: safeAreaContext,
            hasCompactVerticalSize: verticalSizeClass == .compact,
            safeAreaInsets: safeAreaInsets,
            symmetricCameraEdge: symmetricCameraEdge
        )
    }
}

enum MobileTerminalSafeAreaContext: Equatable, Sendable {
    case fullWidth
    case splitSidebarVisible
}

struct MobileTerminalSafeAreaExpansionEdges: Equatable, Sendable {
    var horizontal: Bool
    var bottom: Bool

    var hasEdges: Bool {
        horizontal || bottom
    }

    var edgeSet: Edge.Set {
        var edges: Edge.Set = []
        if horizontal {
            edges.formUnion(.horizontal)
        }
        if bottom {
            edges.formUnion(.bottom)
        }
        return edges
    }
}

enum MobileTerminalSafeAreaExpansionPolicy {
    static func edges(
        context: MobileTerminalSafeAreaContext,
        hasCompactVerticalSize: Bool,
        includesBottom: Bool = true
    ) -> MobileTerminalSafeAreaExpansionEdges {
        switch context {
        case .fullWidth:
            return MobileTerminalSafeAreaExpansionEdges(
                horizontal: hasCompactVerticalSize,
                bottom: includesBottom
            )
        case .splitSidebarVisible:
            return MobileTerminalSafeAreaExpansionEdges(
                horizontal: false,
                bottom: includesBottom
            )
        }
    }
}

struct MobileTerminalContentInsets: Equatable, Sendable {
    static let zero = MobileTerminalContentInsets(leading: 0, trailing: 0)

    var leading: CGFloat
    var trailing: CGFloat
}

enum MobileTerminalContentSafeAreaPolicy {
    private static let landscapeCameraInsetThreshold: CGFloat = 32
    private static let landscapeCameraInsetDeltaThreshold: CGFloat = 8

    static func horizontalInsets(
        context: MobileTerminalSafeAreaContext,
        hasCompactVerticalSize: Bool,
        safeAreaInsets: EdgeInsets,
        symmetricCameraEdge: MobileTerminalLandscapeCameraEdge = .trailing
    ) -> MobileTerminalContentInsets {
        guard context == .fullWidth, hasCompactVerticalSize else {
            return .zero
        }
        let leading = max(0, safeAreaInsets.leading)
        let trailing = max(0, safeAreaInsets.trailing)
        let largestInset = max(leading, trailing)
        guard largestInset >= landscapeCameraInsetThreshold else {
            return .zero
        }
        let insetDelta = abs(leading - trailing)
        if insetDelta >= landscapeCameraInsetDeltaThreshold {
            if leading > trailing {
                return MobileTerminalContentInsets(leading: insetDelta, trailing: 0)
            }
            return MobileTerminalContentInsets(leading: 0, trailing: insetDelta)
        }

        switch symmetricCameraEdge {
        case .leading:
            return MobileTerminalContentInsets(leading: largestInset, trailing: 0)
        case .trailing:
            return MobileTerminalContentInsets(leading: 0, trailing: largestInset)
        case .none:
            return .zero
        }
    }
}

enum MobileTerminalLandscapeCameraEdge: Equatable, Sendable {
    case leading
    case trailing
    case none
}

enum MobileTerminalWindowOrientation: Equatable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case unknown
}

enum MobileTerminalLandscapeCameraEdgeResolver {
    static func edge(for orientation: MobileTerminalWindowOrientation) -> MobileTerminalLandscapeCameraEdge {
        switch orientation {
        case .landscapeLeft:
            return .trailing
        case .landscapeRight:
            return .leading
        case .portrait, .portraitUpsideDown, .unknown:
            return .trailing
        }
    }
}

#if os(iOS)
private struct MobileCompactLandscapeTerminalSafeAreaCompensation: ViewModifier {
    let context: MobileTerminalSafeAreaContext
    let includesBottom: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        let edges = MobileTerminalSafeAreaExpansionPolicy.edges(
            context: context,
            hasCompactVerticalSize: verticalSizeClass == .compact,
            includesBottom: includesBottom
        )
        if edges.hasEdges {
            content
                .ignoresSafeArea(.container, edges: edges.edgeSet)
        } else {
            content
        }
    }
}

private extension View {
    func mobileTerminalSafeAreaExpansion(
        context: MobileTerminalSafeAreaContext,
        includesBottom: Bool = true
    ) -> some View {
        modifier(MobileCompactLandscapeTerminalSafeAreaCompensation(
            context: context,
            includesBottom: includesBottom
        ))
    }
}

@MainActor
private enum MobileTerminalDeviceSafeArea {
    static var landscapeCameraEdge: MobileTerminalLandscapeCameraEdge {
        MobileTerminalLandscapeCameraEdgeResolver.edge(for: windowOrientation)
    }

    static var bottomInset: CGFloat {
        if let keyWindow {
            return keyWindow.safeAreaInsets.bottom
        }
        return 0
    }

    static func horizontalInsets(fallback: EdgeInsets) -> EdgeInsets {
        if let keyWindow {
            let insets = keyWindow.safeAreaInsets
            return EdgeInsets(
                top: insets.top,
                leading: insets.left,
                bottom: insets.bottom,
                trailing: insets.right
            )
        }
        return fallback
    }

    private static var windowOrientation: MobileTerminalWindowOrientation {
        guard let windowScene = keyWindow?.windowScene else {
            return .unknown
        }
        switch windowScene.interfaceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private static var keyWindow: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.windows.first(where: \.isKeyWindow) {
                return window
            }
        }
        return nil
    }
}

private struct TerminalUIKitBottomActionBar: UIViewRepresentable {
    let modifierState: MobileTerminalModifierState
    let canDecreaseFont: Bool
    let canIncreaseFont: Bool
    let performAction: (MobileTerminalBottomAction) -> Void

    func makeUIView(context: Context) -> TerminalUIKitInputAccessoryView {
        let view = TerminalUIKitInputAccessoryView()
        view.performAction = performAction
        view.configure(
            modifierState: modifierState,
            canDecreaseFont: canDecreaseFont,
            canIncreaseFont: canIncreaseFont
        )
        return view
    }

    func updateUIView(_ uiView: TerminalUIKitInputAccessoryView, context: Context) {
        uiView.performAction = performAction
        uiView.configure(
            modifierState: modifierState,
            canDecreaseFont: canDecreaseFont,
            canIncreaseFont: canIncreaseFont
        )
    }
}

private struct KeyboardOverlapReporter: UIViewRepresentable {
    @Binding var overlap: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(overlap: $overlap)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.overlap = $overlap
        context.coordinator.view = uiView
        context.coordinator.updateOverlap()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        var overlap: Binding<CGFloat>
        weak var view: UIView?
        private var keyboardFrame: CGRect = .zero
        private var isObserving = false

        init(overlap: Binding<CGFloat>) {
            self.overlap = overlap
        }

        func start() {
            guard !isObserving else { return }
            let center = NotificationCenter.default
            let notifications: [Notification.Name] = [
                UIResponder.keyboardWillChangeFrameNotification,
                UIResponder.keyboardDidChangeFrameNotification,
                UIResponder.keyboardWillHideNotification,
                UIResponder.keyboardDidHideNotification,
            ]
            for name in notifications {
                center.addObserver(
                    self,
                    selector: #selector(handleKeyboardNotification(_:)),
                    name: name,
                    object: nil
                )
            }
            isObserving = true
        }

        func stop() {
            NotificationCenter.default.removeObserver(self)
            isObserving = false
        }

        @objc
        private func handleKeyboardNotification(_ notification: Notification) {
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardFrame = frame
            }
            let userInfo = notification.userInfo
            let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
            let curveRaw = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? -1
            updateOverlap(animationDuration: duration, curveRaw: curveRaw)
        }

        func updateOverlap(animationDuration: Double = 0, curveRaw: Int = -1) {
            let nextOverlap = computeOverlap()
            if animationDuration > 0 {
                withAnimation(Self.animation(duration: animationDuration, curveRaw: curveRaw)) {
                    overlap.wrappedValue = nextOverlap
                }
            } else {
                overlap.wrappedValue = nextOverlap
            }
        }

        private func computeOverlap() -> CGFloat {
            guard let view,
                  let window = view.window,
                  keyboardFrame != .zero else {
                return 0
            }
            let localKeyboardFrame = window.convert(keyboardFrame, from: nil)
            let rawOverlap = max(0, window.bounds.maxY - localKeyboardFrame.minY)
            let visibleShortSide = min(window.bounds.width, window.bounds.height)
            let maximumUsableOverlap = visibleShortSide * 0.46
            return min(rawOverlap, maximumUsableOverlap)
        }

        private static func animation(duration: Double, curveRaw: Int) -> Animation {
            switch curveRaw {
            case 0: return .easeInOut(duration: duration)
            case 1: return .easeIn(duration: duration)
            case 2: return .easeOut(duration: duration)
            case 3: return .linear(duration: duration)
            default:
                // UIKit's private keyboard curve (raw 7) lands closest to a
                // cubic ease with these control points.
                return .timingCurve(0.17, 0.17, 0.0, 1.0, duration: duration)
            }
        }
    }
}

private struct TerminalHiddenInputProxy: UIViewRepresentable {
    @Binding var modifierState: MobileTerminalModifierState
    @Binding var isKeyboardVisible: Bool
    let focusRequest: Int
    let canDecreaseFont: Bool
    let canIncreaseFont: Bool
    let sendTerminalInput: (String) -> Void
    let performBottomAction: (MobileTerminalBottomAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            modifierState: $modifierState,
            isKeyboardVisible: $isKeyboardVisible,
            focusRequest: focusRequest,
            sendTerminalInput: sendTerminalInput,
            performBottomAction: performBottomAction
        )
    }

    func makeUIView(context: Context) -> TerminalHiddenInputContainerView {
        let container = TerminalHiddenInputContainerView()
        let textView = container.textView
        textView.onText = { text in
            context.coordinator.emitText(text)
        }
        textView.onBackspace = {
            context.coordinator.emitBackspace()
        }
        textView.onRawInput = { input in
            context.coordinator.emitRawInput(input)
        }
        textView.onKeyboardVisibilityChange = { isVisible in
            context.coordinator.setKeyboardVisible(isVisible)
        }
        textView.onFocusRequested = {
            context.coordinator.requestKeyboard()
        }
        textView.allowsAutomaticKeyboardFocus = isKeyboardVisible
        textView.configureInputAccessory(
            modifierState: modifierState,
            canDecreaseFont: canDecreaseFont,
            canIncreaseFont: canIncreaseFont,
            performAction: context.coordinator.performAccessoryAction
        )
        container.onFocusRequested = {
            context.coordinator.requestKeyboard()
        }
        container.accessibilityLabel = L10n.string("mobile.terminal.inputProxy.label", defaultValue: "Terminal input")
        container.accessibilityIdentifier = "MobileTerminalInputProxy"
        return container
    }

    func updateUIView(_ uiView: TerminalHiddenInputContainerView, context: Context) {
        context.coordinator.modifierState = $modifierState
        context.coordinator.isKeyboardVisible = $isKeyboardVisible
        context.coordinator.sendTerminalInput = sendTerminalInput
        context.coordinator.performBottomAction = performBottomAction
        let textView = uiView.textView
        uiView.accessibilityLabel = L10n.string("mobile.terminal.inputProxy.label", defaultValue: "Terminal input")
        uiView.accessibilityIdentifier = "MobileTerminalInputProxy"
        uiView.onFocusRequested = {
            context.coordinator.requestKeyboard()
        }
        textView.allowsAutomaticKeyboardFocus = isKeyboardVisible
        textView.configureInputAccessory(
            modifierState: modifierState,
            canDecreaseFont: canDecreaseFont,
            canIncreaseFont: canIncreaseFont,
            performAction: context.coordinator.performAccessoryAction
        )
        if context.coordinator.consumeFocusRequest(focusRequest) {
            #if DEBUG
            mobileShellUILog.debug("terminal input focus requested token=\(focusRequest, privacy: .public)")
            #endif
            uiView.requestKeyboardFocus()
        } else if isKeyboardVisible {
            if !textView.isFirstResponder {
                uiView.requestKeyboardFocus()
            }
        } else if textView.isFirstResponder {
            _ = textView.resignFirstResponder()
        }
    }

    final class Coordinator {
        var modifierState: Binding<MobileTerminalModifierState>
        var isKeyboardVisible: Binding<Bool>
        var sendTerminalInput: (String) -> Void
        var performBottomAction: (MobileTerminalBottomAction) -> Void
        private var lastFocusRequest: Int

        init(
            modifierState: Binding<MobileTerminalModifierState>,
            isKeyboardVisible: Binding<Bool>,
            focusRequest: Int,
            sendTerminalInput: @escaping (String) -> Void,
            performBottomAction: @escaping (MobileTerminalBottomAction) -> Void
        ) {
            self.modifierState = modifierState
            self.isKeyboardVisible = isKeyboardVisible
            self.lastFocusRequest = focusRequest
            self.sendTerminalInput = sendTerminalInput
            self.performBottomAction = performBottomAction
        }

        func requestKeyboard() {
            isKeyboardVisible.wrappedValue = true
        }

        func setKeyboardVisible(_ isVisible: Bool) {
            isKeyboardVisible.wrappedValue = isVisible
        }

        func consumeFocusRequest(_ focusRequest: Int) -> Bool {
            guard focusRequest != lastFocusRequest else { return false }
            lastFocusRequest = focusRequest
            return true
        }

        func emitText(_ text: String) {
            guard !text.isEmpty else { return }
            #if DEBUG
            mobileShellUILog.debug("terminal text input count=\(text.count, privacy: .public)")
            #endif
            let input = MobileTerminalInputResolver.textInput(
                text,
                modifier: modifierState.wrappedValue.activeModifier
            )
            sendTerminalInput(input)
            modifierState.wrappedValue.consumeAfterInput()
        }

        func emitBackspace() {
            #if DEBUG
            mobileShellUILog.debug("terminal backspace input")
            #endif
            let input = MobileTerminalInputResolver.backspaceInput(
                modifier: modifierState.wrappedValue.activeModifier
            )
            sendTerminalInput(input)
            modifierState.wrappedValue.consumeAfterInput()
        }

        func emitRawInput(_ input: String) {
            guard !input.isEmpty else { return }
            #if DEBUG
            mobileShellUILog.debug("terminal raw input count=\(input.count, privacy: .public)")
            #endif
            sendTerminalInput(input)
            modifierState.wrappedValue.consumeAfterInput()
        }

        func performAccessoryAction(_ action: MobileTerminalBottomAction) {
            #if DEBUG
            mobileShellUILog.debug("terminal input accessory action=\(action.rawValue, privacy: .public)")
            #endif
            performBottomAction(action)
        }

    }
}

@MainActor
private final class TerminalHiddenInputContainerView: UIView {
    let textView = TerminalHiddenInputTextView()
    var onFocusRequested: (() -> Void)?

    override var canBecomeFirstResponder: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits.insert(.allowsDirectInteraction)

        addSubview(textView)
        textView.isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        requestKeyboardFocus()
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        requestKeyboardFocus()
        super.touchesEnded(touches, with: event)
    }

    override func accessibilityActivate() -> Bool {
        requestKeyboardFocus()
        return true
    }

    func requestKeyboardFocus() {
        #if DEBUG
        mobileShellUILog.debug("terminal input container focus requested")
        #endif
        textView.requestKeyboardFocus()
        onFocusRequested?()
    }
}

@MainActor
private final class TerminalHiddenInputTextView: UITextView, UITextViewDelegate {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onRawInput: ((String) -> Void)?
    var onKeyboardVisibilityChange: ((Bool) -> Void)?
    var onFocusRequested: (() -> Void)?
    var allowsAutomaticKeyboardFocus = false
    private let terminalInputAccessoryView = TerminalUIKitInputAccessoryView()
    private lazy var focusTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? {
        get { terminalInputAccessoryView }
        set {}
    }

    override var keyCommands: [UIKeyCommand]? {
        guard markedTextRange == nil else { return nil }
        return MobileTerminalHardwareKeyResolver.makeKeyCommands(
            target: self,
            action: #selector(handleHardwareKeyCommand(_:))
        )
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardType = .default
        returnKeyType = .default
        textContainerInset = .zero
        isScrollEnabled = false
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits.remove(.keyboardKey)
        delegate = self
        text = ""
        addGestureRecognizer(focusTapRecognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        #if DEBUG
        mobileShellUILog.debug("terminal input textView insertText count=\(text.count, privacy: .public)")
        #endif
        if markedTextRange != nil {
            super.insertText(text)
            return
        }
        onText?(text)
    }

    override func deleteBackward() {
        if markedTextRange != nil || hasText {
            super.deleteBackward()
            return
        }
        onBackspace?()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        #if DEBUG
        mobileShellUILog.debug("terminal input textView touchesBegan")
        #endif
        requestKeyboardFocus()
        super.touchesBegan(touches, with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, allowsAutomaticKeyboardFocus else { return }
        requestKeyboardFocus()
    }

    override func accessibilityActivate() -> Bool {
        #if DEBUG
        mobileShellUILog.debug("terminal input textView accessibilityActivate")
        #endif
        requestKeyboardFocus()
        return true
    }

    @objc
    private func handleFocusTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        requestKeyboardFocus()
    }

    func requestKeyboardFocus() {
        allowsAutomaticKeyboardFocus = true
        let focused = becomeFirstResponder()
        #if DEBUG
        mobileShellUILog.debug("terminal input textView becomeFirstResponder result=\(focused, privacy: .public)")
        #endif
        onFocusRequested?()
    }

    func configureInputAccessory(
        modifierState: MobileTerminalModifierState,
        canDecreaseFont: Bool,
        canIncreaseFont: Bool,
        performAction: @escaping (MobileTerminalBottomAction) -> Void
    ) {
        terminalInputAccessoryView.performAction = performAction
        terminalInputAccessoryView.configure(
            modifierState: modifierState,
            canDecreaseFont: canDecreaseFont,
            canIncreaseFont: canIncreaseFont
        )
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onKeyboardVisibilityChange?(true)
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            onKeyboardVisibilityChange?(false)
        }
        return resignedFirstResponder
    }

    override func paste(_ sender: Any?) {
        guard let pastedText = UIPasteboard.general.string,
              !pastedText.isEmpty else {
            return
        }
        onText?(pastedText)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard textView.markedTextRange == nil else { return }
        let committedText = textView.text ?? ""
        guard !committedText.isEmpty else { return }
        textView.text = ""
        onText?(committedText)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        #if DEBUG
        mobileShellUILog.debug("terminal input textView didBeginEditing")
        #endif
        onKeyboardVisibilityChange?(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        #if DEBUG
        mobileShellUILog.debug("terminal input textView didEndEditing")
        #endif
        onKeyboardVisibilityChange?(false)
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard textView.markedTextRange == nil else { return true }
        guard text == "\n" || text == "\r" else { return true }
        onRawInput?("\r")
        return false
    }

    @objc
    private func handleHardwareKeyCommand(_ sender: UIKeyCommand) {
        guard let input = sender.input,
              let output = MobileTerminalHardwareKeyResolver.input(
                input,
                modifierFlags: sender.modifierFlags
              ) else {
            return
        }
        onRawInput?(output)
    }
}

private final class TerminalUIKitInputAccessoryView: UIView {
    var performAction: ((MobileTerminalBottomAction) -> Void)?

    private let topBorder = UIView()
    private let hideKeyboardButton = TerminalUIKitActionButton(action: .hideKeyboard)
    private let arrowNub = TerminalUIKitArrowNubControl()
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var actionButtons: [MobileTerminalBottomAction: TerminalUIKitActionButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: CGRect(
            x: 0,
            y: 0,
            width: UIScreen.main.bounds.width,
            height: TerminalInputAccessoryVisualMetrics.barHeight
        ))
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: TerminalInputAccessoryVisualMetrics.barHeight
        )
    }

    func configure(
        modifierState: MobileTerminalModifierState,
        canDecreaseFont: Bool,
        canIncreaseFont: Bool
    ) {
        for (action, button) in actionButtons {
            let enabled: Bool
            switch action {
            case .zoomOut:
                enabled = canDecreaseFont
            case .zoomIn:
                enabled = canIncreaseFont
            default:
                enabled = true
            }
            let isArmed = TerminalBottomActionSelectionPolicy.isArmed(action: action, modifierState: modifierState)
            let isSticky = TerminalBottomActionSelectionPolicy.isSticky(action: action, modifierState: modifierState)
            button.configure(enabled: enabled, isArmed: isArmed, isSticky: isSticky)
        }
    }

    private func setup() {
        backgroundColor = TerminalUIKitPalette.background
        isOpaque = true

        topBorder.backgroundColor = TerminalUIKitPalette.dimForeground.withAlphaComponent(0.18)
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        configureButton(hideKeyboardButton)
        hideKeyboardButton.widthAnchor.constraint(equalToConstant: TerminalInputAccessoryVisualMetrics.hideKeyboardWidth).isActive = true
        hideKeyboardButton.heightAnchor.constraint(equalToConstant: TerminalInputAccessoryVisualMetrics.barHeight).isActive = true
        addSubview(hideKeyboardButton)

        arrowNub.performAction = { [weak self] action in
            self?.performAction?(action)
        }
        arrowNub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arrowNub)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = TerminalInputAccessoryVisualMetrics.buttonSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        for action in MobileTerminalBottomAction.scrollableActionBarCases {
            let button = TerminalUIKitActionButton(action: action)
            configureButton(button)
            button.heightAnchor.constraint(equalToConstant: TerminalInputAccessoryVisualMetrics.buttonHeight).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: TerminalInputAccessoryVisualMetrics.buttonMinWidth + TerminalInputAccessoryVisualMetrics.buttonHorizontalPadding * 2).isActive = true
            actionButtons[action] = button
            stackView.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            hideKeyboardButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TerminalInputAccessoryVisualMetrics.horizontalInset),
            hideKeyboardButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            arrowNub.leadingAnchor.constraint(equalTo: hideKeyboardButton.trailingAnchor, constant: TerminalInputAccessoryVisualMetrics.buttonSpacing),
            arrowNub.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowNub.widthAnchor.constraint(equalToConstant: TerminalInputAccessoryVisualMetrics.nubSize),
            arrowNub.heightAnchor.constraint(equalToConstant: TerminalInputAccessoryVisualMetrics.nubSize),

            scrollView.leadingAnchor.constraint(equalTo: arrowNub.trailingAnchor, constant: TerminalInputAccessoryVisualMetrics.buttonSpacing),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -TerminalInputAccessoryVisualMetrics.horizontalInset),
            stackView.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor),
            stackView.heightAnchor.constraint(equalToConstant: TerminalInputAccessoryVisualMetrics.buttonHeight),
        ])
    }

    private func configureButton(_ button: TerminalUIKitActionButton) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.activate = { [weak self] action in
            self?.performAction?(action)
        }
        button.configure(enabled: true, isArmed: false, isSticky: false)
    }
}

private final class TerminalUIKitActionButton: UIButton {
    let action: MobileTerminalBottomAction
    var activate: ((MobileTerminalBottomAction) -> Void)?

    init(action: MobileTerminalBottomAction) {
        self.action = action
        super.init(frame: .zero)
        layer.cornerCurve = .continuous
        layer.cornerRadius = TerminalInputAccessoryVisualMetrics.buttonCornerRadius
        titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.75
        if action == .hideKeyboard {
            imageView?.contentMode = .scaleAspectFit
            let configuration = UIImage.SymbolConfiguration(
                pointSize: TerminalInputAccessoryVisualMetrics.hideKeyboardSymbolPointSize,
                weight: .medium
            )
            setImage(UIImage(systemName: "keyboard.chevron.compact.down", withConfiguration: configuration), for: .normal)
            setPreferredSymbolConfiguration(configuration, forImageIn: .normal)
        } else if let symbolName = action.symbolName {
            setImage(UIImage(systemName: symbolName), for: .normal)
        } else {
            setTitle(action.title, for: .normal)
        }
        accessibilityLabel = action.accessibilityLabel
        accessibilityIdentifier = action.accessibilityIdentifier
        addTarget(self, action: #selector(handleActivation), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(enabled: Bool, isArmed: Bool, isSticky: Bool) {
        isEnabled = enabled
        let foreground = enabled ? TerminalUIKitPalette.foreground : TerminalUIKitPalette.dimForeground.withAlphaComponent(0.48)
        tintColor = foreground
        setTitleColor(foreground, for: .normal)
        backgroundColor = Self.backgroundColor(enabled: enabled, isArmed: isArmed, isSticky: isSticky)
        layer.borderColor = TerminalUIKitPalette.foreground.withAlphaComponent(0.85).cgColor
        layer.borderWidth = isSticky ? 2 : 0
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        triggerAction()
        return true
    }

    @objc
    private func handleActivation() {
        triggerAction()
    }

    private func triggerAction() {
        guard isEnabled else { return }
        activate?(action)
    }

    private static func backgroundColor(enabled: Bool, isArmed: Bool, isSticky: Bool) -> UIColor {
        guard enabled else {
            return TerminalUIKitPalette.dimForeground.withAlphaComponent(0.08)
        }
        if isArmed || isSticky {
            return TerminalUIKitPalette.selectedButtonBackground
        }
        return TerminalUIKitPalette.buttonBackground
    }
}

private final class TerminalUIKitArrowNubControl: UIControl {
    var performAction: ((MobileTerminalBottomAction) -> Void)?
    private let innerDot = UIView()
    private var initialTouch: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TerminalUIKitPalette.nubBackground
        layer.cornerCurve = .continuous
        innerDot.backgroundColor = TerminalUIKitPalette.nubInnerDot
        innerDot.translatesAutoresizingMaskIntoConstraints = false
        innerDot.layer.cornerRadius = TerminalInputAccessoryVisualMetrics.nubInnerDotSize / 2
        addSubview(innerDot)
        NSLayoutConstraint.activate([
            innerDot.centerXAnchor.constraint(equalTo: centerXAnchor),
            innerDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            innerDot.widthAnchor.constraint(equalToConstant: TerminalInputAccessoryVisualMetrics.nubInnerDotSize),
            innerDot.heightAnchor.constraint(equalToConstant: TerminalInputAccessoryVisualMetrics.nubInnerDotSize),
        ])
        accessibilityLabel = L10n.string("mobile.terminal.arrowPad.label", defaultValue: "Arrow pad")
        accessibilityIdentifier = "MobileTerminalArrowNubPad"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        initialTouch = touches.first?.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let initialTouch,
              let current = touches.first?.location(in: self),
              let action = action(for: CGPoint(x: current.x - initialTouch.x, y: current.y - initialTouch.y)) else {
            return
        }
        performAction?(action)
        self.initialTouch = current
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        initialTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        initialTouch = nil
    }

    private func action(for translation: CGPoint) -> MobileTerminalBottomAction? {
        let distance = hypot(translation.x, translation.y)
        guard distance > TerminalInputAccessoryVisualMetrics.nubDeadZone else {
            return nil
        }
        if abs(translation.x) > abs(translation.y) {
            return translation.x > 0 ? .rightArrow : .leftArrow
        }
        return translation.y > 0 ? .downArrow : .upArrow
    }
}

private enum TerminalUIKitPalette {
    static let background = UIColor(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x22 / 255.0, alpha: 1)
    static let foreground = UIColor(red: 0xf8 / 255.0, green: 0xf8 / 255.0, blue: 0xf2 / 255.0, alpha: 1)
    static let dimForeground = UIColor(red: 0xc8 / 255.0, green: 0xc8 / 255.0, blue: 0xc0 / 255.0, alpha: 1)
    static let buttonBackground = UIColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1)
    static let selectedButtonBackground = UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1)
    static let nubBackground = UIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 0.85)
    static let nubInnerDot = UIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
}

enum MobileTerminalHardwareKeyResolver {
    private struct Command {
        var input: String
        var modifierFlags: UIKeyModifierFlags
    }

    private static let baseCommands: [Command] = [
        Command(input: UIKeyCommand.inputUpArrow, modifierFlags: UIKeyModifierFlags()),
        Command(input: UIKeyCommand.inputDownArrow, modifierFlags: UIKeyModifierFlags()),
        Command(input: UIKeyCommand.inputLeftArrow, modifierFlags: UIKeyModifierFlags()),
        Command(input: UIKeyCommand.inputRightArrow, modifierFlags: UIKeyModifierFlags()),
        Command(input: UIKeyCommand.inputLeftArrow, modifierFlags: .alternate),
        Command(input: UIKeyCommand.inputRightArrow, modifierFlags: .alternate),
        Command(input: UIKeyCommand.inputHome, modifierFlags: UIKeyModifierFlags()),
        Command(input: UIKeyCommand.inputEnd, modifierFlags: UIKeyModifierFlags()),
        Command(input: UIKeyCommand.inputPageUp, modifierFlags: UIKeyModifierFlags()),
        Command(input: UIKeyCommand.inputPageDown, modifierFlags: UIKeyModifierFlags()),
        Command(input: UIKeyCommand.inputDelete, modifierFlags: .alternate),
        Command(input: UIKeyCommand.inputEscape, modifierFlags: UIKeyModifierFlags()),
        Command(input: "\r", modifierFlags: UIKeyModifierFlags()),
        Command(input: "\n", modifierFlags: UIKeyModifierFlags()),
        Command(input: "\t", modifierFlags: UIKeyModifierFlags()),
        Command(input: "\t", modifierFlags: .shift),
    ]

    private static let commands: [Command] =
        baseCommands
        + controlInputs.map { Command(input: $0, modifierFlags: .control) }
        + shiftedControlInputs.map { Command(input: $0, modifierFlags: [.control, .shift]) }

    private static let controlInputs = "abcdefghijklmnopqrstuvwxyz[]\\ 234567/".map { String($0) }
    private static let shiftedControlInputs = "@^_?".map { String($0) }

    @MainActor
    static func makeKeyCommands(target: Any, action: Selector) -> [UIKeyCommand] {
        commands.map { command in
            UIKeyCommand(
                input: command.input,
                modifierFlags: command.modifierFlags,
                action: action
            )
        }
    }

    static func input(_ input: String, modifierFlags: UIKeyModifierFlags) -> String? {
        let normalizedFlags = modifierFlags.intersection([.shift, .control, .alternate])
        switch (input, normalizedFlags) {
        case (UIKeyCommand.inputLeftArrow, [.alternate]):
            return "\u{1B}b"
        case (UIKeyCommand.inputRightArrow, [.alternate]):
            return "\u{1B}f"
        case (UIKeyCommand.inputUpArrow, []):
            return "\u{1B}[A"
        case (UIKeyCommand.inputDownArrow, []):
            return "\u{1B}[B"
        case (UIKeyCommand.inputRightArrow, []):
            return "\u{1B}[C"
        case (UIKeyCommand.inputLeftArrow, []):
            return "\u{1B}[D"
        case (UIKeyCommand.inputHome, []):
            return "\u{1B}[H"
        case (UIKeyCommand.inputEnd, []):
            return "\u{1B}[F"
        case (UIKeyCommand.inputPageUp, []):
            return "\u{1B}[5~"
        case (UIKeyCommand.inputPageDown, []):
            return "\u{1B}[6~"
        case (UIKeyCommand.inputDelete, [.alternate]):
            return "\u{1B}\u{7F}"
        case (UIKeyCommand.inputEscape, []):
            return "\u{1B}"
        case ("\r", []), ("\n", []):
            return "\r"
        case ("\t", []):
            return "\t"
        case ("\t", [.shift]):
            return "\u{1B}[Z"
        case let (input, flags) where flags == [.control] || flags == [.control, .shift]:
            return MobileTerminalInputResolver.controlSequence(for: input)
        default:
            return nil
        }
    }
}
#endif

private struct TerminalFittedViewportGrid: View {
    let rows: [MobileTerminalGhosttyRow]
    let columnCount: Int
    let cursor: MobileTerminalGhosttyCursor?
    let fontScale: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let metrics = TerminalViewportMetrics(
                size: proxy.size,
                columns: columnCount,
                rows: max(1, rows.count),
                fontScale: fontScale
            )

            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    TerminalStyledRowView(
                        row: rows[index],
                        rowIndex: index,
                        cursor: cursor(forVisibleRowAt: index),
                        columnCount: columnCount,
                        metrics: metrics
                    )
                }
            }
            .frame(width: metrics.gridWidth, height: metrics.gridHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    private func cursor(forVisibleRowAt index: Int) -> MobileTerminalGhosttyCursor? {
        guard let cursor,
              cursor.isVisible,
              index == cursor.row else {
            return nil
        }
        return cursor
    }
}

private struct TerminalVisibleAreaBorder: View {
    let edges: TerminalVisibleAreaBorderEdges
    let metrics: TerminalViewportMetrics
    let containerSize: CGSize
    let displayScale: CGFloat

    var body: some View {
        let lineWidth = max(3 / max(1, displayScale), 1.75)
        let width = min(metrics.gridWidth, containerSize.width)
        let height = min(metrics.gridHeight, containerSize.height)
        let borderColor = TerminalPalette.foreground.opacity(0.58)

        ZStack(alignment: .topLeading) {
            if edges.drawRight {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: lineWidth, height: height)
                    .frame(width: width, height: height, alignment: .topTrailing)
            }

            if edges.drawBottom {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: width, height: lineWidth)
                    .frame(width: width, height: height, alignment: .bottomLeading)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TerminalViewportMetrics {
    let cellWidth: CGFloat
    let rowHeight: CGFloat
    let fontSize: CGFloat
    let gridWidth: CGFloat
    let gridHeight: CGFloat

    static let preferredFontSize: CGFloat = 12
    static let preferredCellWidth: CGFloat = 7.4
    static let preferredRowHeight: CGFloat = 14

    init(size: CGSize, columns: Int, rows: Int, fontScale: CGFloat = 1) {
        let resolvedColumns = max(1, columns)
        let resolvedRows = max(1, rows)
        let scale = Self.clampedFontScale(fontScale)
        cellWidth = Self.preferredCellWidth * scale
        rowHeight = Self.preferredRowHeight * scale
        fontSize = Self.preferredFontSize * scale
        gridWidth = cellWidth * CGFloat(resolvedColumns)
        gridHeight = rowHeight * CGFloat(resolvedRows)
    }

    static func viewportSize(for size: CGSize, fontScale: CGFloat = 1) -> MobileTerminalViewportSize {
        let scale = clampedFontScale(fontScale)
        let columns = max(20, Int(floor(max(1, size.width) / (preferredCellWidth * scale))))
        let rows = max(5, Int(floor(max(1, size.height) / (preferredRowHeight * scale))))
        return MobileTerminalViewportSize(columns: columns, rows: rows)
    }

    static func clampedFontScale(_ scale: CGFloat) -> CGFloat {
        min(1.5, max(0.8, scale))
    }
}

private struct TerminalStyledRowView: View {
    let row: MobileTerminalGhosttyRow
    let rowIndex: Int
    let cursor: MobileTerminalGhosttyCursor?
    let columnCount: Int
    let metrics: TerminalViewportMetrics

    private var cells: [MobileTerminalGhosttyCell] {
        TerminalRowCellProjection.cells(
            from: row,
            preservingCursorColumn: cursor?.column,
            minimumColumnCount: columnCount
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(cells.prefix(columnCount).enumerated()), id: \.offset) { column, cell in
                TerminalCellView(
                    cell: cell,
                    cursorStyle: column == cursor?.column ? cursor?.style : nil,
                    metrics: metrics
                )
            }
        }
        .frame(width: metrics.gridWidth, height: metrics.rowHeight, alignment: .leading)
        .lineLimit(1)
        .clipped()
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.trimmedPlainText)
        .accessibilityIdentifier("MobileTerminalRow-\(rowIndex)")
        .accessibilityValue(hasVisibleCursor ? "cursor-column-\(cursor?.column ?? 0)" : "")
    }

    private var hasVisibleCursor: Bool {
        guard let cursor else { return false }
        return cursor.isVisible && rowIndex == cursor.row
    }
}

struct TerminalRowCellProjection {
    static func cells(
        from row: MobileTerminalGhosttyRow,
        preservingCursorColumn cursorColumn: Int?,
        minimumColumnCount: Int = 1
    ) -> [MobileTerminalGhosttyCell] {
        var lastVisibleIndex: Int?

        for index in row.cells.indices {
            let cell = row.cells[index]
            switch cell.width {
            case .spacerHead, .spacerTail:
                continue
            case .narrow, .wide:
                let text = cell.text.isEmpty ? " " : cell.text
                if text != " " {
                    lastVisibleIndex = index
                }
            }
        }

        if let cursorColumn,
           row.cells.indices.contains(cursorColumn) {
            lastVisibleIndex = max(lastVisibleIndex ?? cursorColumn, cursorColumn)
        }

        let minimumLastIndex = max(0, minimumColumnCount - 1)
        let resolvedLastIndex = max(lastVisibleIndex ?? 0, minimumLastIndex)

        if row.cells.count > resolvedLastIndex {
            return Array(row.cells.prefix(resolvedLastIndex + 1))
        }

        return row.cells + Array(
            repeating: MobileTerminalGhosttyCell(text: " "),
            count: resolvedLastIndex + 1 - row.cells.count
        )
    }
}

enum TerminalCellLayoutPolicy {
    static func columnSpan(for width: MobileTerminalGhosttyCellWidth) -> Int {
        switch width {
        case .narrow:
            return 1
        case .wide:
            return 2
        case .spacerHead, .spacerTail:
            return 0
        }
    }
}

private struct TerminalCellView: View {
    let cell: MobileTerminalGhosttyCell
    let cursorStyle: MobileTerminalGhosttyCursor.Style?
    let metrics: TerminalViewportMetrics

    private var text: String {
        switch cell.width {
        case .spacerHead, .spacerTail:
            return cursorStyle == nil ? "" : " "
        case .narrow, .wide:
            return cell.text.isEmpty ? " " : cell.text
        }
    }

    private var foreground: Color {
        if cell.style.inverse {
            return cell.style.background?.terminalColor ?? TerminalPalette.background
        }
        return cell.style.foreground?.terminalColor ?? TerminalPalette.foreground
    }

    private var background: Color {
        if cell.style.inverse {
            return cell.style.foreground?.terminalColor ?? TerminalPalette.foreground
        }
        return cell.style.background?.terminalColor ?? .clear
    }

    private var displayedForeground: Color {
        switch cursorStyle {
        case .block:
            return TerminalPalette.background
        case .hollowBlock, .bar, .underline, nil:
            return cell.style.dim ? foreground.opacity(0.62) : foreground
        }
    }

    private var displayedBackground: Color {
        switch cursorStyle {
        case .block:
            return TerminalPalette.foreground
        case .hollowBlock, .bar, .underline, nil:
            return background
        }
    }

    private var cellWidth: CGFloat {
        metrics.cellWidth * CGFloat(TerminalCellLayoutPolicy.columnSpan(for: cell.width))
    }

    var body: some View {
        Text(text)
            .font(.system(size: metrics.fontSize, weight: cell.style.bold ? .bold : .regular, design: .monospaced))
            .foregroundStyle(displayedForeground)
            .frame(width: cellWidth, height: metrics.rowHeight, alignment: .center)
            .background(displayedBackground)
            .underline(cell.style.underline != .none, color: foreground)
            .overlay(alignment: .leading) {
                if cursorStyle == .bar {
                    Rectangle()
                        .fill(TerminalPalette.foreground)
                        .frame(width: max(1, metrics.cellWidth * 0.18))
                }
            }
            .overlay(alignment: .bottom) {
                if cursorStyle == .underline {
                    Rectangle()
                        .fill(TerminalPalette.foreground)
                        .frame(height: max(1, metrics.rowHeight * 0.12))
                }
            }
            .overlay {
                if cursorStyle == .hollowBlock {
                    Rectangle()
                        .stroke(TerminalPalette.foreground, lineWidth: 1)
                }
            }
    }
}

private extension MobileTerminalGhosttyColor {
    var terminalColor: Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }
}

enum L10n {
    static func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .main)
    }

    static func terminalCount(_ count: Int) -> String {
        if count == 1 {
            return string("mobile.workspace.terminalCountFormat.one", defaultValue: "1 terminal")
        }
        return String(format: string("mobile.workspace.terminalCountFormat.other", defaultValue: "%d terminals"), count)
    }

    static func workspaceName(index: Int) -> String {
        String(format: string("mobile.preview.workspaceNameFormat", defaultValue: "Workspace %d"), index)
    }

    static func terminalName(index: Int) -> String {
        String(format: string("mobile.preview.terminalNameFormat", defaultValue: "Terminal %d"), index)
    }
}

private extension View {
    @ViewBuilder
    func mobilePlainTextInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileEmailTextInput() -> some View {
        #if os(iOS)
        self
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileOneTimeCodeInput() -> some View {
        #if os(iOS)
        self
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
        #else
        self
        #endif
    }

    @ViewBuilder
    func addDeviceInputBehavior(_ kind: AddDeviceInputKind) -> some View {
        #if os(iOS)
        switch kind {
        case .text:
            self
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        case .url:
            self
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .number:
            self
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileTerminalNavigationChrome() -> some View {
        #if os(iOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileGlassButton() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        #else
        self
            .buttonStyle(.bordered)
            .controlSize(.large)
        #endif
    }

    @ViewBuilder
    func mobileGlassProminentButton() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        #else
        self
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        #endif
    }

    @ViewBuilder
    func mobileGlassPill() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        #else
        self
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        #endif
    }
}
