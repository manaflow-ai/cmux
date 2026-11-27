//! A Cloud machine gives its chat to a laptop, from the design's "Move now" ("The holder's
//! side").

use super::super::*;
use super::machine::serving;
use super::{acts, answer, request};
use crate::wire::AssignmentKind;

const LOCAL: MoveTo = MoveTo::Local;
const SERVING: State = State::Serving { epoch: 2 };

fn returning(step: GiveStep) -> State {
    State::Returning { epoch: 2, step, to: LOCAL }
}

fn give_failed(why: GiveFailure) -> Event {
    Event::GiveFailed { why }
}

/// The store's "holder" at epoch 2 to the renewal among `effects`, with the person's wish.
pub(super) fn held(effects: &[Effect], wish: Option<MoveTo>) -> Event {
    let answer = answer(Verdict::Holder, 2, 4).wishing(wish);
    Event::Answered { request: request(effects), answer }
}

/// The store's "lost" to the renewal among `effects`: the chat is a laptop's, at epoch 3.
fn lost(effects: &[Effect]) -> Event {
    Event::Answered { request: request(effects), answer: answer(Verdict::Lost, 3, 5) }
}

/// The chat's next tick: (the chat, its effects, when).
pub(super) fn tick(chat: Chat) -> (Chat, Vec<Effect>, u64) {
    let now = chat.wake_at().expect("a next tick");
    let (chat, effects) = step(chat, Event::Tick, now);
    (chat, effects, now)
}

/// A machine that serves the chat at epoch 2 and whose renewal was answered with the wish to
/// move it to a laptop: its give as far as `until`. Answers the chat and the time.
pub(super) fn give_until(until: GiveStep) -> (Chat, u64) {
    let (chat, effects, now) = tick(serving(0));
    let (chat, effects) = step(chat, held(&effects, Some(LOCAL)), now);
    assert_eq!(effects, [Effect::StopTurn]);
    assert_eq!(chat.state, returning(GiveStep::Stopping));
    if until == GiveStep::Stopping {
        return (chat, now);
    }
    let (chat, effects) = step(chat, Event::TurnStopped, now + 1);
    let copy = [Effect::UploadEvents { epoch: 2 }, Effect::UploadSnapshot { epoch: 2, copy: 2 }];
    assert_eq!(effects, copy);
    assert_eq!(chat.state, returning(GiveStep::Copying));
    if until == GiveStep::Copying {
        return (chat, now + 1);
    }
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: 2, snapshot: 5 }, now + 2);
    assert_eq!(effects, [Effect::Give { epoch: 2 }]);
    assert_eq!(chat.state, returning(GiveStep::Asking));
    (chat, now + 2)
}

#[test]
fn a_wish_stops_the_turn_copies_then_gives_and_the_machine_has_lost_the_chat() {
    // Each step of the give is checked in `give_until`.
    let (chat, _) = give_until(GiveStep::Stopping);
    assert!(chat.here() && !chat.may_run());
    assert_eq!(chat.moving(), Some(LOCAL));

    let (chat, now) = give_until(GiveStep::Asking);
    // The store has everything this machine did: nothing is kept beside the chat.
    let (chat, effects) = step(chat, Event::Gave { epoch: 3 }, now + 1);
    assert_eq!(effects, [Effect::KillTree]);
    assert_eq!(chat.state, State::Away);
    assert!(!chat.here() && !chat.may_run());
    assert_eq!(chat.wake_at(), None);
}

#[test]
fn a_wish_comes_before_the_inbox() {
    let (chat, effects, now) = tick(serving(0));
    let wish = answer(Verdict::Holder, 2, 4).wishing(Some(LOCAL));
    let both = Answer { inbox_pending: true, ..wish };
    let wished = Event::Answered { request: request(&effects), answer: both };
    // Whoever gets the chat takes its messages.
    let (chat, effects) = step(chat, wished, now);
    assert_eq!(effects, [Effect::StopTurn]);
    assert_eq!(chat.state, returning(GiveStep::Stopping));
}

#[test]
fn the_daemons_own_move_starts_the_give_without_waiting_for_a_renewal() {
    let (chat, effects) = step(serving(0), Event::Wished { to: LOCAL, at: None }, 100);
    assert_eq!(effects, [Effect::StopTurn]);
    assert_eq!(chat.state, returning(GiveStep::Stopping));
}

#[test]
fn a_give_ahead_of_the_copy_is_copied_and_asked_again() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::NotCopied), now + 1);
    assert_eq!(chat.state, returning(GiveStep::Copying));
    let copy = [Effect::UploadEvents { epoch: 2 }, Effect::UploadSnapshot { epoch: 2, copy: 3 }];
    assert_eq!(effects, copy);
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: 3, snapshot: 6 }, now + 2);
    assert_eq!(effects, [Effect::Give { epoch: 2 }]);
    assert_eq!(chat.state, returning(GiveStep::Asking));
}

#[test]
fn a_move_taken_back_leaves_the_chat_running_here() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::NoMove), now + 1);
    assert_eq!(effects, [Effect::Stay]);
    assert_eq!(chat.state, SERVING);
    assert!(chat.may_run() && chat.moving().is_none());
}

#[test]
fn a_give_the_store_refused_is_told_once_and_not_tried_again_for_the_same_wish() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::Refused), now + 1);
    let told = Effect::NotMoved { to: LOCAL, why: Declined::Refused };
    assert_eq!(effects, [told, Effect::Stay]);
    assert_eq!(chat.state, SERVING);
    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, Some(LOCAL)), now);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, SERVING);
}

#[test]
fn a_give_that_lost_the_fence_asks_the_store_whose_the_chat_is() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::Lost), now + 1);
    assert_eq!(chat.state, returning(GiveStep::Copying));
    assert_eq!(acts(&effects), ["renew"]);
    // The chat is another holder's: what ran here is killed, and what it wrote is kept.
    let (chat, effects) = step(chat, lost(&effects), now + 2);
    assert_eq!(effects, [Effect::KillTree, Effect::WriteLeftoverPatch]);
    assert_eq!(chat.state, State::Away);
}

#[test]
fn a_give_the_store_did_not_answer_is_asked_again_at_the_next_tick() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::Unanswered), now + 1);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, returning(GiveStep::Copying));
    let (chat, effects, now) = tick(chat);
    assert_eq!(acts(&effects), ["give", "renew"]);
    assert!(effects.contains(&Effect::Give { epoch: 2 }), "{effects:?}");
    assert_eq!(chat.state, returning(GiveStep::Asking));
    let (chat, effects) = step(chat, Event::Gave { epoch: 3 }, now + 1);
    assert_eq!(effects, [Effect::KillTree]);
    assert_eq!(chat.state, State::Away);
}

#[test]
fn a_turn_that_does_not_stop_keeps_the_chat_here() {
    let (chat, now) = give_until(GiveStep::Stopping);
    let (chat, effects) = step(chat, give_failed(GiveFailure::Stuck), now + 1);
    let told = Effect::NotMoved { to: LOCAL, why: Declined::Stuck };
    assert_eq!(effects, [told, Effect::Stay]);
    assert_eq!(chat.state, SERVING);
}

#[test]
fn a_wish_that_disappears_mid_give_leaves_the_chat_running_here() {
    for until in [GiveStep::Stopping, GiveStep::Copying, GiveStep::Asking] {
        let (chat, _) = give_until(until);
        let (chat, effects, now) = tick(chat);
        assert_eq!(acts(&effects), ["renew"], "{until:?}");
        assert_eq!(chat.state, returning(until));
        let (chat, effects) = step(chat, held(&effects, None), now);
        assert_eq!(effects, [Effect::Stay], "{until:?}");
        assert_eq!(chat.state, SERVING);
        assert!(chat.may_run());
        // What the give still had on its way starts no give.
        for event in [Event::TurnStopped, give_failed(GiveFailure::NoMove)] {
            let (after, effects) = step(chat, event, now + 1);
            assert_eq!(after.state, SERVING, "{until:?} {event:?}");
            assert!(effects.is_empty(), "{until:?} {event:?}: {effects:?}");
        }
    }
}

#[test]
fn a_chat_too_large_to_copy_is_not_given_and_says_so_once() {
    let ended = Event::Changed { change: Change::TurnEnded, needs_run: false };
    let (chat, _) = step(serving(0), ended, 100);
    let (chat, _) = step(chat, Event::SnapshotFailed { copy: 2, too_large: true }, 200);
    assert!(chat.too_large);

    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, Some(LOCAL)), now);
    assert_eq!(effects, [Effect::NotMoved { to: LOCAL, why: Declined::TooLarge }]);
    assert_eq!(chat.state, SERVING);
    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, Some(LOCAL)), now);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, SERVING);
}

#[test]
fn a_copy_past_the_cap_ends_the_give() {
    let (chat, now) = give_until(GiveStep::Copying);
    let (chat, effects) = step(chat, Event::SnapshotFailed { copy: 2, too_large: true }, now + 1);
    let told = Effect::NotMoved { to: LOCAL, why: Declined::TooLarge };
    assert_eq!(effects, [told, Effect::Stay]);
    assert_eq!(chat.state, SERVING);
}

#[test]
fn a_newer_assignment_mid_give_starts_over_from_the_cloud_copy() {
    let (chat, now) = give_until(GiveStep::Asking);
    // One at this epoch waits in the store for whoever holds the chat next.
    let same = Event::Assigned { kind: AssignmentKind::Deliver, epoch: 2 };
    let (chat, effects) = step(chat, same, now + 1);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, returning(GiveStep::Asking));

    let newer = Event::Assigned { kind: AssignmentKind::Takeover, epoch: 4 };
    let (chat, effects) = step(chat, newer, now + 2);
    assert_eq!(acts(&effects), ["kill_tree", "write_leftover_patch", "import"]);
    let taking = State::Taking { epoch: 4, reason: ImportReason::Takeover, failed: false };
    assert_eq!(chat.state, taking);
}

#[test]
fn a_wake_mid_give_only_renews() {
    let (chat, now) = give_until(GiveStep::Copying);
    let (chat, effects) = step(chat, Event::Wake, now + 1);
    assert_eq!(acts(&effects), ["renew"]);
    assert_eq!(chat.state, returning(GiveStep::Copying));
    // A machine with a copy on its way is at work: the store does not hand the chat back
    // before the give.
    let at_work = matches!(effects.first(), Some(Effect::Renew { needs_run: true, .. }));
    assert!(at_work, "{effects:?}");
}
