import Foundation

/// A model an agent offers on a Mac, with the effort steps it accepts.
public struct ComposerModel: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var efforts: [String]
    public var defaultEffort: String?

    public init(id: String, label: String? = nil, efforts: [String] = [], defaultEffort: String? = nil) {
        self.id = id
        self.label = label ?? id
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
}
