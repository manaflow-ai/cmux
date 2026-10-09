public import CmuxiOSFeatureKit
import Foundation
public import Observation

/// State behind the "Add direct address" form: the draft, its issues once
/// the user tried to save, and the save intent through `HostsStore`. C9's
/// Hosts tab decides where the entry point sits and presents the form.
@MainActor
@Observable
public final class DirectAddressFormModel {
    public var draft: DirectAddressDraft
    public private(set) var isSaving = false
    /// Issues are shown only after the first save attempt.
    public private(set) var showsIssues = false
    public private(set) var refusal: String?
    @ObservationIgnored private let store: any HostsStore
    @ObservationIgnored private let editing: HostID?
    /// One key per form, so a retried save is the same intent.
    @ObservationIgnored private let intentKey = IntentKey()

    public init(store: any HostsStore, draft: DirectAddressDraft = DirectAddressDraft(), editing: HostID? = nil) {
        self.store = store
        self.draft = draft
        self.editing = editing
    }

    public var visibleIssues: [DirectAddressIssue] { showsIssues ? draft.issues : [] }

    public var canSave: Bool { !isSaving }

    /// Saves the draft. Returns true when the owner committed it.
    public func save() async -> Bool {
        showsIssues = true
        refusal = nil
        guard let host = draft.hostDraft(), !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let receipt = if let editing {
                try await store.update(editing, with: host, key: intentKey)
            } else {
                try await store.add(host, key: intentKey)
            }
            switch receipt {
            case .committed:
                return true
            case let .refused(_, reason):
                refusal = reason
                return false
            }
        } catch {
            refusal = error.localizedDescription
            return false
        }
    }
}
