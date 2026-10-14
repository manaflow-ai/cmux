import CnxModel
import Foundation

/// How the Workspaces list orders rows inside each Mac.
public enum WorkspaceSort: String, CaseIterable, Identifiable, Sendable {
    case recent, name
    public var id: String { rawValue }
    var title: String { self == .recent ? "Recent" : "Name" }

    func ordered(_ items: [Workspace]) -> [Workspace] {
        switch self {
        case .recent: items.sorted { $0.lastActivityAt > $1.lastActivityAt }
        case .name: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}
