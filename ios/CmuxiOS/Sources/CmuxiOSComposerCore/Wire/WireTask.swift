import CmuxiOSFeatureKit
import Foundation

/// `task.schema.json` `Task`.
struct WireTask: Hashable, Sendable, Decodable {
    var id: String
    var host: String
    var workspace: String?
    var tab: String?
    var agent: String
    var state: TaskState
    var title: String?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, host, workspace, tab, agent, state, title
        case createdAt = "created_at"
    }

    var record: TaskRecord {
        TaskRecord(id: id, hostID: HostID(host), workspaceID: workspace, tabID: tab, agentID: agent, state: state,
                   title: title, createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000))
    }
}
