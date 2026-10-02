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
        #expect(
            MachineRowActions.renamePromptDisplayName(
                id: "vm_123",
                currentLabel: "  wandering-blue-hawk  "
            ) == "wandering-blue-hawk"
        )
    }

    @Test("falls back to the stable id when no label exists")
    func fallsBackToID() {
        #expect(MachineRowActions.renamePromptDisplayName(id: "vm_123", currentLabel: nil) == "vm_123")
        #expect(MachineRowActions.renamePromptDisplayName(id: "vm_123", currentLabel: "   ") == "vm_123")
    }
}
