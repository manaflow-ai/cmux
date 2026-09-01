import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyCopyActionResolverTests: XCTestCase {
    func testStandardCopyBindingUsesConfiguredPlainFlavor() {
        let resolver = GhosttyCopyActionResolver()
        let binding = GhosttyCopyActionResolver.Binding(
            flavor: .plain,
            shortcut: GhosttyCopyActionResolver.standardCopyShortcut
        )

        XCTAssertEqual(
            resolver.resolve(bindings: [binding]),
            "copy_to_clipboard:plain"
        )
    }

    func testNoStandardFlavorOverrideKeepsGhosttyMixedDefault() {
        let resolver = GhosttyCopyActionResolver()
        let binding = GhosttyCopyActionResolver.Binding(
            flavor: .plain,
            shortcut: StoredShortcut(
                key: "c",
                command: true,
                shift: true,
                option: false,
                control: false
            )
        )

        XCTAssertEqual(
            resolver.resolve(bindings: [binding]),
            GhosttyCopyActionResolver.defaultAction
        )
    }
}
