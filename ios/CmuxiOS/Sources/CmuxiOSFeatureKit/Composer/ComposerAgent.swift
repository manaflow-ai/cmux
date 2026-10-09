import Foundation

/// An agent the composer can launch, with its models and effort levels, as
/// the target Mac advertises it.
public struct ComposerAgent: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Model ids (kept for callers that only need names).
    public var models: [String]
    /// Every effort step any model offers.
    public var efforts: [String]
    /// Models with labels and per-model efforts (effort follows the model).
    public var modelOptions: [ComposerModel]
    public var defaultModel: String?
    /// Why the Mac cannot run this agent now ("Not signed in"); nil when it can.
    public var unavailableReason: String?

    public init(id: String, name: String, models: [String], efforts: [String]) {
        self.init(id: id, name: name, modelOptions: models.map { ComposerModel(id: $0, efforts: efforts) },
                  defaultModel: models.first)
    }

    public init(id: String, name: String, modelOptions: [ComposerModel], defaultModel: String? = nil,
                unavailableReason: String? = nil) {
        self.id = id
        self.name = name
        self.modelOptions = modelOptions
        self.models = modelOptions.map(\.id)
        var efforts: [String] = []
        for step in modelOptions.flatMap(\.efforts) where !efforts.contains(step) { efforts.append(step) }
        self.efforts = efforts
        self.defaultModel = defaultModel
        self.unavailableReason = unavailableReason
    }

    public var isAvailable: Bool { unavailableReason == nil }

    public func model(_ id: String?) -> ComposerModel? {
        guard let id else { return nil }
        return modelOptions.first { $0.id == id }
    }
}
