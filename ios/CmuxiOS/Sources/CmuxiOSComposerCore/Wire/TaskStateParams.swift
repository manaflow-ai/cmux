import CmuxiOSFeatureKit
import Foundation

/// `task.state.set` params.
struct TaskStateParams: Hashable, Sendable, Decodable {
    var task: String
    var state: TaskState
    var tab: String?
}
