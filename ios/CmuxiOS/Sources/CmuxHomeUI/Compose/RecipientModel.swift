import CmuxHomeCore
import Foundation

/// The To: field's view model: a `RecipientSet` plus one lookup task per
/// new address (`HomeStore.resolve`). A lookup that outlives the model
/// finds it gone (weak) and does nothing.
@MainActor
final class RecipientModel {
    private(set) var set = RecipientSet()
    var onChange: (@MainActor () -> Void)?

    private let store: HomeStore
    private let callingCode: String
    private var lookups: [Int: Task<Void, Never>] = [:]

    init(store: HomeStore, region: String? = Locale.current.region?.identifier) {
        self.store = store
        callingCode = RecipientSet.defaultCallingCode(region: region)
    }

    /// Commits typed text as tokens and starts their lookups.
    func add(text: String) {
        let added = set.add(text: text, defaultCallingCode: callingCode)
        for recipient in added { lookUp(recipient) }
        onChange?()
    }

    func add(_ address: ContactAddress) {
        add(text: address.description)
    }

    func remove(id: Int) {
        lookups[id]?.cancel()
        lookups[id] = nil
        set.remove(id: id)
        onChange?()
    }

    func removeLast() {
        guard let last = set.recipients.last else { return }
        remove(id: last.id)
    }

    /// Waits for every lookup in flight (gallery capture and tests).
    func settled() async {
        for task in lookups.values { await task.value }
    }

    private func lookUp(_ recipient: Recipient) {
        guard let address = recipient.address else { return }
        let store = self.store
        let id = recipient.id
        lookups[id] = Task { [weak self] in
            let resolution = try? await store.resolve(address)
            guard !Task.isCancelled, let self else { return }
            self.set.resolve(id: id, as: resolution)
            self.lookups[id] = nil
            self.onChange?()
        }
    }
}
