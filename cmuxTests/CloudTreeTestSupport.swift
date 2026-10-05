import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension Array where Element == CloudTreeNode {
    /// Removes the account-management section when a test is asserting the
    /// machine/device tree shape. The production tree intentionally appends
    /// CodeRouter after those sections.
    var withoutCoderouterSection: [CloudTreeNode] {
        filter { $0.id != "coderouter-section" && !$0.id.hasPrefix("coderouter-section/") }
    }
}
