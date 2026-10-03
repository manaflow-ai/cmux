import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxHomeUI

/// Pure derivations behind the Home UI: row text, grouping, recipients,
/// search grouping and time buckets. No views, no store.
@Suite struct HomeUIModelTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Lawrence")
    let leo = Participant(id: ParticipantID("user_leo"), kind: .human, displayName: "Leo")
    let chief = Participant(id: ParticipantID("agent_chief"), kind: .agent, displayName: "Chief", agentClass: .chief)
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    func message(_ seq: Seq, by author: Participant, in id: ConversationID, _ text: String) -> Message {
        Message(id: MessageID("msg_\(seq)"), conversation: id, seq: seq, clientMessageID: IdempotencyKey("key_\(seq)"),
                author: author.id, parts: [.text(text)], createdAt: epoch.addingTimeInterval(Double(seq)))
    }

    func rows(_ summaries: [ConversationSummary]) -> [InboxRow] {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: summaries, rev: 1))
        return mirror.inboxRows(log: IntentLog())
    }

    @Test func groupPreviewCarriesTheAuthor() {
        let id = ConversationID("conv_group")
        let last = message(4, by: leo, in: id, "Ship it.")
        let row = rows([ConversationSummary(id: id, title: "Core", participants: [me, leo, chief], lastSeq: 4,
                                            createdAt: epoch, updatedAt: epoch, lastMessage: last,
                                            readCursors: [me.id: 2])])[0]
        let model = ConversationRowModel(row: row, me: me.id)
        #expect(model.preview == "Leo: Ship it.")
        #expect(model.unread == 2)
        #expect(model.avatarParticipants.map(\.id) == [leo.id, chief.id])
        #expect(model.accessibilityLabel(spokenTime: "now").hasPrefix("Core, 2 unread, Leo: Ship it."))
    }

    @Test func directPreviewHasNoPrefixAndMyGroupMessageSaysYou() {
        let direct = ConversationID("conv_direct")
        let group = ConversationID("conv_group")
        let all = rows([
            ConversationSummary(id: direct, participants: [me, chief], lastSeq: 1, createdAt: epoch, updatedAt: epoch,
                                lastMessage: message(1, by: chief, in: direct, "Done."), readCursors: [me.id: 1]),
            ConversationSummary(id: group, participants: [me, leo, chief], lastSeq: 1, createdAt: epoch, updatedAt: epoch,
                                lastMessage: message(1, by: me, in: group, "Status?"), readCursors: [me.id: 1]),
        ])
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, ConversationRowModel(row: $0, me: me.id)) })
        #expect(byID[direct]?.preview == "Done.")
        #expect(byID[direct]?.kind == .chief)
        #expect(byID[group]?.preview == "You: Status?")
    }

    @Test func newIncomingAnnouncesOnlyLaterMessagesFromOthers() throws {
        let id = ConversationID("conv_group")
        let window = TranscriptWindow(messages: [
            message(1, by: leo, in: id, "a"), message(2, by: leo, in: id, "b"),
            message(3, by: me, in: id, "c"), message(4, by: chief, in: id, "d"),
        ], reachedStart: true)
        let items = window.items(pending: [], me: me.id)
        let incoming = items.newIncoming(since: Array(items.prefix(2)), me: me.id)
        #expect(incoming.map(\.key) == [IdempotencyKey("key_4")], "my own message is not announced")
        #expect(items.newIncoming(since: [], me: me.id).isEmpty, "the first render announces nothing")
    }

    @Test func recipientSetParsesDedupesAndResolves() {
        var set = RecipientSet()
        let added = set.add(text: "Sam@Example.org, (415) 555-0100; nope, sam@example.org", defaultCallingCode: "1")
        #expect(added.map(\.address) == [.email("sam@example.org"), .phone("+14155550100")])
        #expect(set.recipients.count == 3)
        #expect(set.hasInvalid)
        #expect(!set.isReady)
        if let invalid = set.recipients.first(where: { $0.state == .invalid }) { set.remove(id: invalid.id) }
        #expect(set.isResolving)
        set.resolve(id: added[0].id, as: .member(leo))
        set.resolve(id: added[1].id, as: .invitable(.phone("+14155550100")))
        #expect(set.isReady)
        #expect(set.hasInvitable)
        #expect(set.recipients.first?.title == "Leo")
        #expect(RecipientSet.defaultCallingCode(region: "JP") == "81")
        #expect(RecipientSet.defaultCallingCode(region: nil) == "1")
    }

    @Test func searchGroupsKeepSourceOrder() {
        let a = ConversationID("conv_a")
        let b = ConversationID("conv_b")
        let hits = [
            HomeSearchHit(conversation: b, message: message(9, by: leo, in: b, "x"), highlights: [0..<1]),
            HomeSearchHit(conversation: a, message: message(3, by: leo, in: a, "x"), highlights: [0..<1]),
            HomeSearchHit(conversation: b, message: message(2, by: leo, in: b, "x"), highlights: [0..<1]),
        ]
        let groups = HomeSearchGroup.group(hits) { $0.rawValue }
        #expect(groups.map(\.conversation) == [b, a])
        #expect(groups[0].hits.count == 2)
        #expect([-2..<3, 5..<40, 50..<60].clampedNSRanges(length: 10)
            == [NSRange(location: 0, length: 3), NSRange(location: 5, length: 5)])
    }

    @Test func rowActionsDependOnStateAndConnection() {
        let id = ConversationID("conv_x")
        let row = rows([ConversationSummary(id: id, participants: [me, leo], lastSeq: 3, createdAt: epoch, updatedAt: epoch,
                                            lastMessage: message(3, by: leo, in: id, "hi"), readCursors: [me.id: 1],
                                            pinRank: 4)])
        let model = ConversationRowModel(row: row[0], me: me.id)
        let online = HomeRowAction.actions(for: model, isOnline: true)
        #expect(online.leading == [.markRead, .unpin])
        #expect(online.trailing == [.mute])
        #expect(HomeRowAction.actions(for: model, isOnline: false).leading.isEmpty)
        #expect(HomeRowAction.nextPinRank(in: row) == 5)
        #expect(HomeRowAction.nextPinRank(in: []) == 0)
    }

    @Test func timeBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let time = HomeTimeFormatting(calendar: calendar, locale: Locale(identifier: "en_US"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 15)))
        #expect(time.bucket(for: now.addingTimeInterval(-3_600), now: now) == .today)
        #expect(time.bucket(for: now.addingTimeInterval(-86_400), now: now) == .yesterday)
        #expect(time.bucket(for: now.addingTimeInterval(-86_400 * 4), now: now) == .thisWeek)
        #expect(time.bucket(for: now.addingTimeInterval(-86_400 * 10), now: now) == .older)
        #expect(time.rowLabel(for: now.addingTimeInterval(-86_400 * 4), now: now) == "Monday")
    }

    @Test func inviteConfirmationLines() {
        #expect(InviteReceipt(contact: .email("a@b.co"), channel: .email, alreadyMember: false).confirmationLine
            == "Emailed to a@b.co.")
        #expect(InviteReceipt(contact: .phone("+14155550100"), channel: .sms, alreadyMember: false).confirmationLine
            == "Texted to +14155550100.")
        #expect(InviteReceipt(contact: .email("a@b.co"), channel: .email, alreadyMember: true).confirmationLine
            == "a@b.co is already on cmux.")
    }
}
