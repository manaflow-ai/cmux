import AppKit
import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the machine Rename entrypoint. The prompt's text is
/// owned by ``MachineRowActions``, but the menu must hand it the same
/// human-facing name that the machine row renders.
@MainActor
@Suite("Cloud machine rename prompt")
struct CloudMachineRenamePromptTests {
    @Test("machine menu passes the current display label to Rename")
    func passesDisplayLabel() throws {
        var received: (String, String?)?
        let verbs = Self.verbs { id, label in received = (id, label) }
        let machine = Self.machine(label: "Build machine", slug: "sleepy-teal-otter")

        try Self.performRename(in: verbs.manageEntries(machine))

        #expect(received?.0 == machine.id)
        #expect(received?.1 == machine.displayName)
    }

    @Test("machine menu passes the generated name when no display label exists")
    func passesGeneratedName() throws {
        var received: (String, String?)?
        let verbs = Self.verbs { id, label in received = (id, label) }
        let machine = Self.machine(label: nil, slug: "sleepy-teal-otter")

        try Self.performRename(in: verbs.manageEntries(machine))

        #expect(received?.0 == machine.id)
        #expect(received?.1 == machine.displayName)
    }

    private static func machine(label: String?, slug: String?) -> MachineSnapshot {
        MachineSnapshot(
            id: "vm-1f7ddfedaa024f559b-d0b959327fe3f6",
            provider: "freestyle",
            image: "cmux-devbox",
            isDesktop: false,
            activity: .ready,
            label: label,
            slug: slug
        )
    }

    private static func verbs(
        promptRename: @escaping @MainActor (String, String?) -> Void
    ) -> CloudMachineMenuVerbs {
        CloudMachineMenuVerbs(
            openShell: { _ in },
            newWorkspace: { _ in },
            openDesktop: { _ in },
            runCommand: { _, _ in },
            promptRename: promptRename,
            copyToPasteboard: { _ in },
            confirmDelete: { _ in },
            promptUpgrade: {}
        )
    }

    private static func performRename(in entries: [CloudMenuEntry]) throws {
        let action = try #require(entries.compactMap { entry -> CloudMenuAction? in
            guard case .action(let action) = entry else { return nil }
            return action.id.hasSuffix(".rename") ? action : nil
        }.first)
        action.perform()
    }
}
