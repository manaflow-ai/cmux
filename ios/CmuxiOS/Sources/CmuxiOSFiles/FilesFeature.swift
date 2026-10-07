import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import Observation
import UIKit

/// Lane C4's entry points (c4-files.md section 6): pick and send a file to
/// a terminal, to the task composer or to the Mac inbox, and the transfer
/// list. Also keeps transfers alive briefly in the background and resumes
/// the ones the system paused.
@MainActor
public final class FilesFeature {
    public let model: TransferListModel
    public let sender: FileSendCoordinator
    public let picker: FilePickerCoordinator
    public var viewer: (any FileViewerHook)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lifecycle: [Task<Void, Never>] = []

    public init(transfer: any FileTransfer, paster: (any TerminalPathPaster)? = nil, attachments: (any FileAttachmentSink)? = nil,
                viewer: (any FileViewerHook)? = QuickLookFileViewer(), preferences: FileTransferPreferences = FileTransferPreferences()) {
        let stager = FileStager()
        model = TransferListModel(transfer: transfer)
        sender = FileSendCoordinator(model: model, paster: paster, attachments: attachments, stager: stager)
        picker = FilePickerCoordinator(stager: stager, preferences: preferences)
        self.viewer = viewer
        observeLifecycle()
        watchIdle()
    }

    /// "Send to terminal", "Attach to task", "Save to Mac": pick, then upload.
    public func pickAndSend(to target: FileSendTarget, host: HostID, from presenter: UIViewController,
                            anchor: UIBarButtonItem? = nil) {
        picker.presentSourceMenu(from: presenter, anchor: anchor) { [weak self] files in
            self?.sender.send(files, to: target, host: host)
        }
    }

    /// The transfer list; with `host`, its + button saves picked files to that Mac's inbox.
    public func makeTransferList(host: HostID?) -> UIViewController {
        var list: TransferListViewController?
        let onAdd: ((UIBarButtonItem) -> Void)? = host.map { host in
            { [weak self] anchor in
                guard let self, let list else { return }
                self.pickAndSend(to: .inbox, host: host, from: list, anchor: anchor)
            }
        }
        let controller = TransferListViewController(model: model, viewer: viewer, onAdd: onAdd)
        list = controller
        return controller
    }

    // MARK: Background (c4-files.md section 5)

    private func observeLifecycle() {
        let center = NotificationCenter.default
        // Each loop ends at the first notification after the feature is gone.
        lifecycle.append(Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.didEnterBackgroundNotification) {
                guard let self else { return }
                self.didEnterBackground()
            }
        })
        lifecycle.append(Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.willEnterForegroundNotification) {
                guard let self else { return }
                self.willEnterForeground()
            }
        })
    }

    /// Ends the background task as soon as nothing runs any more.
    private func watchIdle() {
        let running = withObservationTracking {
            model.hasRunning
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchIdle() }
        }
        if !running, backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func didEnterBackground() {
        guard model.hasRunning, backgroundTask == .invalid else { return }
        let model = model
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "cmux.files") { [weak self] in
            // Expiry: pause best effort and end the task before returning, as UIKit requires.
            Task { await model.pauseAll() }
            UIApplication.shared.endBackgroundTask(identifier)
            MainActor.assumeIsolated {
                if self?.backgroundTask == identifier { self?.backgroundTask = .invalid }
            }
        }
        backgroundTask = identifier
    }

    private func willEnterForeground() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        // Paused covers both an expiry and a link lost in the background.
        model.resumeInterrupted()
    }
}
