import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Notification command palette action contracts")
struct CommandPaletteNotificationActionContractTests {
    @Test("Notification commands expose only the deterministic unread setter argument")
    func notificationCommandSchemas() throws {
        let contributions = ContentView.commandPaletteNotificationCommandContributions()
        #expect(Set(contributions.map(\.commandId)) == Set([
            "palette.showNotifications",
            "palette.jumpUnread",
            "palette.toggleUnread",
            "palette.markOldestUnreadAndJumpNext",
        ]))

        let toggle = try #require(contributions.first { $0.commandId == "palette.toggleUnread" })
        #expect(toggle.arguments == [
            CmuxActionArgumentDefinition(
                name: "unread",
                valueType: .boolean,
                required: false
            ),
        ])

        let jump = try #require(contributions.first { $0.commandId == "palette.jumpUnread" })
        var context = CommandPaletteContextSnapshot()
        #expect(!jump.enablement(context))
        context.setBool(CommandPaletteContextKeys.notificationsCanJumpUnread, true)
        #expect(jump.enablement(context))

        for contribution in contributions where contribution.commandId != "palette.toggleUnread" {
            #expect(contribution.arguments.isEmpty)
        }
    }
}
