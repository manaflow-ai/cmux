import CmuxiOSFeatureKit
import Foundation

/// `task.schema.json` `Agent`: a harness the Mac advertises.
struct WireAgent: Hashable, Sendable, Decodable {
    var id: String
    var name: String?
    var models: [WireAgentModel]?
    var defaultModel: String?
    var unavailable: String?

    enum CodingKeys: String, CodingKey {
        case id, name, models, unavailable
        case defaultModel = "default_model"
    }

    var composerAgent: ComposerAgent {
        ComposerAgent(
            id: id, name: name ?? id,
            modelOptions: (models ?? []).map {
                ComposerModel(id: $0.id, label: $0.label, efforts: $0.efforts ?? [], defaultEffort: $0.defaultEffort)
            },
            defaultModel: defaultModel, unavailableReason: unavailable)
    }
}
