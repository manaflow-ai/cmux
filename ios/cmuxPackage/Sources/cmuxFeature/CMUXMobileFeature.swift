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

@MainActor
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
                WorkspaceShellView(store: store, signOut: signOut)
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
            let startedUITestAttachURL = connectUITestAttachURLIfNeeded()
            if !startedUITestAttachURL,
               MobileRootAuthGate.shouldReconnectStoredMac(
                stackAuthenticated: authManager.isAuthenticated,
                attachTicketAuthenticated: hasActiveAttachTicketAuthentication,
                connectionState: store.connectionState
            ) {
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

    @discardableResult
    private func connectUITestAttachURLIfNeeded() -> Bool {
        #if DEBUG
        guard UITestConfig.mockDataEnabled,
              !didConsumeUITestAttachURL,
              isAuthenticated,
              let attachURL = UITestConfig.attachURL else {
            return false
        }
        didConsumeUITestAttachURL = true
        Task {
            await store.connectPairingURL(attachURL)
        }
        return true
        #else
        return false
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

    static func shouldReconnectStoredMac(
        stackAuthenticated: Bool,
        attachTicketAuthenticated: Bool,
        connectionState: MobileConnectionState
    ) -> Bool {
        stackAuthenticated && !attachTicketAuthenticated && connectionState != .connected
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
    let signOut: () -> Void
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
                signOut: signOut
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
                signOut: signOut
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
                store: store,
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
        terminals.first?.name ?? name
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

    private var latestActivityDate: Date { .distantPast }

private var stableAvatarSeed: Int {
        id.rawValue.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
    }
}

struct WorkspaceDetailView: View {
    let host: String
    let workspace: MobileWorkspacePreview
    @Bindable var store: CMUXMobileShellStore
    @Binding var selectedTerminalID: MobileTerminalPreview.ID?
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    @State private var isTerminalPickerPresented = false

    private var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == selectedTerminalID } ?? workspace.terminals.first
    }

    var body: some View {
        detailContent()
    }

    private func detailContent() -> some View {
        // libghostty owns the bottom input accessory bar: it ships with
        // `GhosttySurfaceView`'s `inputAccessoryView` (see
        // `TerminalInputAccessoryAction`). The SwiftUI bar that used to
        // live here has been removed so the two stacked toolbars from
        // dogfood iosfin no longer fight for the same screen edge.
        Group {
            #if os(iOS)
            if let terminalID = selectedTerminal?.id.rawValue {
                GhosttySurfaceRepresentable(
                    surfaceID: terminalID,
                    store: store,
                    fontSize: 16
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TerminalPalette.background)
            } else {
                TerminalPalette.background
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            #else
            TerminalPalette.background
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .mobileTerminalSafeAreaExpansion(
            context: safeAreaContext,
            includesBottom: true
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
        dismissKeyboard()
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

#endif
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
