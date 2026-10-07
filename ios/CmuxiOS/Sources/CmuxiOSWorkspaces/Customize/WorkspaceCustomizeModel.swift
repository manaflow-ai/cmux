import CmuxiOSFeatureKit
import Observation

/// The customize sheet's draft: name, color and icon, compared with the
/// workspace as it was when the sheet opened. Saving turns the changes into
/// at most two intents (rename, customize); nothing changes on the Mac
/// until then.
@MainActor
@Observable
final class WorkspaceCustomizeModel {
    let original: (title: String, color: String?, icon: String?)
    var title: String
    var color: String?
    var icon: String?
    let canRename: Bool
    let canCustomize: Bool
    var save: (@MainActor (WorkspaceCustomizeModel) -> Void)?
    var cancel: (@MainActor () -> Void)?

    init(title: String, color: String?, icon: String?, canRename: Bool, canCustomize: Bool) {
        original = (title, color, icon)
        self.title = title
        self.color = color
        self.icon = icon
        self.canRename = canRename
        self.canCustomize = canCustomize
    }

    var trimmedTitle: String { String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }

    /// The new name, when it changed and is not empty.
    var newTitle: String? {
        canRename && !trimmedTitle.isEmpty && trimmedTitle != original.title ? trimmedTitle : nil
    }

    var colorChange: WorkspaceLookChange { Self.change(from: original.color, to: color) }
    var iconChange: WorkspaceLookChange { Self.change(from: original.icon, to: icon) }

    var hasChanges: Bool {
        newTitle != nil || (canCustomize && (colorChange != .unchanged || iconChange != .unchanged))
    }

    static func change(from old: String?, to new: String?) -> WorkspaceLookChange {
        guard old != new else { return .unchanged }
        return new.map(WorkspaceLookChange.set) ?? .clear
    }
}
