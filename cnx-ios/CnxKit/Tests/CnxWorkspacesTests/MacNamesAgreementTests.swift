import CnxModel
import Foundation
import Testing
@testable import CnxWorkspaces

/// Settings round 2: Workspaces and Settings → Devices name and date a Mac
/// the same way (one tag scope and spelling, one "Last seen" formatter).
@MainActor @Suite struct MacNamesAgreementTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    // A same-name pair split across two teams, and a third pair in one team.
    static let teams = [
        Team(id: "t1", name: "Manaflow", macs: [
            MacDevice(id: "8c41e0d2-3f2a", name: "Aziz's MacBook Pro", isOnline: true),
            MacDevice(id: "mini-4", name: "mini 4", isOnline: true),
        ]),
        Team(id: "t2", name: "Personal", macs: [
            MacDevice(id: "5b97a6f1-91c7", name: "Aziz's MacBook Pro", isOnline: false, lastSeenAt: now.addingTimeInterval(-7200)),
        ]),
    ]

    @Test func workspacesAndSettingsTagEveryMacAlike() {
        let account = Self.teams.flatMap(\.macs)
        // Workspaces: the active team's filter, tagged over the account.
        let active = Self.teams[0].macs
        let entries = MacFilterMemo().entries(MacFilterMemo.Input(macs: active, accountMacs: account, connection: [:],
                                                                 linkStatus: [:], live: false, now: Self.now))
        let workspaces = MacFilterMemo().names(account)
        // Settings → Devices: the account's teams plus the service's list.
        let service = account.map { (id: $0.id, name: $0.name) }
        let settings = MacNameDisambiguation(account: Self.teams, extra: service)
        for mac in account {
            #expect(workspaces.tag(for: mac.id) == settings.tag(for: mac.id))
            #expect(workspaces.displayName(mac) == settings.displayName(id: mac.id, name: mac.name))
        }
        // The other team's namesake still tags the active team's Mac.
        #expect(entries.first { $0.id == "8c41e0d2-3f2a" }?.title == "Aziz's MacBook Pro 3F2A")
        #expect(entries.first { $0.id == "mini-4" }?.title == "mini 4")
        #expect(settings.displayName(id: "5b97a6f1-91c7", name: "Aziz's MacBook Pro") == "Aziz's MacBook Pro 91C7")
    }

    @Test func lastSeenAgreesAcrossACachedMinute() {
        // The filter caches by the minute; a row formats at any second of it.
        let seen = Date(timeIntervalSince1970: 1_800_000_000 - 7200 + 15)
        for offset in stride(from: 0.0, to: 60, by: 5) {
            let now = Date(timeIntervalSince1970: 1_800_000_000 + offset)
            let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
            #expect(RelativeStamp(now: now).presence(isOnline: false, lastSeenAt: seen)
                    == RelativeStamp(now: minute).presence(isOnline: false, lastSeenAt: seen))
        }
        #expect(RelativeStamp(now: Self.now).presence(isOnline: false, lastSeenAt: seen) == "Last seen 2h ago")
    }
}
