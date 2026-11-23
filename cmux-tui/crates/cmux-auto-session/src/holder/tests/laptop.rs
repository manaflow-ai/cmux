//! A laptop's journeys, from the design's "Lease", "Laptop wake", "A laptop that cannot reach
//! the Cloud stops by itself" and "Handback".

use super::super::*;
use super::{answer, has, kinds, request};
use crate::consts::{LEASE_MS, RENEW_MS, SELF_STOP_MS, STREAM_COPY_MS};
use crate::wire::Blocked;

/// A laptop that switched Auto on at `now`, holds the chat at epoch 1 and stored snapshot 1.
fn holding(now: u64) -> Chat {
    let (chat, effects) = step(Chat::new(Side::Laptop, now), Event::AutoOn, now);
    let registered =
        Event::Answered { request: request(&effects), answer: answer(Verdict::Holder, 1, 0) };
    let (chat, effects) = step(chat, registered, now);
    assert_eq!(kinds(&effects), ["upload_events", "upload_snapshot"]);
    let (chat, _) = step(chat, Event::SnapshotStored { copy: 1, snapshot: 1 }, now);
    assert_eq!(chat.state, State::Holding { epoch: 1 });
    chat
}

/// The holder with no network: ticks go by unanswered until the laptop stops the chat.
/// Answers the stopped chat and when it stopped.
fn stopped_offline(start: u64) -> (Chat, u64) {
    let mut chat = holding(start);
    loop {
        let now = chat.wake_at().expect("a holder always has a next tick");
        let (next, effects) = step(chat, Event::Tick, now);
        chat = next;
        if matches!(chat.state, State::Stopped { .. }) {
            assert_eq!(effects.first(), Some(&Effect::StopTree));
            assert!(effects.contains(&Effect::ShowBlocked { blocked: Some(Blocked::Offline) }));
            return (chat, now);
        }
        let unanswered = Event::Unanswered { request: request(&effects) };
        chat = step(chat, unanswered, now + 1).0;
    }
}

/// The next renewal of a chat whose tick is due: (the chat, the request, when it was sent).
fn next_renewal(chat: Chat) -> (Chat, u64, u64) {
    let now = chat.wake_at().expect("a next tick");
    let (chat, effects) = step(chat, Event::Tick, now);
    (chat, request(&effects), now)
}

#[test]
fn auto_on_registers_and_the_first_copy_goes_at_once() {
    let (chat, effects) = step(Chat::new(Side::Laptop, 0), Event::AutoOn, 100);
    assert_eq!(chat.state, State::Registering);
    assert_eq!(kinds(&effects), ["register", "schedule_at"]);
    // Until the store answers, the chat runs as any chat does and is not held here.
    assert!(chat.may_run() && !chat.here());
    let registered =
        Event::Answered { request: request(&effects), answer: answer(Verdict::Holder, 1, 0) };
    let (chat, effects) = step(chat, registered, 200);
    assert_eq!(chat.state, State::Holding { epoch: 1 });
    assert_eq!(
        effects,
        [Effect::UploadEvents { epoch: 1 }, Effect::UploadSnapshot { epoch: 1, copy: 1 }]
    );
    assert!(chat.may_run() && chat.here());
}

#[test]
fn a_registration_with_no_answer_is_sent_again() {
    let (chat, effects) = step(Chat::new(Side::Laptop, 0), Event::AutoOn, 0);
    let (chat, _) = step(chat, Event::Unanswered { request: request(&effects) }, 500);
    let (chat, effects) = step(chat, Event::Tick, RENEW_MS);
    assert_eq!(chat.state, State::Registering);
    assert_eq!(kinds(&effects), ["register", "schedule_at"]);
}

#[test]
fn the_holder_renews_every_ten_seconds() {
    let mut chat = holding(0);
    for round in 1..=6 {
        let (next, request, now) = next_renewal(chat);
        assert_eq!(now, round * RENEW_MS);
        let answered = Event::Answered { request, answer: answer(Verdict::Holder, 1, 1) };
        let (next, effects) = step(next, answered, now + 50);
        assert!(effects.is_empty(), "{effects:?}");
        assert_eq!(next.state, State::Holding { epoch: 1 });
        chat = next;
    }
}

#[test]
fn a_renewal_says_the_holder_and_its_work() {
    let chat = holding(0);
    let (_, effects) = step(chat, Event::Tick, RENEW_MS);
    assert_eq!(
        effects.first(),
        Some(&Effect::Renew { request: 2, epoch: 1, needs_run: false, standby: false })
    );
}

#[test]
fn a_laptop_that_cannot_reach_the_cloud_stops_by_itself() {
    let (chat, stopped_at) = stopped_offline(0);
    // 35 s after the last answered renewal was sent, which is before the lease runs out.
    assert_eq!(stopped_at, SELF_STOP_MS);
    assert!(stopped_at < LEASE_MS);
    assert_eq!(chat.state, State::Stopped { epoch: 1, why: Stop::Offline });
    assert_eq!(chat.blocked(), Some(Blocked::Offline));
    assert!(!chat.may_run() && chat.here());
    // It keeps asking.
    let (_, effects) = step(chat, Event::Tick, chat.wake_at().expect("a next tick"));
    assert!(has(&effects, "renew"));
}

#[test]
fn a_stopped_chat_the_laptop_still_holds_is_continued() {
    let (chat, _) = stopped_offline(0);
    let (chat, request, now) = next_renewal(chat);
    let still = Event::Answered { request, answer: answer(Verdict::Holder, 1, 1) };
    let (chat, effects) = step(chat, still, now + 100);
    assert_eq!(chat.state, State::Holding { epoch: 1 });
    assert_eq!(effects.first(), Some(&Effect::ContinueTree));
    assert!(effects.contains(&Effect::ShowBlocked { blocked: None }));
    assert!(!has(&effects, "kill_tree"));
    assert!(chat.may_run());
}

#[test]
fn a_parked_chat_is_held_again_at_the_stores_new_epoch() {
    let (chat, _) = stopped_offline(0);
    let (chat, request, now) = next_renewal(chat);
    // The lease ran out idle: parked at epoch 2, and this renewal makes the laptop holder at 3.
    let again = Event::Answered { request, answer: answer(Verdict::Holder, 3, 1) };
    let (chat, effects) = step(chat, again, now + 100);
    assert_eq!(chat.state, State::Holding { epoch: 3 });
    assert_eq!(effects.first(), Some(&Effect::ContinueTree));
    // Writes go out under the new epoch.
    let ended = Event::Changed { change: Change::TurnEnded, needs_run: false };
    let (_, effects) = step(chat, ended, now + 200);
    assert_eq!(effects.first(), Some(&Effect::UploadEvents { epoch: 3 }));
}

#[test]
fn a_stopped_chat_a_machine_took_is_killed_and_kept_as_a_leftover_patch() {
    let (chat, _) = stopped_offline(0);
    let (chat, request, now) = next_renewal(chat);
    let taken = Event::Answered { request, answer: answer(Verdict::Lost, 2, 1) };
    let (chat, effects) = step(chat, taken, now + 100);
    assert_eq!(chat.state, State::Standby { epoch: 2 });
    assert_eq!(kinds(&effects)[..3], ["kill_tree", "write_leftover_patch", "renew"]);
    assert!(matches!(effects[2], Effect::Renew { standby: true, needs_run: false, epoch: 2, .. }));
    assert!(!has(&effects, "continue_tree"));
    assert!(!chat.may_run() && !chat.here());
    assert_eq!(chat.blocked(), None);
}

#[test]
fn a_chat_another_holder_ran_while_the_laptop_was_gone_comes_home_from_the_cloud() {
    let (chat, _) = stopped_offline(0);
    let (chat, request, now) = next_renewal(chat);
    // Holder again, but the store has a snapshot this laptop did not write: a machine ran the
    // chat and released it in between.
    let newer = Event::Answered { request, answer: answer(Verdict::Holder, 5, 2) };
    let (chat, effects) = step(chat, newer, now + 100);
    assert_eq!(chat.state, State::ComingHome { epoch: 5, failed: false });
    assert_eq!(
        effects[..3],
        [
            Effect::KillTree,
            Effect::WriteLeftoverPatch,
            Effect::Import { reason: ImportReason::Handback, epoch: 5 }
        ]
    );
    assert!(!chat.may_run());
}

#[test]
fn a_wake_stops_the_chat_before_it_asks() {
    let chat = holding(0);
    let (chat, effects) = step(chat, Event::Wake, 3_000);
    assert_eq!(chat.state, State::Stopped { epoch: 1, why: Stop::Wake });
    assert_eq!(kinds(&effects)[..2], ["stop_tree", "renew"]);
    assert!(!chat.may_run());
    // Still the holder at the same epoch: continue.
    let still =
        Event::Answered { request: request(&effects), answer: answer(Verdict::Holder, 1, 1) };
    let (held, effects) = step(chat, still, 3_200);
    assert_eq!(held.state, State::Holding { epoch: 1 });
    assert_eq!(kinds(&effects), ["continue_tree"]);
    // Taken by a machine: kill, leftover patch, standby.
    let taken = Event::Answered { request: chat.requests, answer: answer(Verdict::Lost, 2, 2) };
    let (lost, effects) = step(chat, taken, 3_200);
    assert_eq!(lost.state, State::Standby { epoch: 2 });
    assert_eq!(kinds(&effects)[..3], ["kill_tree", "write_leftover_patch", "renew"]);
}

#[test]
fn a_wake_with_no_answer_waits_for_the_network() {
    let (chat, effects) = step(holding(0), Event::Wake, 3_000);
    let (chat, effects) = step(chat, Event::Unanswered { request: request(&effects) }, 4_000);
    assert_eq!(chat.state, State::Stopped { epoch: 1, why: Stop::Offline });
    assert_eq!(effects, [Effect::ShowBlocked { blocked: Some(Blocked::Offline) }]);
}

#[test]
fn a_clock_jump_is_a_wake_whatever_the_event() {
    let chat = holding(0);
    let changed = Event::Changed { change: Change::Streaming, needs_run: true };
    for now in [1_000 + LEASE_MS + 1, 1_000 + 86_400_000] {
        let (seen, _) = step(chat, Event::Tick, 1_000);
        let (after, effects) = step(seen, changed, now);
        assert_eq!(after.state, State::Stopped { epoch: 1, why: Stop::Wake });
        assert_eq!(kinds(&effects)[..2], ["stop_tree", "renew"]);
    }
    // A clock that went back is not trusted either; one being set right by under a second is.
    let (seen, _) = step(chat, Event::Tick, 5_000);
    let (after, effects) = step(seen, changed, 5_000 - CLOCK_SLACK_MS - 1);
    assert_eq!(after.state, State::Stopped { epoch: 1, why: Stop::Wake });
    assert_eq!(effects.first(), Some(&Effect::StopTree));
    let (after, effects) = step(seen, changed, 5_000 - CLOCK_SLACK_MS);
    assert_eq!(after.state, State::Holding { epoch: 1 });
    assert!(!has(&effects, "stop_tree"));
}

#[test]
fn only_the_newest_request_is_answered() {
    let (chat, first) = step(holding(0), Event::Tick, RENEW_MS);
    let (chat, second) = step(chat, Event::Wake, RENEW_MS + 500);
    assert!(request(&second) > request(&first));
    let old = Event::Answered { request: request(&first), answer: answer(Verdict::Holder, 1, 1) };
    let (chat, effects) = step(chat, old, RENEW_MS + 600);
    assert_eq!(chat.state, State::Stopped { epoch: 1, why: Stop::Wake });
    assert!(effects.is_empty(), "{effects:?}");
    let new = Event::Answered { request: request(&second), answer: answer(Verdict::Holder, 1, 1) };
    let (chat, effects) = step(chat, new, RENEW_MS + 700);
    assert_eq!(chat.state, State::Holding { epoch: 1 });
    assert_eq!(effects.first(), Some(&Effect::ContinueTree));
}

#[test]
fn an_answer_older_than_the_self_stop_does_not_continue_the_chat() {
    let (chat, effects) = step(holding(0), Event::Wake, 3_000);
    let late =
        Event::Answered { request: request(&effects), answer: answer(Verdict::Holder, 1, 1) };
    let (chat, effects) = step(chat, late, 3_000 + SELF_STOP_MS);
    assert!(matches!(chat.state, State::Stopped { .. }));
    assert!(!has(&effects, "continue_tree"));
    assert!(has(&effects, "renew"));
}

#[test]
fn a_standby_laptop_imports_the_handback_then_holds() {
    let (chat, effects) = Chat::standby(4, 0);
    assert_eq!(
        effects.first(),
        Some(&Effect::Renew { request: 1, epoch: 4, needs_run: false, standby: true })
    );
    let listed = Event::Answered { request: 1, answer: answer(Verdict::Standby, 4, 7) };
    let (chat, effects) = step(chat, listed, 100);
    assert_eq!((chat.state, effects.len()), (State::Standby { epoch: 4 }, 0));
    assert!(!chat.may_run() && !chat.here());

    // The machine's turn ended and the store moved the lease here.
    let (chat, request, now) = next_renewal(chat);
    let granted = Event::Answered { request, answer: answer(Verdict::Holder, 5, 8) };
    let (chat, effects) = step(chat, granted, now + 100);
    assert_eq!(chat.state, State::ComingHome { epoch: 5, failed: false });
    assert_eq!(effects, [Effect::Import { reason: ImportReason::Handback, epoch: 5 }]);
    assert!(!chat.may_run() && chat.here());

    // The laptop is the holder while it imports, so it renews as one.
    let (chat, effects) = step(chat, Event::Tick, chat.wake_at().expect("a next tick"));
    assert!(matches!(effects[0], Effect::Renew { epoch: 5, standby: false, .. }));

    // A failed import is tried again at the next tick.
    let (chat, effects) = step(chat, Event::ImportFailed { epoch: 5 }, chat.seen_at + 10);
    assert_eq!((chat.state, effects.len()), (State::ComingHome { epoch: 5, failed: true }, 0));
    let (chat, effects) = step(chat, Event::Tick, chat.wake_at().expect("a next tick"));
    assert_eq!(effects[0], Effect::Import { reason: ImportReason::Handback, epoch: 5 });

    let done = Event::ImportDone { epoch: 5, snapshot: 8 };
    let (chat, effects) = step(chat, done, chat.seen_at + 10);
    assert_eq!(chat.state, State::Holding { epoch: 5 });
    assert_eq!(chat.snapshot, 8);
    assert!(has(&effects, "renew"));
    assert!(chat.may_run());
}

#[test]
fn an_import_of_another_epoch_does_not_start_the_chat() {
    let (chat, _) = Chat::standby(4, 0);
    let granted = Event::Answered { request: 1, answer: answer(Verdict::Holder, 5, 8) };
    let (chat, _) = step(chat, granted, 100);
    let (chat, effects) = step(chat, Event::ImportDone { epoch: 3, snapshot: 2 }, 200);
    assert_eq!((chat.state, effects.len()), (State::ComingHome { epoch: 5, failed: false }, 0));
}

#[test]
fn auto_off_takes_effect_when_the_store_confirms_it() {
    let chat = holding(0);
    let (chat, effects) = step(chat, Event::AutoOff, 1_000);
    assert_eq!(effects, [Effect::Close]);
    assert_eq!(chat.state, State::Holding { epoch: 1 });
    let (chat, effects) = step(chat, Event::Closed, 1_200);
    assert_eq!((chat.state, effects.len()), (State::Off, 0));
    assert_eq!(chat.wake_at(), None);
    assert!(chat.may_run() && !chat.here());

    // A stopped chat is not continued on the switch alone: a machine may have taken it.
    let (chat, _) = stopped_offline(0);
    let (chat, effects) = step(chat, Event::AutoOff, chat.seen_at + 10);
    assert_eq!(effects, [Effect::Close]);
    assert!(!chat.may_run());
    let (chat, effects) = step(chat, Event::Closed, chat.seen_at + 10);
    assert_eq!(chat.state, State::Off);
    assert_eq!(effects, [Effect::ContinueTree, Effect::ShowBlocked { blocked: None }]);
}

#[test]
fn work_is_told_to_the_store_only_with_a_copy_to_take_over_from() {
    let (chat, effects) = step(Chat::new(Side::Laptop, 0), Event::AutoOn, 0);
    let registered =
        Event::Answered { request: request(&effects), answer: answer(Verdict::Holder, 1, 0) };
    let (chat, _) = step(chat, registered, 100);
    // A turn runs, but the store has no snapshot yet: a lapsed lease must park, not take over.
    let started = Event::Changed { change: Change::TurnStarted, needs_run: true };
    let (chat, effects) = step(chat, started, 200);
    assert!(effects.is_empty(), "{effects:?}");
    assert!(!chat.reports_needs_run());
    // The first snapshot is stored: the store is told at once.
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: 1, snapshot: 1 }, 300);
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
    // Past the cap there is no copy to go on from: the chat stays local.
    let (chat, effects) = step(chat, Event::SnapshotFailed { copy: 2, too_large: true }, 400);
    assert!(matches!(effects[0], Effect::Renew { needs_run: false, .. }));
    assert!(effects.contains(&Effect::ShowBlocked { blocked: Some(Blocked::TooLarge) }));
    assert_eq!(chat.blocked(), Some(Blocked::TooLarge));
}

#[test]
fn a_turn_end_copies_and_tells_the_store_at_once() {
    let chat = holding(0);
    let started = Event::Changed { change: Change::TurnStarted, needs_run: true };
    let (chat, effects) = step(chat, started, 1_000);
    assert_eq!(kinds(&effects)[..1], ["renew"]);
    assert!(matches!(effects[0], Effect::Renew { needs_run: true, .. }));
    let ended = Event::Changed { change: Change::TurnEnded, needs_run: false };
    let (_, effects) = step(chat, ended, 2_000);
    assert_eq!(kinds(&effects)[..3], ["upload_events", "upload_snapshot", "renew"]);
    assert!(matches!(effects[2], Effect::Renew { needs_run: false, .. }));
}

#[test]
fn a_streaming_turn_is_copied_at_most_every_five_seconds() {
    let mut chat = holding(0);
    let streaming = Event::Changed { change: Change::Streaming, needs_run: true };
    let mut copies = Vec::new();
    for now in (500..=3 * STREAM_COPY_MS).step_by(500) {
        let (next, effects) = step(chat, streaming, now);
        if has(&effects, "upload_snapshot") {
            copies.push(now);
        }
        chat = next;
    }
    assert_eq!(copies, [STREAM_COPY_MS, 2 * STREAM_COPY_MS, 3 * STREAM_COPY_MS]);
}

#[test]
fn the_holder_drains_the_inbox_on_its_renewal() {
    let (chat, request, now) = next_renewal(holding(0));
    let pending = Answer { inbox_pending: true, ..answer(Verdict::Holder, 1, 1) };
    let (_, effects) = step(chat, Event::Answered { request, answer: pending }, now + 50);
    assert_eq!(effects, [Effect::DrainInbox]);
}

#[test]
fn a_daemon_that_restarts_treats_its_chats_as_a_wake() {
    let (chat, effects) = Chat::resume(Side::Laptop, 6, 2, 0);
    assert_eq!(chat.state, State::Stopped { epoch: 6, why: Stop::Wake });
    assert_eq!(kinds(&effects)[..2], ["stop_tree", "renew"]);
}
