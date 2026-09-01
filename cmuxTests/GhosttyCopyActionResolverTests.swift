import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct GhosttyCopyActionResolverTests {
    private let resolver = GhosttyCopyActionResolver()

    private func binding(
        _ flavor: GhosttyCopyActionResolver.Flavor,
        shortcut: StoredShortcut = GhosttyCopyActionResolver.standardCopyShortcut
    ) -> GhosttyCopyActionResolver.Binding {
        GhosttyCopyActionResolver.Binding(flavor: flavor, shortcut: shortcut)
    }

    @Test func mixedFlavorUsesGhosttyDefaultActionSpelling() {
        #expect(
            GhosttyCopyActionResolver.Flavor.mixed.bindingAction
                == GhosttyCopyActionResolver.defaultAction
        )
    }

    @Test func everyFlavorIsPassedThroughToGhostty() {
        let standard = GhosttyCopyActionResolver.standardCopyShortcut

        for flavor in GhosttyCopyActionResolver.Flavor.allCases {
            #expect(
                resolver.resolve(bindings: [binding(flavor, shortcut: standard)])
                    == flavor.bindingAction
            )
        }
    }

    @Test func standardCopyBindingUsesConfiguredPlainFlavor() {
        #expect(
            resolver.resolve(bindings: [binding(.plain)])
                == "copy_to_clipboard:plain"
        )
    }

    @Test func noStandardFlavorOverrideKeepsGhosttyMixedDefault() {
        let nonStandardShortcut = StoredShortcut(
            key: "c",
            command: true,
            shift: true,
            option: false,
            control: false
        )

        #expect(
            resolver.resolve(bindings: [binding(.plain, shortcut: nonStandardShortcut)])
                == GhosttyCopyActionResolver.defaultAction
        )
    }

    @Test func conflictingStandardFlavorBindingsFallBackToMixedDefault() {
        let standard = GhosttyCopyActionResolver.standardCopyShortcut

        #expect(
            resolver.resolve(bindings: [
                binding(.plain, shortcut: standard),
                binding(.html, shortcut: standard),
            ]) == GhosttyCopyActionResolver.defaultAction
        )
    }
}
