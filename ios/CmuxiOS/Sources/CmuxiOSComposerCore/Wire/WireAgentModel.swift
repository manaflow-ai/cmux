import Foundation

/// `task.schema.json` `AgentModel`.
struct WireAgentModel: Hashable, Sendable, Decodable {
    var id: String
    var label: String?
    var efforts: [String]?
    var defaultEffort: String?

    enum CodingKeys: String, CodingKey {
        case id, label, efforts
        case defaultEffort = "default_effort"
    }
}
