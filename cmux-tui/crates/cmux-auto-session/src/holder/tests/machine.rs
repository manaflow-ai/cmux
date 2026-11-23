//! A Cloud machine's journeys, from the design's "Assignments" and "Handback" and the store's
//! rules as built: the store gives a chat home at the machine's renewal that says nothing is
//! left to run.

use super::super::*;
use super::{answer, has, kinds, request};
use crate::consts::RENEW_MS;
use crate::wire::AssignmentKind;

fn assigned(kind: AssignmentKind, epoch: u64) -> Event {
    Event::Assigned { kind, epoch }
}

fn changed(change: Change, needs_run: bool) -> Event {
    Event::Changed { change, needs_run }
}

/// The store's "holder" to the renewal among `effects`.
fn held(effects: &[Effect]) -> Event {
    Event::Answered { request: request(effects), answer: answer(Verdict::Holder, 2, 3) }
}

/// A machine that took the chat over at epoch 2, ran its turn, stored its last copy and told
/// the store that nothing is left to run.
fn serving(now: u64) -> Chat {
    let chat = Chat::new(Side::Machine, now);
    let (chat, _) = step(chat, assigned(AssignmentKind::Takeover, 2), now);
    let (chat, effects) = step(chat, Event::ImportDone { epoch: 2, snapshot: 3 }, now);
    let (chat, _) = step(chat, held(&effects), now);
    let (chat, effects) = step(chat, changed(Change::TurnEnded, false), now);
    assert_eq!(kinds(&effects), ["upload_events", "upload_snapshot"]);
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: 1, snapshot: 4 }, now);
    assert!(matches!(effects[0], Effect::Renew { needs_run: false, .. }));
    let (chat, effects) = step(chat, held(&effects), now);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    assert_eq!((chat.needs_run, chat.copy), (false, CopyState::Stored));
    chat
}

/// The next renewal of a chat whose tick is due: (the chat, its effects, when it was sent).
fn next_renewal(chat: Chat) -> (Chat, Vec<Effect>, u64) {
    let now = chat.wake_at().expect("a next tick");
    let (chat, effects) = step(chat, Event::Tick, now);
    (chat, effects, now)
}

/// The store's answer to a holder with a laptop standing by.
fn handback_due() -> Answer {
    Answer { handback_due: true, ..answer(Verdict::Holder, 2, 3) }
}

/// The store's "lost" to the renewal among `effects`: the chat is a laptop's, at epoch 3.
fn lost(effects: &[Effect]) -> Event {
    Event::Answered { request: request(effects), answer: answer(Verdict::Lost, 3, 4) }
}

#[test]
fn a_takeover_is_imported_then_its_messages_taken_then_acked_then_renewed() {
    let chat = Chat::new(Side::Machine, 0);
    assert_eq!(chat.state, State::Away);
    assert!(!chat.may_run() && !chat.here());

    let (chat, effects) = step(chat, assigned(AssignmentKind::Takeover, 2), 10);
    assert_eq!(
        chat.state,
        State::Taking { epoch: 2, reason: ImportReason::Takeover, failed: false }
    );
    assert_eq!(effects[0], Effect::Import { reason: ImportReason::Takeover, epoch: 2 });
    // Nothing runs before the import is done.
    assert!(!chat.may_run() && chat.here());

    // The assignment stays until it is acked, so the reader hands it over again.
    let (chat, effects) = step(chat, assigned(AssignmentKind::Takeover, 2), 20);
    assert!(effects.is_empty(), "{effects:?}");

    // The store keeps a `deliver` while a message is unread, so the inbox goes first. The
    // chat was given here because it has work, and the store hears so.
    let (chat, effects) = step(chat, Event::ImportDone { epoch: 2, snapshot: 3 }, 500);
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    assert_eq!(kinds(&effects)[..3], ["drain_inbox", "ack_assignment", "renew"]);
    assert_eq!(effects[1], Effect::AckAssignment { epoch: 2 });
    assert!(matches!(effects[2], Effect::Renew { epoch: 2, standby: false, needs_run: true, .. }));
    assert!(chat.may_run());
    assert_eq!(chat.snapshot, 3);
}

#[test]
fn a_failed_import_is_tried_again() {
    let (chat, _) = step(Chat::new(Side::Machine, 0), assigned(AssignmentKind::Takeover, 2), 0);
    let (chat, effects) = step(chat, Event::ImportFailed { epoch: 2 }, 100);
    assert!(effects.is_empty(), "{effects:?}");
    assert!(!has(&step(chat, Event::Tick, 200).1, "import"));
    let (chat, effects) = step(chat, Event::Tick, RENEW_MS);
    assert_eq!(effects[0], Effect::Import { reason: ImportReason::Takeover, epoch: 2 });
    assert!(!chat.may_run());
}

#[test]
fn a_create_and_a_delivery_are_imported_for_their_reason() {
    for (kind, reason) in [
        (AssignmentKind::Create, ImportReason::Create),
        (AssignmentKind::Deliver, ImportReason::Deliver),
    ] {
        let (chat, effects) = step(Chat::new(Side::Machine, 0), assigned(kind, 1), 0);
        assert_eq!(chat.state, State::Taking { epoch: 1, reason, failed: false });
        assert_eq!(effects[0], Effect::Import { reason, epoch: 1 });
    }
}

#[test]
fn a_delivery_for_a_chat_the_machine_runs_drains_the_inbox() {
    // The store hears "at work" before the messages are acked: until the next copy they are
    // only on this machine.
    let (chat, effects) = step(serving(0), assigned(AssignmentKind::Deliver, 2), 100);
    assert_eq!(kinds(&effects)[..3], ["renew", "drain_inbox", "ack_assignment"]);
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
    assert_eq!(effects[2], Effect::AckAssignment { epoch: 2 });
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    // A repeat of the takeover it already imported (its ack was lost) is acked again.
    let (_, effects) = step(chat, assigned(AssignmentKind::Takeover, 2), 200);
    assert_eq!(effects, [Effect::AckAssignment { epoch: 2 }]);
}

#[test]
fn a_newer_assignment_replaces_what_the_machine_ran() {
    let (chat, effects) = step(serving(0), assigned(AssignmentKind::Takeover, 4), 100);
    assert_eq!(
        effects[..3],
        [
            Effect::KillTree,
            Effect::WriteLeftoverPatch,
            Effect::Import { reason: ImportReason::Takeover, epoch: 4 }
        ]
    );
    assert_eq!(
        chat.state,
        State::Taking { epoch: 4, reason: ImportReason::Takeover, failed: false }
    );
}

#[test]
fn an_idle_machine_with_its_copy_stored_is_relieved_by_its_renewal() {
    let (chat, effects, now) = next_renewal(serving(0));
    assert!(matches!(effects[0], Effect::Renew { needs_run: false, .. }));
    // A laptop stands by: the store gave it the chat and answers "lost". It has everything
    // this machine did, so nothing is kept.
    let (chat, effects) = step(chat, lost(&effects), now + 50);
    assert_eq!(chat.state, State::Away);
    assert_eq!(effects, [Effect::KillTree]);
    assert_eq!(chat.wake_at(), None);
    assert!(!chat.may_run() && !chat.here());
}

#[test]
fn a_chat_at_work_is_not_given_home_until_its_last_copy_is_stored() {
    let (chat, effects) = step(serving(0), changed(Change::TurnStarted, true), 1_000);
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
    let due = Event::Answered { request: request(&effects), answer: handback_due() };
    let (chat, effects) = step(chat, due, 1_100);
    assert!(effects.is_empty(), "{effects:?}");

    // The turn ends with nothing queued. The copy goes, and until the store has it the
    // machine still says it is at work: on "nothing left to run" the store would give the
    // chat home without what the turn did last.
    let (chat, effects) = step(chat, changed(Change::TurnEnded, false), 9_000);
    assert_eq!(kinds(&effects), ["upload_events", "upload_snapshot"]);
    assert!(chat.reports_needs_run());
    let (chat, effects, now) = next_renewal(chat);
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
    let (chat, effects) = step(chat, held(&effects), now + 50);
    assert!(effects.is_empty(), "{effects:?}");

    // The copy is stored: the machine says so at once, and the store's answer ends its hold.
    let stored = Event::SnapshotStored { copy: chat.copies, snapshot: 5 };
    let (chat, effects) = step(chat, stored, now + 900);
    assert!(matches!(effects[0], Effect::Renew { needs_run: false, .. }));
    let (chat, effects) = step(chat, lost(&effects), now + 950);
    assert_eq!((chat.state, effects), (State::Away, vec![Effect::KillTree]));
}

#[test]
fn an_older_copy_landing_does_not_make_the_machine_idle() {
    let (chat, _) = step(serving(0), changed(Change::ToolEnded, true), 1_000);
    let (chat, _) = step(chat, changed(Change::TurnEnded, false), 2_000);
    let (first, second) = (chat.copies - 1, chat.copies);
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: first, snapshot: 5 }, 2_500);
    assert!(effects.is_empty(), "{effects:?}");
    assert!(chat.reports_needs_run());
    let (_, effects) = step(chat, Event::SnapshotStored { copy: second, snapshot: 6 }, 3_000);
    assert!(matches!(effects[0], Effect::Renew { needs_run: false, .. }));
}

#[test]
fn a_copy_that_failed_is_sent_again_before_the_machine_says_it_is_idle() {
    let (chat, _) = step(serving(0), changed(Change::TurnStarted, true), 1_000);
    let (chat, _) = step(chat, changed(Change::TurnEnded, false), 2_000);
    let failed = Event::SnapshotFailed { copy: chat.copies, too_large: false };
    let (chat, effects) = step(chat, failed, 2_500);
    assert!(effects.is_empty(), "{effects:?}");
    let (chat, effects, _) = next_renewal(chat);
    assert_eq!(kinds(&effects)[..3], ["upload_events", "upload_snapshot", "renew"]);
    assert!(matches!(effects[2], Effect::Renew { needs_run: true, .. }));

    // Past the cap there is no copy to send: the chat stays on the machine.
    let too_large = Event::SnapshotFailed { copy: chat.copies, too_large: true };
    let (chat, _) = step(chat, too_large, chat.seen_at + 100);
    let (_, effects, _) = next_renewal(chat);
    assert!(!has(&effects, "upload_snapshot"));
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
}

#[test]
fn a_store_that_did_not_give_an_idle_chat_home_gets_one_more_copy() {
    // The machine said nothing is left to run, a laptop stands by, and the store still
    // answers "holder": its snapshot does not cover its last event.
    let (chat, effects, now) = next_renewal(serving(0));
    let due = Event::Answered { request: request(&effects), answer: handback_due() };
    let (chat, effects) = step(chat, due, now + 50);
    assert_eq!(kinds(&effects), ["upload_events", "upload_snapshot"]);
    assert_eq!((chat.state, chat.copy), (State::Serving { epoch: 2 }, CopyState::Sending));
    // New prompts may still arrive; otherwise the copy is awaited, not sent again.
    assert!(chat.may_run());
    let (chat, effects, now) = next_renewal(chat);
    let due = Event::Answered { request: request(&effects), answer: handback_due() };
    let (_, effects) = step(chat, due, now + 50);
    assert!(effects.is_empty(), "{effects:?}");
}

#[test]
fn a_message_comes_before_a_handback() {
    let (chat, effects, now) = next_renewal(serving(0));
    let both = Answer { inbox_pending: true, ..handback_due() };
    let answered = Event::Answered { request: request(&effects), answer: both };
    let (chat, effects) = step(chat, answered, now + 50);
    assert_eq!(kinds(&effects)[..3], ["renew", "drain_inbox", "ack_assignment"]);
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    // The messages are work until the chat's next change says otherwise.
    assert!(chat.needs_run);
}

#[test]
fn a_chat_with_no_laptop_standing_by_stays_on_the_machine() {
    let (chat, effects, now) = next_renewal(serving(0));
    let (chat, effects) = step(chat, held(&effects), now + 50);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, State::Serving { epoch: 2 });
}

/// A paused machine is not a lost one: with no answer for five minutes it still serves.
#[test]
fn a_machine_that_cannot_reach_the_cloud_keeps_the_chat() {
    let mut chat = serving(0);
    while chat.seen_at < 300_000 {
        let (next, effects, now) = next_renewal(chat);
        let unanswered = Event::Unanswered { request: request(&effects) };
        let (next, effects) = step(next, unanswered, now + 1);
        assert!(effects.is_empty(), "{effects:?}");
        assert_eq!(next.state, State::Serving { epoch: 2 });
        assert!(next.may_run());
        chat = next;
    }
}

#[test]
fn a_machine_that_wakes_only_renews() {
    let (chat, effects) = step(serving(0), Event::Wake, 86_400_000);
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    assert_eq!(kinds(&effects), ["renew", "schedule_at"]);
}

/// A daemon that restarts cannot know the store has what the chat did last: it says "at
/// work" and copies again before it says anything else.
#[test]
fn a_machine_whose_daemon_restarts_copies_before_it_says_it_is_idle() {
    let (chat, effects) = Chat::resume(Side::Machine, 7, 1, 0);
    assert_eq!(chat.state, State::Serving { epoch: 7 });
    assert_eq!(kinds(&effects), ["renew", "schedule_at"]);
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
    let (chat, effects, now) = next_renewal(chat);
    assert_eq!(kinds(&effects)[..3], ["upload_events", "upload_snapshot", "renew"]);
    let stored = Event::SnapshotStored { copy: chat.copies, snapshot: 2 };
    let (_, effects) = step(chat, stored, now + 100);
    assert!(matches!(effects[0], Effect::Renew { needs_run: false, .. }));
}

#[test]
fn a_machine_that_loses_a_chat_at_work_keeps_what_it_wrote() {
    let (chat, effects) = step(serving(0), changed(Change::TurnStarted, true), 1_000);
    let (chat, effects) = step(chat, lost(&effects), 1_100);
    assert_eq!(chat.state, State::Away);
    assert_eq!(effects, [Effect::KillTree, Effect::WriteLeftoverPatch]);
    assert_eq!(chat.wake_at(), None);
    // The next chat that comes here starts clean.
    assert_eq!((chat.needs_run, chat.copy), (false, CopyState::Stored));
}

#[test]
fn the_person_switches_mean_nothing_on_a_machine() {
    for (name, chat) in sample_chats() {
        if chat.side() != Side::Machine {
            continue;
        }
        for event in [Event::AutoOn, Event::AutoOff] {
            let (after, effects) = step(chat, event, SAMPLE_AT);
            assert_eq!(after.state, chat.state, "{name}");
            assert!(effects.is_empty(), "{name}: {effects:?}");
        }
    }
}
