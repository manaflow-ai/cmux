import CmuxCloud
import AppKit
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Separates accepting a local reservation from receiving the eventual machine receipt.
@MainActor
final class DelayedNewMachineSheetPresenter: NewMachineSheetPresenting {
    let workspaceID: UUID
    let accepted: AsyncStream<Void>
    private let acceptance: AsyncStream<Void>.Continuation
    private var completion: CheckedContinuation<UUID?, Never>?

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
        (accepted, acceptance) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func presentNewMachineFetchingPlan(preferredWindow: NSWindow?, onReservation: @escaping @MainActor (UUID) -> Void) async -> UUID? {
        onReservation(workspaceID)
        return await withCheckedContinuation { continuation in
            completion = continuation
            acceptance.yield(())
            acceptance.finish()
        }
    }

    func finish() {
        completion?.resume(returning: workspaceID)
        completion = nil
    }
}
