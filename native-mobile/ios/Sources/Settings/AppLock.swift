import LocalAuthentication
import SwiftUI

/// "Require Face ID" (Codex Settings › Safety and security): the app opens
/// behind a lock and hides its content in the app switcher.
enum AppLock {
    static let settingKey = "security.requireUnlock"

    static var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    static var biometryName: String {
        switch biometryType {
        case .faceID: String(localized: "Face ID")
        case .touchID: String(localized: "Touch ID")
        case .opticID: String(localized: "Optic ID")
        default: String(localized: "Passcode")
        }
    }

    static var biometrySymbol: String {
        switch biometryType {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        default: "lock"
        }
    }

    /// Biometrics with passcode fallback.
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.passcodeNotSet)
        }
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

/// Covers the app with a blur whenever it is not active (app switcher) and
/// keeps it locked after a trip to the background until the owner unlocks.
struct AppLockModifier: ViewModifier {
    @AppStorage(AppLock.settingKey) private var requireUnlock = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = UserDefaults.standard.bool(forKey: AppLock.settingKey)
    @State private var authenticating = false
    @State private var failed = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if requireUnlock, locked || scenePhase != .active {
                    LockCover(locked: locked, failed: failed, unlock: unlock)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: locked)
            .animation(.smooth(duration: 0.2), value: scenePhase)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background where requireUnlock:
                    locked = true
                case .active where locked && requireUnlock:
                    unlock()
                default:
                    break
                }
            }
            .onChange(of: requireUnlock) { _, on in if !on { locked = false } }
            .task {
                if locked && requireUnlock && scenePhase == .active { unlock() }
                if !requireUnlock { locked = false }
            }
    }

    private func unlock() {
        guard !authenticating else { return }
        authenticating = true
        failed = false
        Task {
            defer { authenticating = false }
            do {
                try await AppLock.authenticate(reason: String(localized: "Unlock cmux"))
                locked = false
            } catch {
                failed = true
            }
        }
    }
}

private struct LockCover: View {
    let locked: Bool
    let failed: Bool
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Theme.background.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                CmuxMark().frame(width: 64, height: 64)
                if locked {
                    Text(String(localized: "cmux is locked"))
                        .font(.headline)
                        .padding(.top, 6)
                    Button {
                        unlock()
                    } label: {
                        Label(String(localized: "Unlock with \(AppLock.biometryName)"), systemImage: AppLock.biometrySymbol)
                    }
                    .buttonStyle(.primaryCapsule)
                    .padding(.top, 6)
                    .accessibilityIdentifier("lock.unlock")
                    if failed {
                        Text(String(localized: "Couldn't verify it's you. Try again."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

extension View {
    func appLock() -> some View { modifier(AppLockModifier()) }
}
