import CnxDesign
import LocalAuthentication
import SwiftUI

/// Settings → Require Face ID (audit B11): with the setting on, cmux opens
/// locked and locks again whenever it leaves the foreground; Face ID (or the
/// device passcode) unlocks it. The app switcher snapshot shows the lock, not
/// the content.
struct AppLock: ViewModifier {
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked: Bool
    @State private var evaluating = false

    init(enabled: Bool) {
        self.enabled = enabled
        _locked = State(initialValue: enabled)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if locked || (enabled && scenePhase != .active) {
                    LockScreen(evaluating: evaluating) { unlock() }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: locked)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: if enabled { locked = true }
                case .active: if locked { unlock() }
                default: break
                }
            }
            // Turning the setting off unlocks; turning it on locks from the next background.
            .onChange(of: enabled) { _, on in if !on { locked = false } }
            .task { if locked { unlock() } }
    }

    private func unlock() {
        guard locked, !evaluating else { return }
        let context = LAContext()
        var error: NSError?
        // No passcode on this device: nothing can check the owner, so the lock cannot hold.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false
            return
        }
        evaluating = true
        Task { @MainActor in
            let passed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock cmux")) ?? false
            evaluating = false
            if passed { locked = false }
        }
    }
}

private struct LockScreen: View {
    let evaluating: Bool
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("cmux is locked")
                    .font(.title3.weight(.semibold))
                Button(action: unlock) {
                    Label("Unlock with Face ID", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                .disabled(evaluating)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cnx.appLock")
    }
}

extension View {
    /// Locks the app behind Face ID while `enabled` (``AppLock``).
    func cnxAppLock(enabled: Bool) -> some View { modifier(AppLock(enabled: enabled)) }
}
