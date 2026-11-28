//! A move the store refused, asked again, from the design's "Move now" ("The holder's side").
//! The store's answer says when the person asked for the move: the same time is the wish that
//! was refused, another time is the person asking again. Each test runs on a laptop that
//! gives its chat to the Cloud and on a Cloud machine that gives it to a laptop.

use super::super::*;
use super::laptop::holding;
use super::machine::serving;
use super::{answer, request};

/// A laptop that holds the chat at epoch 1 and a machine that serves it at epoch 2, each with
/// where its give goes.
fn holders() -> [(Chat, MoveTo); 2] {
    [(holding(0), MoveTo::Cloud), (serving(0), MoveTo::Local)]
}

/// The chat's next renewal, answered "holder" with the wish to move the chat to `to`. `at` is
/// when the person asked, None from a store that does not say. Answers the chat, what the
/// answer made it do, and the time.
fn renewed(chat: Chat, to: MoveTo, at: Option<u64>) -> (Chat, Vec<Effect>, u64) {
    let now = chat.wake_at().expect("a next tick");
    let (chat, effects) = step(chat, Event::Tick, now);
    let held = match chat.side() {
        Side::Laptop => answer(Verdict::Holder, 1, 1),
        Side::Machine => answer(Verdict::Holder, 2, 4),
    };
    let answer = match at {
        Some(at) => held.wishing_since(to, at),
        None => held.wishing(Some(to)),
    };
    let answered = Event::Answered { request: request(&effects), answer };
    let (chat, effects) = step(chat, answered, now);
    (chat, effects, now)
}

/// A give whose turn was told to stop at `now`, as far as the store's refusal: the person is
/// told, and the chat goes on at its holder.
fn refused(chat: Chat, to: MoveTo, now: u64) -> Chat {
    let (chat, effects) = step(chat, Event::TurnStopped, now + 1);
    let copy = effects
        .iter()
        .find_map(|effect| match effect {
            Effect::UploadSnapshot { copy, .. } => Some(*copy),
            _ => None,
        })
        .expect("the give's copy");
    let (chat, effects) = step(chat, Event::SnapshotStored { copy, snapshot: 9 }, now + 2);
    assert!(matches!(effects.as_slice(), [Effect::Give { .. }]), "{effects:?}");
    let (chat, effects) = step(chat, Event::GiveFailed { why: GiveFailure::Refused }, now + 3);
    assert_eq!(effects, [Effect::NotMoved { to, why: Declined::Refused }, Effect::Stay]);
    assert!(chat.may_run());
    assert_eq!(chat.moving(), None);
    chat
}

#[test]
fn a_refused_move_asked_again_is_tried_again_and_the_same_ask_is_not() {
    for (chat, to) in holders() {
        let (chat, effects, now) = renewed(chat, to, Some(500));
        assert_eq!(effects, [Effect::StopTurn]);
        let chat = refused(chat, to, now);
        // The store still tells the wish the person asked at 500: it is not acted on, and
        // nothing is said again.
        let (chat, effects, _) = renewed(chat, to, Some(500));
        assert!(effects.is_empty(), "{effects:?}");
        assert_eq!(chat.moving(), None);
        // The person asks again, so the wish's time starts again: the give is tried.
        let (chat, effects, now) = renewed(chat, to, Some(900));
        assert_eq!(effects, [Effect::StopTurn]);
        assert_eq!(chat.moving(), Some(to));
        // Refused again, the person is told again, and this ask is not tried twice either.
        let chat = refused(chat, to, now);
        let (chat, effects, _) = renewed(chat, to, Some(900));
        assert!(effects.is_empty(), "{effects:?}");
        assert_eq!(chat.moving(), None);
    }
}

#[test]
fn a_store_that_does_not_say_when_keeps_a_refusal_while_it_tells_the_wish() {
    for (chat, to) in holders() {
        let (chat, effects, now) = renewed(chat, to, None);
        assert_eq!(effects, [Effect::StopTurn]);
        let chat = refused(chat, to, now);
        let (chat, effects, _) = renewed(chat, to, None);
        assert!(effects.is_empty(), "{effects:?}");
        let (chat, effects, _) = renewed(chat, to, None);
        assert!(effects.is_empty(), "{effects:?}");
        assert_eq!(chat.moving(), None);
    }
}

#[test]
fn a_wish_heard_without_its_time_is_the_same_wish_once_the_store_says_when() {
    for (chat, to) in holders() {
        let (chat, effects, now) = renewed(chat, to, None);
        assert_eq!(effects, [Effect::StopTurn]);
        let chat = refused(chat, to, now);
        // The first time the store names is this wish's, not a new ask.
        let (chat, effects, _) = renewed(chat, to, Some(500));
        assert!(effects.is_empty(), "{effects:?}");
        let (chat, effects, _) = renewed(chat, to, Some(500));
        assert!(effects.is_empty(), "{effects:?}");
        let (chat, effects, _) = renewed(chat, to, Some(900));
        assert_eq!(effects, [Effect::StopTurn]);
        assert_eq!(chat.moving(), Some(to));
    }
}

#[test]
fn a_move_asked_again_mid_give_is_the_one_a_refusal_counts_for() {
    for (chat, to) in holders() {
        let (chat, effects, _) = renewed(chat, to, Some(500));
        assert_eq!(effects, [Effect::StopTurn]);
        // The person asks again while the turn stops: the give goes on, for the newer ask.
        let (chat, effects, now) = renewed(chat, to, Some(900));
        assert!(effects.is_empty(), "{effects:?}");
        assert_eq!(chat.moving(), Some(to));
        let chat = refused(chat, to, now);
        let (chat, effects, _) = renewed(chat, to, Some(900));
        assert!(effects.is_empty(), "{effects:?}");
        assert_eq!(chat.moving(), None);
    }
}

#[test]
fn a_move_asked_from_this_daemon_is_the_same_ask_when_a_renewal_tells_it() {
    for (chat, to) in holders() {
        let (chat, effects) = step(chat, Event::Wished { to, at: Some(500) }, 100);
        assert_eq!(effects, [Effect::StopTurn]);
        let chat = refused(chat, to, 100);
        let (chat, effects, now) = renewed(chat, to, Some(500));
        assert!(effects.is_empty(), "{effects:?}");
        // Asked from this daemon again, it is tried again whatever was refused.
        let (chat, effects) = step(chat, Event::Wished { to, at: Some(900) }, now + 1);
        assert_eq!(effects, [Effect::StopTurn]);
        assert_eq!(chat.moving(), Some(to));
    }
}
