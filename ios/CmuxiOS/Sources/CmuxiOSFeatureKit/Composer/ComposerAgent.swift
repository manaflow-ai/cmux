import Foundation

/// An agent the composer can launch, with its models and effort levels.
public struct ComposerAgent: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var models: [String]
    public var efforts: [String]

    public init(id: String, name: String, models: [String], efforts: [String]) {
        self.id = id
        self.name = name
        self.models = models
        self.efforts = efforts
    }
}
