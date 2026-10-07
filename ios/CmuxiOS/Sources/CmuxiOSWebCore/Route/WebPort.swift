/// A forwardable port as the list shows it.
public struct WebPort: Hashable, Sendable, Identifiable {
    public enum Source: String, Hashable, Sendable {
        case detected, allowed
    }

    public var port: UInt16
    public var source: Source
    public var workspace: String?
    public var process: String?

    public var id: UInt16 { port }

    public init(port: UInt16, source: Source, workspace: String? = nil, process: String? = nil) {
        self.port = port
        self.source = source
        self.workspace = workspace
        self.process = process
    }
}
