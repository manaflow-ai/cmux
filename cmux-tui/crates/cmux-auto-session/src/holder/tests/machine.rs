//! A Cloud machine's journeys, from the design's "Assignments" and "Handback".

use super::super::*;
use super::{answer, has, kinds, request};
use crate::consts::RENEW_MS;
use crate::wire::AssignmentKind;

fn assigned(kind: AssignmentKind, epoch: u64) -> Event {
    Event::Assigned { kind, epoch }
}

/// A machine that took the chat over at epoch 2 and serves it, idle.
fn serving(now: u64) -> Chat {
    let chat = Chat::new(Side::Machine, now);
    let (chat, _) = step(chat, assigned(AssignmentKind::Takeover, 2), now);
    let (chat, effects) = step(chat, Event::ImportDone { epoch: 2, snapshot: 3 }, now);
    let held =
        Event::Answered { request: request(&effects), answer: answer(Verdict::Holder, 2, 3) };
    let (chat, effects) = step(chat, held, now);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    chat
}

/// The next renewal of a chat whose tick is due: (the chat, the request, when it was sent).
fn next_renewal(chat: Chat) -> (Chat, u64, u64) {
    let now = chat.wake_at().expect("a next tick");
    let (chat, effects) = step(chat, Event::Tick, now);
    (chat, request(&effects), now)
}

/// The store's answer to a holder with a laptop standing by.
fn handback_due() -> Answer {
    Answer { handback_due: true, ..answer(Verdict::Holder, 2, 3) }
}

/// A machine that started a handback: the chat, and the copy the release waits for.
fn handing_back() -> (Chat, u64) {
    let (chat, request, now) = next_renewal(serving(0));
    let (chat, effects) = step(chat, Event::Answered { request, answer: handback_due() }, now);
    let copy = match effects.as_slice() {
        [Effect::UploadEvents { epoch: 2 }, Effect::UploadSnapshot { epoch: 2, copy }] => *copy,
        _ => panic!("a handback starts with a last copy: {effects:?}"),
    };
    assert_eq!(chat.state, State::HandingBack { epoch: 2, copy });
    (chat, copy)
}

#[test]
fn a_takeover_is_imported_then_acked_then_renewed() {
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

    let (chat, effects) = step(chat, Event::ImportDone { epoch: 2, snapshot: 3 }, 500);
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    assert_eq!(kinds(&effects)[..3], ["ack_assignment", "drain_inbox", "renew"]);
    assert_eq!(effects[0], Effect::AckAssignment { epoch: 2 });
    assert!(matches!(effects[2], Effect::Renew { epoch: 2, standby: false, .. }));
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
    let (chat, effects) = step(serving(0), assigned(AssignmentKind::Deliver, 2), 100);
    assert_eq!(effects, [Effect::DrainInbox, Effect::AckAssignment { epoch: 2 }]);
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
fn a_machine_hands_an_idle_chat_back_to_a_standby_laptop() {
    let (chat, copy) = handing_back();
    // New prompts may still arrive, and end the handback; otherwise the copy is awaited.
    assert!(chat.may_run());
    let stored = Event::SnapshotStored { copy, snapshot: 4 };
    let (chat, effects) = step(chat, stored, chat.seen_at + 800);
    assert_eq!(chat.state, State::Releasing { epoch: 2 });
    assert_eq!(effects[0], Effect::Release { epoch: 2 });
    assert!(!chat.may_run());

    // No answer to the release: it is sent again.
    let (chat, effects) = step(chat, Event::Tick, chat.wake_at().expect("a next tick"));
    assert_eq!(effects[0], Effect::Release { epoch: 2 });

    let (chat, effects) = step(chat, Event::Released, chat.seen_at + 100);
    assert_eq!(chat.state, State::Away);
    assert_eq!(effects, [Effect::KillTree]);
    assert_eq!(chat.wake_at(), None);
    assert!(!chat.may_run() && !chat.here());
}

#[test]
fn a_chat_at_work_is_not_handed_back_until_its_turn_ends() {
    let started = Event::Changed { change: Change::TurnStarted, needs_run: true };
    let (chat, effects) = step(serving(0), started, 1_000);
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
    let due = Event::Answered { request: request(&effects), answer: handback_due() };
    let (chat, effects) = step(chat, due, 1_100);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, State::Serving { epoch: 2 });

    // The turn ends with nothing queued: copy, tell the store, and the answer starts the
    // handback.
    let ended = Event::Changed { change: Change::TurnEnded, needs_run: false };
    let (chat, effects) = step(chat, ended, 9_000);
    assert_eq!(kinds(&effects)[..3], ["upload_events", "upload_snapshot", "renew"]);
    let due = Event::Answered { request: request(&effects), answer: handback_due() };
    let (chat, effects) = step(chat, due, 9_100);
    assert!(matches!(chat.state, State::HandingBack { epoch: 2, .. }));
    assert_eq!(kinds(&effects), ["upload_events", "upload_snapshot"]);
}

#[test]
fn new_work_ends_a_handback() {
    let (chat, copy) = handing_back();
    let queued = Event::Changed { change: Change::QueueChanged, needs_run: true };
    let (chat, _) = step(chat, queued, chat.seen_at + 100);
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    // The copy that was on its way lands, and nothing is released.
    let stored = Event::SnapshotStored { copy, snapshot: 4 };
    let (chat, effects) = step(chat, stored, chat.seen_at + 100);
    assert!(!has(&effects, "release"));
    assert_eq!(chat.state, State::Serving { epoch: 2 });
}

#[test]
fn a_message_comes_before_a_handback() {
    let (chat, request, now) = next_renewal(serving(0));
    let both = Answer { inbox_pending: true, ..handback_due() };
    let (chat, effects) = step(chat, Event::Answered { request, answer: both }, now);
    assert_eq!(effects, [Effect::DrainInbox]);
    assert_eq!(chat.state, State::Serving { epoch: 2 });
}

#[test]
fn a_handback_stops_when_the_laptop_is_gone_or_the_chat_is_kept() {
    let (chat, _) = handing_back();
    let (chat, request, now) = next_renewal(chat);
    let kept = Event::Answered { request, answer: answer(Verdict::Holder, 2, 3) };
    let (chat, effects) = step(chat, kept, now + 50);
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    assert!(!has(&effects, "release"));
}

#[test]
fn a_chat_with_no_laptop_standing_by_stays_on_the_machine() {
    let (chat, request, now) = next_renewal(serving(0));
    let alone = Event::Answered { request, answer: answer(Verdict::Holder, 2, 3) };
    let (chat, effects) = step(chat, alone, now + 50);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, State::Serving { epoch: 2 });
}

/// A paused machine is not a lost one: with no answer for five minutes it still serves.
#[test]
fn a_machine_that_cannot_reach_the_cloud_keeps_the_chat() {
    let mut chat = serving(0);
    while chat.seen_at < 300_000 {
        let (next, request, now) = next_renewal(chat);
        let (next, effects) = step(next, Event::Unanswered { request }, now + 1);
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
    let (chat, effects) = Chat::resume(Side::Machine, 7, 1, 0);
    assert_eq!(chat.state, State::Serving { epoch: 7 });
    assert_eq!(kinds(&effects), ["renew", "schedule_at"]);
}

#[test]
fn a_machine_the_store_says_lost_the_chat_kills_it() {
    let (chat, request, now) = next_renewal(serving(0));
    let lost = Event::Answered { request, answer: answer(Verdict::Lost, 3, 3) };
    let (chat, effects) = step(chat, lost, now + 50);
    assert_eq!(chat.state, State::Away);
    assert_eq!(effects, [Effect::KillTree, Effect::WriteLeftoverPatch]);
    assert_eq!(chat.wake_at(), None);
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
