import CmuxTerminalCore
import Testing

/// Keeps the app-host selector wired to the package-owned copy resolver.
///
/// The complete flavor and fallback matrix lives in `CmuxTerminalCoreTests`;
/// this smoke test verifies the executable test target can consume the public
/// package API instead of silently executing zero tests.
@Suite struct GhosttyCopyActionResolverTests {
    @Test func appTargetUsesPackageResolver() {
        let binding = GhosttyCopyActionResolver.Binding(
            flavor: .plain,
            shortcut: GhosttyCopyActionResolver.standardCopyShortcut
        )

        #expect(
            GhosttyCopyActionResolver().resolve(bindings: [binding])
                == "copy_to_clipboard:plain"
        )
    }
}
