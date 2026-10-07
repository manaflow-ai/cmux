import Foundation

/// A non-empty section of rows.
public struct CloudMachineSection: Identifiable, Hashable, Sendable {
    public var kind: CloudMachineSectionKind
    public var rows: [CloudMachineRow]

    public var id: CloudMachineSectionKind { kind }

    public init(kind: CloudMachineSectionKind, rows: [CloudMachineRow]) {
        self.kind = kind
        self.rows = rows
    }
}
