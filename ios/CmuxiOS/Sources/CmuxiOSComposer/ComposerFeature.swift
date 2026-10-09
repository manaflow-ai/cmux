public import CmuxiOSComposerCore
public import CmuxiOSFeatureKit
import CmuxiOSFiles
public import UIKit

/// Lane C8's entry point: the Compose tab, the composer sheet the floating
/// button presents, and the button itself. The composition root makes one per
/// shell and injects C5's picker and workspace opener as closures, so this
/// module never imports the Workspaces feature.
@MainActor
public final class ComposerFeature {
    /// Presents C5's picker (`WorkspacesFeature.makePicker`).
    public typealias PickerFactory = @MainActor (WorkspacePickerRequest, @escaping @MainActor (WorkspaceSelection?) -> Void)
        -> UIViewController
    /// Shows a workspace (`WorkspacesFeature.open(hostID:workspaceID:)`) and its tab.
    public typealias WorkspaceOpener = @MainActor (HostID, WorkspaceSummary.ID) -> Void

    let sink: any TaskComposerSink
    let makePicker: PickerFactory
    let openWorkspace: WorkspaceOpener
    let uploader: (any ComposerAttachmentUploading)?
    let attachmentPicker: ComposerAttachmentPicker?
    let files: any ComposerFileSuggesting
    let isMock: Bool
    let store: ComposerDraftStore
    let preferences: ComposerPreferences
    let templates: PromptTemplateLibrary

    public init(sink: any TaskComposerSink, makePicker: @escaping PickerFactory, openWorkspace: @escaping WorkspaceOpener,
                uploader: (any ComposerAttachmentUploading)? = nil, c4Files: FilesFeature? = nil,
                files: any ComposerFileSuggesting = NoFileSuggestions(),
                isMock: Bool = false, defaults: UserDefaults = .standard) {
        self.sink = sink
        self.makePicker = makePicker
        self.openWorkspace = openWorkspace
        self.uploader = uploader ?? c4Files.map { C4ComposerAttachmentUploader(sender: $0.sender) }
        attachmentPicker = c4Files.map { ComposerAttachmentPicker(coordinator: $0.picker) }
            ?? (uploader == nil ? nil : ComposerAttachmentPicker())
        self.files = files
        self.isMock = isMock
        store = ComposerDraftStore(defaults: defaults)
        preferences = ComposerPreferences(defaults: defaults)
        templates = PromptTemplateLibrary(builtIns: ComposerText.builtInTemplates, defaults: defaults)
    }

    /// The Compose tab root (a navigation controller with large titles).
    public func makeComposeScreen() -> UIViewController {
        let screen = ComposerViewController(feature: self, target: nil, presentation: .tab)
        let navigation = UINavigationController(rootViewController: screen)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }

    /// The composer as a sheet (floating button, deep links), optionally on a target.
    public func makeComposeSheet(target: ComposerTarget? = nil) -> UIViewController {
        let screen = ComposerViewController(feature: self, target: target, presentation: .sheet)
        let navigation = UINavigationController(rootViewController: screen)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }

    /// Adds the floating compose button to `navigation`'s root screen; it
    /// hides while a pushed screen is on top (terminals, details).
    public func installFloatingButton(on navigation: UINavigationController) {
        FloatingComposeButton.install(on: navigation) { [weak self, weak navigation] in
            guard let self, let navigation else { return }
            navigation.present(self.makeComposeSheet(), animated: true)
        }
    }

    func makeSession(target: ComposerTarget?) -> ComposerSession {
        ComposerSession(sink: sink, store: store, preferences: preferences, target: target)
    }
}
