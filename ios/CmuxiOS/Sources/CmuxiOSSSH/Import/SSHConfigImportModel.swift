import CmuxiOSFeatureKit
import CmuxiOSSSHCore
import Foundation
import Observation

/// Paste, preview and commit hosts from an SSH config snippet. Items are
/// committed in plan order (jump hosts first); duplicates start unchecked.
@MainActor
@Observable
final class SSHConfigImportModel {
    var text = "" {
        didSet { if text != oldValue { reparse() } }
    }
    private(set) var plan = SSHConfigImport(entries: [], existing: [])
    var selected = Set<String>()
    private(set) var isWorking = false
    var message: String?
    var dismiss: (() -> Void)?

    private let hosts: any HostsStore
    private let existing: [HostRecord]

    init(hosts: any HostsStore, existing: [HostRecord]) {
        self.hosts = hosts
        self.existing = existing
    }

    var selectedCount: Int { plan.items.filter { selected.contains($0.id) }.count }

    func toggle(_ item: SSHConfigImport.Item) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func commit() async {
        isWorking = true
        defer { isWorking = false }
        var added = 0
        var refusal: String?
        for item in plan.items where selected.contains(item.id) {
            do {
                switch try await hosts.add(item.draft, key: item.key) {
                case .committed: added += 1
                case .refused(_, let reason): refusal = refusal ?? SSHText.refusal(reason)
                }
            } catch {
                refusal = SSHText.offline
                break
            }
        }
        if let refusal {
            message = String(format: SSHText.importResult, Int64(added)) + "\n" + refusal
        } else {
            dismiss?()
        }
    }

    private func reparse() {
        plan = SSHConfigImport(entries: SSHConfigParser().parse(text), existing: existing)
        selected = Set(plan.items.filter { $0.duplicateOf == nil }.map(\.id))
        message = nil
    }
}
