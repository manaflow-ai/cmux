import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import Foundation
import Observation

/// The Cloud tab's state: the newest snapshot as a list model, plus the
/// sheet, confirmation and alert the user opened. Intents carry one fresh
/// key per tap; the owner's answer (or the next event) moves the rows.
@MainActor
@Observable
final class CloudModel {
    private(set) var list: CloudMachineListModel
    private(set) var options = CloudCreateOptions(plan: nil)
    private(set) var connection: SourceConnection = .connecting
    var notice: CloudNotice?
    var confirmingDelete: CloudMachineRow?
    var isCreating = false
    let isMock: Bool

    @ObservationIgnored private let source: any CloudMachineSource

    init(source: any CloudMachineSource, isMock: Bool) {
        self.source = source
        self.isMock = isMock
        list = CloudMachineListModel(snapshot: SourceSnapshot(revision: 0, value: CloudState(), connection: .connecting))
    }

    /// Follows the owner while the screen is visible (the view's `.task`).
    func run() async {
        for await snapshot in await source.updates() {
            list = CloudMachineListModel(snapshot: snapshot)
            options = CloudCreateOptions(plan: snapshot.value.plan)
            connection = snapshot.connection
        }
    }

    func run(_ action: CloudMachineAction, on row: CloudMachineRow) {
        switch action {
        case .resume: send(.start(machine: row.id))
        case .pause: send(.pause(machine: row.id))
        case .delete: confirmingDelete = row
        }
    }

    func confirmDelete(_ row: CloudMachineRow) {
        confirmingDelete = nil
        send(.delete(machine: row.id))
    }

    func create(name: String, size: CloudSizeOption) {
        isCreating = false
        send(.create(name: CloudCreateOptions.normalizedName(name), size: size.size))
    }

    private func send(_ intent: CloudIntent) {
        let key = IntentKey()
        Task {
            do {
                if case .refused(_, let reason) = try await source.perform(intent, key: key) {
                    notice = CloudNotice(message: CloudText.refusal(reason))
                }
            } catch {
                notice = CloudNotice(message: CloudText.offlineError)
            }
        }
    }
}
