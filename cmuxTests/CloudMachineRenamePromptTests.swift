import CmuxCloud
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud machine rename prompt")
struct CloudMachineRenamePromptTests {
    @Test("uses the visible machine label in the prompt")
    func usesVisibleLabel() {
        let machine = MachineSnapshot(
            id: "vm_123",
            provider: "freestyle",
            image: "cmux-devbox",
            isDesktop: false,
            activity: .ready,
            label: "  wandering-blue-hawk  ",
            slug: "generated-name"
        )
        #expect(
            MachineRowActions.renamePromptDisplayName(for: machine) == "wandering-blue-hawk"
        )
    }

    @Test("uses the generated name when no label exists")
    func fallsBackToGeneratedName() {
        let machine = MachineSnapshot(
            id: "vm_123",
            provider: "freestyle",
            image: "cmux-devbox",
            isDesktop: false,
            activity: .ready,
            label: nil,
            slug: "generated-name"
        )
        #expect(MachineRowActions.renamePromptDisplayName(for: machine) == "generated-name")
    }

    @Test("uses a localized fallback when no human name exists")
    func fallsBackToLocalizedName() {
        let machine = MachineSnapshot(
            id: "vm_123",
            provider: "freestyle",
            image: "cmux-devbox",
            isDesktop: false,
            activity: .ready,
            label: "   ",
            slug: "\n"
        )
        #expect(MachineRowActions.renamePromptDisplayName(for: machine) == "Cloud machine")
    }
}
