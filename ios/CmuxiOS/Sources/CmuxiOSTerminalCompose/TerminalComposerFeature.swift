public import CmuxiOSFeatureKit
public import CmuxiOSFiles
import CmuxiOSFilesCore
public import CmuxiOSTerminal
public import CmuxiOSTerminalComposeCore
import UIKit

/// Lane E4's entry point (e4-compose.md): one per signed-in shell. Hands
/// each terminal screen its composer bar over the device's draft store and
/// C4's uploads and pickers.
@MainActor
public final class TerminalComposerFeature {
    public let store: TerminalComposeStore
    private let files: FilesFeature?
    private let uploader: FilesComposerUploader?

    /// `files` nil: attaching is unavailable (the attach button hides).
    public init(store: TerminalComposeStore, files: FilesFeature?) {
        self.store = store
        self.files = files
        uploader = files.map { FilesComposerUploader(sender: $0.sender) }
    }

    /// The composer of one host terminal (`term_…` on `host`).
    public func provider(host: HostID, terminal: String) -> any TerminalComposerProviding {
        TerminalComposerProvider(feature: self, key: TerminalDraftKey(host: host, terminal: terminal))
    }

    func makeModel(key: TerminalDraftKey) -> TerminalComposerModel {
        TerminalComposerModel(key: key, store: store, uploader: uploader)
    }

    var picker: FilePickerCoordinator? { files?.picker }
}

/// Builds the bar for one terminal screen.
@MainActor
final class TerminalComposerProvider: TerminalComposerProviding {
    private let feature: TerminalComposerFeature
    private let key: TerminalDraftKey

    init(feature: TerminalComposerFeature, key: TerminalDraftKey) {
        self.feature = feature
        self.key = key
    }

    func makeComposer(for screen: TerminalViewController) -> UIViewController {
        TerminalComposerViewController(model: feature.makeModel(key: key), picker: feature.picker, screen: screen)
    }
}
