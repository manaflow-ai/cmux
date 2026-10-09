import CmuxiOSComposerCore
import CmuxiOSDesign
import CmuxiOSFeatureKit
import UIKit

/// The composer screen (Compose tab or sheet). Renders a `ComposerSession`
/// and forwards user actions to it; the session owns every rule.
@MainActor
final class ComposerViewController: UIViewController, UITextViewDelegate {
    let feature: ComposerFeature
    let session: ComposerSession
    let presentation: ComposerPresentation
    let scrollView = UIScrollView()
    let outcomeView = ComposerOutcomeView()
    let targetButton = UIButton(configuration: .plain())
    let pills = ComposerPillsView()
    let promptView = ComposerPromptTextView()
    let suggestions = ComposerSuggestionBar()
    let attachmentStrip = ComposerAttachmentStrip()
    let attachButton = UIButton(configuration: .plain())
    let dictateButton = UIButton(configuration: .plain())
    let sendButton = UIButton(configuration: .filled())
    let footnote = UILabel()
    let mockLabel = UILabel()
    let dictation = DictationController()
    let picker: ComposerAttachmentPicker?
    /// The prompt before dictation started; transcriptions append to it.
    var dictationPrefix = ""
    var activeTrigger: PromptTrigger?
    var mentionLookup: Task<Void, Never>?
    var uploads: [TransferID: Task<Void, Never>] = [:]

    init(feature: ComposerFeature, target: ComposerTarget?, presentation: ComposerPresentation) {
        self.feature = feature
        self.presentation = presentation
        picker = feature.attachmentPicker
        session = feature.makeSession(target: target)
        super.init(nibName: nil, bundle: nil)
        title = presentation == .tab ? ComposerText.title : ComposerText.newTask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "composer.screen"
        buildLayout()
        wireActions()
        session.onChange = { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentation == .sheet { promptView.becomeFirstResponder() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        dictation.stop()
        cancelUploads()
        session.stop()
    }

    /// Cancels C4 work and removes its placeholders before the draft is saved.
    /// This keeps a dismissed composer from restoring uploads that no longer
    /// have a live task or staged file behind them.
    func cancelUploads() {
        let ids = Array(uploads.keys)
        uploads.values.forEach { $0.cancel() }
        uploads.removeAll()
        for id in ids { session.removeAttachment(id) }
    }

    // MARK: Render

    func render() {
        let draft = session.draft
        targetButton.configuration?.title = targetTitle
        targetButton.configuration?.subtitle = session.targetHost?.offlineReason
        targetButton.accessibilityValue = targetTitle
        pills.show(makePills())
        // The text view leads while typing (it updates the session first), so
        // this only lands on a target switch, a cleared draft after a start, or a restore.
        if let draft, draft.prompt != promptView.text, !dictation.isRunning { promptView.setPrompt(draft.prompt) }
        attachmentStrip.show(draft?.attachments ?? [])
        attachButton.isHidden = feature.uploader == nil || picker == nil
        attachButton.menu = attachMenu()
        let blocker = session.blocker
        let canSend = blocker == nil
        sendButton.isEnabled = canSend
        sendButton.configuration?.showsActivityIndicator = session.isSending
        sendButton.configuration?.title = session.isSending ? ComposerText.sending : ComposerText.send
        // Empty prompt is the resting state, not an error worth a footnote.
        footnote.text = blocker.flatMap { $0 == .emptyPrompt ? nil : ComposerText.blocker($0) }
        footnote.isHidden = footnote.text == nil
        outcomeView.show(session.outcome, workspaceTitle: outcomeWorkspaceTitle, task: session.task)
        navigationItem.leftBarButtonItem?.menu = draftsMenu()
        dictateButton.configuration?.image = UIImage(systemName: dictation.isRunning ? "stop.circle.fill" : "mic")
        dictateButton.accessibilityLabel = dictation.isRunning ? ComposerText.stopDictation : ComposerText.dictate
    }

    private var targetTitle: String {
        guard let host = session.targetHost else { return ComposerText.chooseTarget }
        let workspace = session.draft?.target.workspaceID == nil ? ComposerText.newWorkspace
            : session.targetWorkspace?.title ?? session.draft?.target.workspaceID ?? ""
        return host.hostName + " · " + workspace
    }

    private var outcomeWorkspaceTitle: String? {
        guard case .started(let target, let workspaceID, _, _)? = session.outcome else { return nil }
        return session.catalog?.value.host(target.hostID)?.workspaces.first { $0.id == workspaceID }?.title
    }

    // MARK: Actions

    func send() {
        guard session.blocker == nil else { return }
        dictation.stop()
        session.updatePrompt(promptView.text)
        Task { await session.send() }
    }

    func chooseTarget() {
        let request = WorkspacePickerRequest(hostID: nil, allowsNewWorkspace: true)
        let picker = feature.makePicker(request) { [weak self] selection in
            guard let self, let selection else { return }
            self.cancelUploads()
            self.session.setTarget(ComposerTarget(selection))
        }
        present(picker, animated: true)
    }

    func openOutcome() {
        guard case .started(let target, let workspaceID, _, _)? = session.outcome else { return }
        let open = feature.openWorkspace
        if presentation == .sheet {
            dismiss(animated: true) { open(target.hostID, workspaceID) }
        } else {
            open(target.hostID, workspaceID)
        }
    }

    func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        let current = promptView.text ?? ""
        dictationPrefix = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") ? current : current + " "
        dictation.onText = { [weak self] text in
            guard let self else { return }
            let next = self.dictationPrefix + text
            self.promptView.setPrompt(next)
            self.session.updatePrompt(next)
        }
        dictation.onEnd = { [weak self] in
            self?.session.saveDraft()
            self?.render()
        }
        Task {
            do {
                try await dictation.start()
                render()
            } catch DictationController.Failure.denied {
                showMessage(ComposerText.dictationDenied)
            } catch {
                showMessage(ComposerText.dictationUnavailable)
            }
        }
    }

    func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ComposerText.close, style: .cancel))
        present(alert, animated: true)
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        promptView.restyle()
        session.updatePrompt(textView.text)
        updateSuggestions()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        updateSuggestions()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        session.saveDraft()
        suggestions.show([])
    }
}
