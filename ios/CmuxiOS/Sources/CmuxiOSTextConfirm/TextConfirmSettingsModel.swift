public import CmuxTextConfirmCore
public import Foundation
public import Observation

/// Settings state for the text confirmation level. The owner (UserDO) holds
/// the level; this shows its last known value and runs the change flow.
@MainActor
@Observable
public final class TextConfirmSettingsModel {
    public private(set) var state: TextConfirmState
    public private(set) var busy = false
    public private(set) var message: String?
    /// The level waiting for the raise dialog's confirmation.
    public var pendingLowering: TextConfirmLevel?
    /// False until the presence key is past its 24 h cooldown.
    public var presenceKeyReady: Bool

    private let flow: TextConfirmFlow
    private let ops: any TextConfirmOps

    public init(state: TextConfirmState, flow: TextConfirmFlow, ops: any TextConfirmOps, presenceKeyReady: Bool) {
        self.state = state
        self.flow = flow
        self.ops = ops
        self.presenceKeyReady = presenceKeyReady
    }

    /// The user picked a level: safer applies, riskier asks first.
    public func pick(_ level: TextConfirmLevel) {
        guard level != state.level, state.selectable.contains(level), !busy else { return }
        if state.level.isLowered(to: level) {
            pendingLowering = level
        } else {
            run(level)
        }
    }

    /// The raise dialog's "Lower protection".
    public func confirmLowering() {
        guard let level = pendingLowering, !busy, state.selectable.contains(level), state.level.isLowered(to: level) else {
            pendingLowering = nil
            return
        }
        pendingLowering = nil
        run(level)
    }

    /// Re-reads the owner's level and lock.
    public func refresh() async {
        if let fresh = try? await ops.state() { state = fresh }
    }

    private static var notAccepted: String {
        String(localized: "textConfirm.lowered.refused", defaultValue: "The change was not accepted. Try again.", bundle: .module)
    }

    private func run(_ level: TextConfirmLevel) {
        busy = true
        message = nil
        let from = state.level
        Task {
            defer { busy = false }
            do {
                switch try await flow.change(from: from, to: level) {
                case .lowered: state.level = level
                case .refused: message = Self.notAccepted
                }
            } catch let refusal as TextConfirmRefusal where refusal.code == "text_confirm.key_cooling_down" {
                presenceKeyReady = false
            } catch let refusal as TextConfirmRefusal where refusal.code == "text_confirm.proof_required" {
                // Our level was stale (another device changed it): re-read, then ask.
                await refresh()
                if state.level.isLowered(to: level) { pendingLowering = level }
                return
            } catch {
                // Cancelled Face ID, offline, or a refused proof.
                message = Self.notAccepted
            }
            // Never keep a guess: the owner's level is the truth.
            await refresh()
        }
    }
}
