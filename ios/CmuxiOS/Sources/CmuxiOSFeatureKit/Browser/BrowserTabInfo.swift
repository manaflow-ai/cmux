public import Foundation

/// A browser tab record as the host's workspace store publishes it.
public struct BrowserTabInfo: Identifiable, Hashable, Sendable {
    /// The daemon public id (`tab_...`).
    public var id: String
    public var workspaceID: WorkspaceSummary.ID?
    public var title: String
    public var url: URL?

    public init(id: String, workspaceID: WorkspaceSummary.ID?, title: String, url: URL?) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.url = url
    }
}
