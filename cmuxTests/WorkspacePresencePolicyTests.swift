import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct WorkspacePresencePolicyTests {
    private func participant(
        id: String,
        viewerID: String?,
        seen: TimeInterval,
        device: String = "device"
    ) -> WorkspacePresenceParticipant {
        WorkspacePresenceParticipant(
            id: id,
            viewerID: viewerID,
            displayName: id,
            avatarURL: nil,
            deviceID: device,
            tag: "default",
            lastSeenAt: Date(timeIntervalSince1970: seen)
        )
    }

    @Test func deduplicatesOneCollaboratorAcrossDevicesAndExcludesSelf() {
        let participants = WorkspacePresencePolicy.participants(
            from: [
                participant(id: "ada-old", viewerID: "ada", seen: 1, device: "old"),
                participant(id: "ada-new", viewerID: "ada", seen: 2, device: "new"),
                participant(id: "me", viewerID: "me", seen: 3),
            ],
            currentViewerID: "me"
        )
        #expect(participants.map(\.id) == ["ada-new"])
    }

    @Test func avatarLayoutCapsVisibleStackAndReportsOverflow() {
        let participants = (0..<6).map {
            participant(id: "user-\($0)", viewerID: "user-\($0)", seen: TimeInterval($0))
        }
        let layout = WorkspacePresencePolicy.avatarLayout(participants: participants, maximumVisible: 3)
        #expect(layout.visible.count == 3)
        #expect(layout.overflowCount == 3)
    }

    @Test func singleUserWorkspaceHasNoCollaboratorRows() {
        let participants = WorkspacePresencePolicy.participants(
            from: [participant(id: "me", viewerID: "me", seen: 1)],
            currentViewerID: "me"
        )
        #expect(participants.isEmpty)
    }
}
