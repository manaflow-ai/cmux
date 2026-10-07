import Foundation

/// A reusable prompt the user inserts with `/name`. Text only: templates
/// never carry shell commands (the shipping app's templates did).
public struct PromptTemplate: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    /// The `/name` the user types (letters, digits, `-`).
    public var name: String
    public var title: String
    public var body: String
    public var isBuiltIn: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String, title: String, body: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = PromptTemplate.slug(name)
        self.title = title
        self.body = body
        self.isBuiltIn = isBuiltIn
    }

    /// Lowercased letters, digits and `-`, at most 32.
    public static func slug(_ raw: String) -> String {
        let mapped = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(collapsed.prefix(32))
    }
}
