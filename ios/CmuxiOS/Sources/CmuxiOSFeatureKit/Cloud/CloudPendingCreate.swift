import Foundation

/// A create the owner has not answered yet (shown as a "Creating" row).
public struct CloudPendingCreate: Identifiable, Hashable, Sendable {
    public var id: IntentKey
    public var name: String?
    public var size: CloudMachineSize

    public init(id: IntentKey, name: String?, size: CloudMachineSize) {
        self.id = id
        self.name = name
        self.size = size
    }
}
