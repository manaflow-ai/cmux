import Foundation

/// A plan the agent wants approved (`review` with subject `plan`).
public struct FeedPlan: Hashable, Sendable {
    /// The plan reference (a path or attachment id); the text is in `body`.
    public var ref: String
    public var checklist: [String]

    public init(ref: String = "", checklist: [String] = []) {
        self.ref = ref
        self.checklist = checklist
    }
}
