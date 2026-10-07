/// The ports a machine offers to the tunnel browser.
public protocol WebPortSource: Sendable {
    func ports() async throws -> [WebPort]
}
