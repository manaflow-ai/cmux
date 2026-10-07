public import CmuxiOSFeatureKit
import Foundation

/// One memory size of the create sheet.
public struct CloudSizeOption: Identifiable, Hashable, Sendable {
    public var memoryMB: Int
    /// The plan lists it but needs an upgrade (`cloud.size.locked`).
    public var isLocked: Bool

    public var id: Int { memoryMB }
    /// CPU and disk use the owner's defaults.
    public var size: CloudMachineSize { CloudMachineSize(memoryMB: memoryMB) }

    public init(memoryMB: Int, isLocked: Bool) {
        self.memoryMB = memoryMB
        self.isLocked = isLocked
    }
}
