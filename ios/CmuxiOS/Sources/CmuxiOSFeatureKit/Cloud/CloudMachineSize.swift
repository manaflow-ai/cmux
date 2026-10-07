import Foundation

/// A machine size. Every field is optional on the wire; the plan decides
/// which sizes are allowed (`cloud.size.locked`).
public struct CloudMachineSize: Hashable, Sendable {
    public var cpu: Int?
    public var memoryMB: Int?
    public var diskMB: Int?

    public init(cpu: Int? = nil, memoryMB: Int? = nil, diskMB: Int? = nil) {
        self.cpu = cpu
        self.memoryMB = memoryMB
        self.diskMB = diskMB
    }
}
