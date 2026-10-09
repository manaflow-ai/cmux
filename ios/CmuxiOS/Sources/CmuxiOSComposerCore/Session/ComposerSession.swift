public import CmuxiOSFeatureKit
import Foundation

/// One composer screen's state: the catalog mirror, the draft for the chosen
/// target (saved per target), the selection rules, sending with a kept
/// idempotency key, the receipt and the started task's live state. UIKit
/// screens render it and forward user actions; `onChange` fires after every
/// change, once per batch.
@MainActor
public final class ComposerSession {
    public private(set) var catalog: SourceSnapshot<ComposerCatalog>?
    public private(set) var draft: ComposerDraft?
    public private(set) var isSending = false
    public private(set) var outcome: ComposerOutcome?
    /// The started task as its Mac reports it (nil until the first state).
    public private(set) var task: TaskRecord?
    public var onChange: (() -> Void)?

    private let sink: any TaskComposerSink
    private let store: ComposerDraftStore
    private let preferences: ComposerPreferences
    private var requestedTarget: ComposerTarget?
    private var catalogPump: Task<Void, Never>?
    private var taskPump: Task<Void, Never>?
    /// Invalidates an intake when its target changes or its draft was sent.
    private var attachmentGeneration = UUID()

    public init(sink: any TaskComposerSink, store: ComposerDraftStore, preferences: ComposerPreferences,
                target: ComposerTarget? = nil) {
        self.sink = sink
        self.store = store
        self.preferences = preferences
        requestedTarget = target
    }

    // MARK: Lifecycle

    /// Subscribes the catalog (opens the Macs' task channels).
    public func start() {
        guard catalogPump == nil else { return }
        let sink = self.sink
        catalogPump = Task { [weak self] in
            for await snapshot in await sink.catalog() {
                guard !Task.isCancelled else { return }
                self?.catalogChanged(snapshot)
            }
        }
    }

    /// Saves the draft and drops the subscriptions (a hidden composer costs nothing).
    public func stop() {
        saveDraft()
        catalogPump?.cancel()
        catalogPump = nil
        taskPump?.cancel()
        taskPump = nil
    }

    // MARK: Derived

    public var agents: [ComposerAgent] {
        guard let draft, let catalog else { return [] }
        return catalog.value.agents(on: draft.target.hostID)
    }

    public var selectedAgent: ComposerAgent? { draft?.selection.agent(in: agents) }

    public var selectedModel: ComposerModel? { draft?.selection.currentModel(in: agents) }

    public var targetHost: HostWorkspaces? {
        guard let draft else { return nil }
        return catalog?.value.host(draft.target.hostID)
    }

    public var targetWorkspace: WorkspaceSummary? {
        guard let id = draft?.target.workspaceID else { return nil }
        return targetHost?.workspaces.first { $0.id == id }
    }

    public var blocker: ComposerSendBlocker? {
        guard let draft, let catalog else { return .noTarget }
        return ComposerSendGate(draft: draft, catalog: catalog.value, connection: catalog.connection,
                                isSending: isSending).blocker
    }

    public var savedDrafts: [ComposerDraft] { store.all }

    /// Captures the target and generation an in-flight C4 upload belongs to.
    /// The view may keep receiving upload events after a target switch, so
    /// completions must present this context when they update the draft.
    public func attachmentContext() -> (target: ComposerTarget, generation: UUID)? {
        guard let draft else { return nil }
        return (draft.target, attachmentGeneration)
    }

    // MARK: Edits

    public func setTarget(_ target: ComposerTarget) {
        guard target != draft?.target else { return }
        saveDraft()
        attachmentGeneration = UUID()
        draft = makeDraft(for: target)
        preferences.remember(target: target)
        changed()
    }

    public func selectAgent(_ id: String) {
        guard var draft, let agent = agents.first(where: { $0.id == id }) else { return }
        draft.selection.selectAgent(agent)
        commitSelection(draft)
    }

    public func selectModel(_ id: String) {
        guard var draft, let model = selectedAgent?.model(id) else { return }
        draft.selection.selectModel(model)
        commitSelection(draft)
    }

    public func selectEffort(_ effort: String?) {
        guard var draft else { return }
        draft.selection.selectEffort(effort, in: agents)
        commitSelection(draft)
    }

    /// The prompt as the text view holds it. Saved on `saveDraft()` (end of
    /// editing, disappear, target switch), not on every keystroke.
    public func updatePrompt(_ text: String) {
        guard var draft, draft.prompt != text else { return }
        draft.prompt = text
        draft.updatedAt = Date()
        self.draft = draft
        if case .refused = outcome { outcome = nil }
        changed()
    }

    public func setTemplate(_ name: String?) {
        guard var draft, draft.templateID != name else { return }
        draft.templateID = name
        self.draft = draft
        changed()
    }

    public func upsertAttachment(_ attachment: ComposerAttachment) {
        guard var draft else { return }
        if let index = draft.attachments.firstIndex(where: { $0.id == attachment.id }) {
            draft.attachments[index] = attachment
        } else {
            draft.attachments.append(attachment)
        }
        self.draft = draft
        saveDraft()
        changed()
    }

    /// Applies an upload event only to the draft that admitted it. A late
    /// event from an old host is ignored after a target switch or send.
    public func updateAttachment(_ attachment: ComposerAttachment, target: ComposerTarget,
                                 generation: UUID) {
        guard generation == attachmentGeneration, draft?.target == target else { return }
        upsertAttachment(attachment)
    }

    /// An intake for this target and draft lifetime. A late upload after a
    /// target switch or a successful send remains in the Mac inbox.
    public func attachmentSink() -> (any FileAttachmentSink)? {
        guard let draft else { return nil }
        return ComposerFileAttachmentSink(session: self, target: draft.target, generation: attachmentGeneration)
    }

    func accept(_ file: FileAttachment, target: ComposerTarget, generation: UUID) {
        guard generation == attachmentGeneration, let draft, draft.target == target,
              file.hostID == target.hostID, !isSending, draft.pendingKey == nil,
              file.byteCount >= 0, let upload = file.uploadID, upload.hasPrefix("up_") else { return }
        let suffix = upload.dropFirst(3)
        guard (2...64).contains(suffix.count), suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              draft.attachments.contains(where: { $0.id == file.id }) || draft.attachments.count < 32 else { return }
        upsertAttachment(ComposerAttachment(id: file.id, name: file.name, mime: file.mime, byteCount: file.byteCount,
                                            uploadID: upload, phase: .ready))
    }

    public func removeAttachment(_ id: TransferID) {
        guard var draft else { return }
        draft.attachments.removeAll { $0.id == id }
        self.draft = draft
        saveDraft()
        changed()
    }

    public func saveDraft() {
        if let draft { store.save(draft) }
    }

    // MARK: Send

    /// Sends the draft once. A send whose outcome is unknown keeps its key in
    /// the draft, so the retry is the same op to the Mac.
    public func send() async {
        guard blocker == nil, var draft, let wire = draft.taskDraft() else { return }
        let key = draft.pendingKey.map { IntentKey(rawValue: $0) } ?? IntentKey()
        draft.pendingKey = key.rawValue
        self.draft = draft
        store.save(draft)
        isSending = true
        outcome = nil
        changed()
        let result: ComposerOutcome
        do {
            switch try await sink.dispatch(wire, key: key) {
            case .started(_, let workspaceID, let taskID, let tabID):
                result = .started(target: draft.target, workspaceID: workspaceID, taskID: taskID, tabID: tabID)
            case .refused(_, let reason):
                result = .refused(reason: reason)
            }
        } catch FeatureSourceError.unsupported {
            result = .unsupported
        } catch {
            result = .notDelivered
        }
        isSending = false
        finish(result, sent: draft)
    }

    private func finish(_ result: ComposerOutcome, sent: ComposerDraft) {
        outcome = result
        guard var draft, draft.target == sent.target else {
            changed()
            return
        }
        switch result {
        case .started(let target, _, let taskID, _):
            attachmentGeneration = UUID()
            store.clear(target)
            draft.prompt = ""
            draft.attachments = []
            draft.templateID = nil
            draft.pendingKey = nil
            self.draft = draft
            follow(taskID: taskID, on: target.hostID)
        case .refused, .unsupported:
            draft.pendingKey = nil
            self.draft = draft
            store.save(draft)
        case .notDelivered:
            break
        }
        changed()
    }

    private func follow(taskID: String?, on host: HostID) {
        taskPump?.cancel()
        task = nil
        guard let taskID else { return }
        let sink = self.sink
        taskPump = Task { [weak self] in
            for await snapshot in await sink.tasks(on: host) {
                guard !Task.isCancelled else { return }
                if let record = snapshot.value.first(where: { $0.id == taskID }) { self?.taskChanged(record) }
            }
        }
    }

    private func taskChanged(_ record: TaskRecord) {
        guard record != task else { return }
        task = record
        changed()
    }

    // MARK: Catalog

    private func catalogChanged(_ snapshot: SourceSnapshot<ComposerCatalog>) {
        catalog = snapshot
        if draft == nil, let target = initialTarget(in: snapshot.value) {
            draft = makeDraft(for: target)
        } else if var draft {
            let reconciled = draft.selection.reconciled(with: agents, preferred: preferences.selection(for: draft.target.hostID))
            if reconciled != draft.selection {
                draft.selection = reconciled
                self.draft = draft
            }
        }
        changed()
    }

    private func initialTarget(in catalog: ComposerCatalog) -> ComposerTarget? {
        let known = Set(catalog.hosts.map(\.hostID))
        for candidate in [requestedTarget, preferences.lastTarget, store.latest?.target] {
            if let candidate, known.contains(candidate.hostID) { return candidate }
        }
        let host = catalog.hosts.first(where: \.isReachable) ?? catalog.hosts.first
        return host.map { ComposerTarget(hostID: $0.hostID) }
    }

    private func makeDraft(for target: ComposerTarget) -> ComposerDraft {
        var draft = store.draft(for: target) ?? ComposerDraft(target: target)
        let agents = catalog?.value.agents(on: target.hostID) ?? []
        let preferred = preferences.selection(for: target.hostID)
        if draft.agentID == nil, let preferred { draft.selection = preferred }
        draft.selection = draft.selection.reconciled(with: agents, preferred: preferred)
        return draft
    }

    private func commitSelection(_ next: ComposerDraft) {
        guard next != draft else { return }
        draft = next
        preferences.remember(next.selection, for: next.target.hostID)
        changed()
    }

    private func changed() { onChange?() }
}
