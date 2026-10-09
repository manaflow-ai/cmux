import Foundation

/// The owner's last error on a machine (`CloudMachine.error`).
public struct CloudMachineFailure: Hashable, Sendable {
    public var code: String
    public var message: String
    public var at: Date

    public init(code: String, message: String, at: Date) {
        self.code = code
        self.message = message
        self.at = at
    }
}
