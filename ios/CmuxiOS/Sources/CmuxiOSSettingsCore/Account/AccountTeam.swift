/// A team the signed-in user belongs to (Stack Auth team summary).
public struct AccountTeam: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
