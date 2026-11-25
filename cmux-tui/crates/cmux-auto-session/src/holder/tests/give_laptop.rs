//! A laptop gives its chat to the Cloud, from the design's "Move now" ("The holder's side").

use super::super::*;
use super::laptop::holding;
use super::{acts, answer, has, request};
use crate::cloud::AutoCloudError;
use crate::consts::SELF_STOP_MS;
use crate::wire::{Blocked, ErrorCode};

const CLOUD: MoveTo = MoveTo::Cloud;
const HOLDING: State = State::Holding { epoch: 1 };

fn giving(step: GiveStep) -> State {
    State::Giving { epoch: 1, step, to: CLOUD }
}

fn give_failed(why: GiveFailure) -> Event {
    Event::GiveFailed { why }
}

/// The store's "holder" at epoch 1 to the renewal among `effects`, with the person's wish.
pub(super) fn held(effects: &[Effect], wish: Option<MoveTo>) -> Event {
    let answer = answer(Verdict::Holder, 1, 1).wishing(wish);
    Event::Answered { request: request(effects), answer }
}

/// The store's word to the renewal among `effects` that the chat is another holder's, at
/// epoch 2.
fn taken(effects: &[Effect], verdict: Verdict) -> Event {
    Event::Answered { request: request(effects), answer: answer(verdict, 2, 2) }
}

/// A renewal numbered `request`, for `held` and `taken`.
fn renewal(request: u64) -> [Effect; 1] {
    [Effect::Renew { request, epoch: 1, needs_run: false, standby: false }]
}

/// The chat's next tick: (the chat, its effects, when).
pub(super) fn tick(chat: Chat) -> (Chat, Vec<Effect>, u64) {
    let now = chat.wake_at().expect("a next tick");
    let (chat, effects) = step(chat, Event::Tick, now);
    (chat, effects, now)
}

/// A laptop that holds the chat at epoch 1 and whose renewal was answered with the wish to
/// move it to the Cloud: its give as far as `until`. Answers the chat and the time.
pub(super) fn give_until(until: GiveStep) -> (Chat, u64) {
    let (chat, effects, now) = tick(holding(0));
    let (chat, effects) = step(chat, held(&effects, Some(CLOUD)), now);
    assert_eq!(effects, [Effect::StopTurn]);
    assert_eq!(chat.state, giving(GiveStep::Stopping));
    if until == GiveStep::Stopping {
        return (chat, now);
    }
    let (chat, effects) = step(chat, Event::TurnStopped, now + 1);
    let copy = [Effect::UploadEvents { epoch: 1 }, Effect::UploadSnapshot { epoch: 1, copy: 2 }];
    assert_eq!(effects, copy);
    assert_eq!(chat.state, giving(GiveStep::Copying));
    if until == GiveStep::Copying {
        return (chat, now + 1);
    }
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: 2, snapshot: 2 }, now + 2);
    assert_eq!(effects, [Effect::Give { epoch: 1 }]);
    assert_eq!(chat.state, giving(GiveStep::Asking));
    (chat, now + 2)
}

#[test]
fn a_wish_stops_the_turn_copies_then_gives_and_the_laptop_stands_by() {
    // Each step of the give is checked in `give_until`.
    let (chat, now) = give_until(GiveStep::Stopping);
    // Nothing of the chat starts here while it is given, and the row says where it goes.
    assert!(chat.here() && !chat.may_run());
    assert_eq!(chat.moving(), Some(CLOUD));
    // The stopped turn's end is not a reason to copy: the give's own copy follows the stop.
    let ended = Event::Changed { change: Change::TurnEnded, needs_run: true };
    let (_, effects) = step(chat, ended, now + 1);
    assert!(effects.is_empty(), "{effects:?}");

    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, Event::Gave { epoch: 2 }, now + 1);
    assert_eq!(chat.state, State::Standby { epoch: 2 });
    assert_eq!(acts(&effects), ["kill_tree", "write_leftover_patch", "renew"]);
    let standby = Effect::Renew { request: 3, epoch: 2, needs_run: false, standby: true };
    assert!(effects.contains(&standby), "{effects:?}");
    assert!(!chat.here() && !chat.may_run());
    assert_eq!(chat.moving(), None);
}

#[test]
fn the_daemons_own_move_starts_the_give_without_waiting_for_a_renewal() {
    let (chat, effects) = step(holding(0), Event::Wished { to: CLOUD, at: None }, 100);
    assert_eq!(effects, [Effect::StopTurn]);
    assert_eq!(chat.state, giving(GiveStep::Stopping));
    // A second word of the same wish changes nothing.
    let (chat, effects) = step(chat, Event::Wished { to: CLOUD, at: None }, 200);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, giving(GiveStep::Stopping));
}

#[test]
fn a_give_ahead_of_the_copy_is_copied_and_asked_again() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::NotCopied), now + 1);
    assert_eq!(chat.state, giving(GiveStep::Copying));
    let copy = [Effect::UploadEvents { epoch: 1 }, Effect::UploadSnapshot { epoch: 1, copy: 3 }];
    assert_eq!(effects, copy);
    // An older copy that lands is not the one this give waits for.
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: 2, snapshot: 2 }, now + 2);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, giving(GiveStep::Copying));
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: 3, snapshot: 3 }, now + 3);
    assert_eq!(effects, [Effect::Give { epoch: 1 }]);
    assert_eq!(chat.state, giving(GiveStep::Asking));
}

#[test]
fn a_copy_that_failed_is_sent_again_before_the_give() {
    let (chat, now) = give_until(GiveStep::Copying);
    let failed = Event::SnapshotFailed { copy: 2, too_large: false };
    let (chat, effects) = step(chat, failed, now + 1);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, giving(GiveStep::Copying));
    let (chat, effects, now) = tick(chat);
    assert_eq!(acts(&effects), ["upload_events", "upload_snapshot", "renew"]);
    let (chat, effects) = step(chat, Event::SnapshotStored { copy: 3, snapshot: 2 }, now + 1);
    assert_eq!(effects, [Effect::Give { epoch: 1 }]);
    assert_eq!(chat.state, giving(GiveStep::Asking));
}

#[test]
fn a_move_taken_back_leaves_the_chat_running_here() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::NoMove), now + 1);
    assert_eq!(effects, [Effect::Stay]);
    assert_eq!(chat.state, HOLDING);
    assert!(chat.may_run() && chat.moving().is_none());
    // The next wish is a new one.
    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, Some(CLOUD)), now);
    assert_eq!(effects, [Effect::StopTurn]);
    assert_eq!(chat.state, giving(GiveStep::Stopping));
}

#[test]
fn a_give_the_store_refused_is_told_once_and_not_tried_again_for_the_same_wish() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::Refused), now + 1);
    let told = Effect::NotMoved { to: CLOUD, why: Declined::Refused };
    assert_eq!(effects, [told, Effect::Stay]);
    assert_eq!(chat.state, HOLDING);
    // The store still tells the wish: it is not acted on, and nothing is said again.
    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, Some(CLOUD)), now);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, HOLDING);
    // An answer without it, then a wish: a new one.
    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, None), now);
    assert!(effects.is_empty(), "{effects:?}");
    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, Some(CLOUD)), now);
    assert_eq!(effects, [Effect::StopTurn]);
    assert_eq!(chat.state, giving(GiveStep::Stopping));
}

#[test]
fn a_give_that_lost_the_fence_asks_the_store_whose_the_chat_is() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (asked, effects) = step(chat, give_failed(GiveFailure::Lost), now + 1);
    assert_eq!(asked.state, giving(GiveStep::Copying));
    assert_eq!(acts(&effects), ["renew"]);
    let holder = Effect::Renew { request: 3, epoch: 1, needs_run: false, standby: false };
    assert!(effects.contains(&holder), "{effects:?}");

    // Another holder has the chat: what ran here is killed and kept, and the laptop stands by.
    let (chat, effects) = step(asked, taken(&renewal(3), Verdict::Standby), now + 2);
    assert_eq!(chat.state, State::Standby { epoch: 2 });
    assert_eq!(acts(&effects), ["kill_tree", "write_leftover_patch", "renew"]);

    // Still this laptop's, and the person still wants it moved: the next tick asks again.
    let (chat, effects) = step(asked, held(&renewal(3), Some(CLOUD)), now + 2);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, giving(GiveStep::Copying));
    let (chat, effects, _) = tick(chat);
    assert_eq!(acts(&effects), ["give", "renew"]);
    assert_eq!(chat.state, giving(GiveStep::Asking));

    // Still this laptop's, and the wish is gone: the chat goes on here.
    let (chat, effects) = step(asked, held(&renewal(3), None), now + 2);
    assert_eq!(effects, [Effect::Stay]);
    assert_eq!(chat.state, HOLDING);
}

#[test]
fn a_give_the_store_did_not_answer_is_asked_again_at_the_next_tick() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, effects) = step(chat, give_failed(GiveFailure::Unanswered), now + 1);
    assert!(effects.is_empty(), "{effects:?}");
    assert_eq!(chat.state, giving(GiveStep::Copying));
    let (chat, effects, now) = tick(chat);
    assert_eq!(acts(&effects), ["give", "renew"]);
    assert!(effects.contains(&Effect::Give { epoch: 1 }), "{effects:?}");
    assert_eq!(chat.state, giving(GiveStep::Asking));
    // The first ask had reached the store after all: the second is refused at the fence, and
    // the renewal says the chat is another holder's.
    let (chat, effects) = step(chat, give_failed(GiveFailure::Lost), now + 1);
    let (chat, effects) = step(chat, taken(&effects, Verdict::Lost), now + 2);
    assert_eq!(chat.state, State::Standby { epoch: 2 });
    assert_eq!(acts(&effects), ["kill_tree", "write_leftover_patch", "renew"]);
}

#[test]
fn a_turn_that_does_not_stop_keeps_the_chat_here() {
    let (chat, now) = give_until(GiveStep::Stopping);
    let (chat, effects) = step(chat, give_failed(GiveFailure::Stuck), now + 1);
    let told = Effect::NotMoved { to: CLOUD, why: Declined::Stuck };
    assert_eq!(effects, [told, Effect::Stay]);
    assert_eq!(chat.state, HOLDING);
    // Nothing was copied or asked for this give.
    assert_eq!(chat.copies, 1);
}

#[test]
fn a_wish_that_disappears_mid_give_leaves_the_chat_running_here() {
    for until in [GiveStep::Stopping, GiveStep::Copying, GiveStep::Asking] {
        let (chat, _) = give_until(until);
        let (chat, effects, now) = tick(chat);
        assert_eq!(acts(&effects), ["renew"], "{until:?}");
        assert_eq!(chat.state, giving(until));
        let (chat, effects) = step(chat, held(&effects, None), now);
        assert_eq!(effects, [Effect::Stay], "{until:?}");
        assert_eq!(chat.state, HOLDING);
        assert!(chat.may_run());
        // What the give still had on its way changes nothing.
        let late = [
            Event::TurnStopped,
            Event::SnapshotStored { copy: 2, snapshot: 2 },
            give_failed(GiveFailure::NoMove),
        ];
        for event in late {
            let (after, effects) = step(chat, event, now + 1);
            assert_eq!(after.state, HOLDING, "{until:?} {event:?}");
            assert!(acts(&effects).is_empty(), "{until:?} {event:?}: {effects:?}");
        }
    }
}

#[test]
fn a_chat_too_large_to_copy_is_not_given_and_says_so_once() {
    let ended = Event::Changed { change: Change::TurnEnded, needs_run: false };
    let (chat, _) = step(holding(0), ended, 100);
    let (chat, effects) = step(chat, Event::SnapshotFailed { copy: 2, too_large: true }, 200);
    assert_eq!(effects, [Effect::ShowBlocked { blocked: Some(Blocked::TooLarge) }]);
    let told = Effect::NotMoved { to: CLOUD, why: Declined::TooLarge };

    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, Some(CLOUD)), now);
    assert_eq!(effects, [told]);
    assert_eq!(chat.state, HOLDING);
    assert!(chat.may_run());
    // The store tells the wish at every renewal until it gives it up: said once.
    let (chat, effects, now) = tick(chat);
    let (chat, effects) = step(chat, held(&effects, Some(CLOUD)), now);
    assert!(effects.is_empty(), "{effects:?}");
    // The person asks again from this laptop: told again, and still not given.
    let (chat, effects) = step(chat, Event::Wished { to: CLOUD, at: None }, now + 1);
    assert_eq!(effects, [told]);
    assert_eq!(chat.state, HOLDING);
}

#[test]
fn a_copy_past_the_cap_ends_the_give() {
    let (chat, now) = give_until(GiveStep::Copying);
    let (chat, effects) = step(chat, Event::SnapshotFailed { copy: 2, too_large: true }, now + 1);
    let told = Effect::NotMoved { to: CLOUD, why: Declined::TooLarge };
    let blocked = Effect::ShowBlocked { blocked: Some(Blocked::TooLarge) };
    assert_eq!(effects, [told, Effect::Stay, blocked]);
    assert_eq!(chat.state, HOLDING);
}

#[test]
fn a_laptop_that_cannot_reach_the_cloud_stops_its_give_too() {
    let (chat, now) = give_until(GiveStep::Copying);
    // No renewal is answered from the wish on.
    let (chat, effects) = step(chat, Event::Tick, now - 1 + SELF_STOP_MS);
    assert_eq!(chat.state, State::Stopped { epoch: 1, why: Stop::Offline });
    assert_eq!(effects.first(), Some(&Effect::StopTree));
    assert!(has(&effects, "stay"), "{effects:?}");
    assert!(!chat.may_run() && chat.moving().is_none());

    // The store answers again, still with the wish: the tree goes on and the give begins
    // again in the same step, so the turn the first give stopped does not go on here between
    // the two.
    let (chat, effects) = step(chat, held(&effects, Some(CLOUD)), now + SELF_STOP_MS);
    assert_eq!(acts(&effects), ["continue_tree", "stop_turn"]);
    assert_eq!(chat.state, giving(GiveStep::Stopping));
    assert!(!chat.may_run());
}

#[test]
fn a_laptop_that_stops_by_itself_does_not_ask_the_store_to_take_the_chat() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (chat, _) = step(chat, give_failed(GiveFailure::Unanswered), now + 1);
    // The tick that would ask again is the one at which the laptop stops.
    let (chat, effects) = step(chat, Event::Tick, now - 2 + SELF_STOP_MS);
    assert_eq!(chat.state, State::Stopped { epoch: 1, why: Stop::Offline });
    assert_eq!(acts(&effects), ["stop_tree", "renew", "stay"]);
}

#[test]
fn a_wish_the_store_tells_differently_mid_give_goes_on_as_it_says_now() {
    let (chat, _) = give_until(GiveStep::Copying);
    let (chat, effects, now) = tick(chat);
    let moved = answer(Verdict::Holder, 3, 1).wishing(Some(MoveTo::Local));
    let moved = Event::Answered { request: request(&effects), answer: moved };
    let (chat, effects) = step(chat, moved, now);
    assert!(effects.is_empty(), "{effects:?}");
    let local = State::Giving { epoch: 3, step: GiveStep::Copying, to: MoveTo::Local };
    assert_eq!(chat.state, local);
    // The give asks at the epoch the store named.
    let (_, effects) = step(chat, Event::SnapshotStored { copy: 2, snapshot: 2 }, now + 1);
    assert_eq!(effects, [Effect::Give { epoch: 3 }]);
}

#[test]
fn a_wake_before_the_store_was_asked_stops_the_chat_and_asks() {
    for until in [GiveStep::Stopping, GiveStep::Copying] {
        let (chat, now) = give_until(until);
        let (chat, effects) = step(chat, Event::Wake, now + 1);
        assert_eq!(chat.state, State::Stopped { epoch: 1, why: Stop::Wake }, "{until:?}");
        assert_eq!(acts(&effects), ["stop_tree", "stay", "renew"], "{until:?}");
        // Another holder has the chat by now.
        let (chat, effects) = step(chat, taken(&effects, Verdict::Lost), now + 2);
        assert_eq!(chat.state, State::Standby { epoch: 2 }, "{until:?}");
        assert_eq!(acts(&effects), ["kill_tree", "write_leftover_patch", "renew"], "{until:?}");
    }
}

#[test]
fn a_wake_while_the_store_is_asked_keeps_the_chat_frozen_until_an_answer() {
    let asking = State::Giving { epoch: 1, step: GiveStep::Asking, to: CLOUD };
    let (chat, now) = give_until(GiveStep::Asking);
    // The network changed with the give on its way: nothing of the chat starts here.
    let (woke, effects) = step(chat, Event::Wake, now + 1);
    assert_eq!(woke.state, asking);
    assert_eq!(acts(&effects), ["renew"]);
    assert!(!woke.may_run());
    // The renewal overtakes the give: this laptop still holds the chat and the wish stands.
    // The turn the give stopped does not go on here.
    let (chat, after) = step(woke, held(&effects, Some(CLOUD)), now + 2);
    assert_eq!(chat.state, asking);
    assert!(after.is_empty(), "{after:?}");
    assert!(!chat.may_run());
    // The give lands: the chat is the machine's, and this laptop ran none of it since.
    let (gone, after) = step(chat, Event::Gave { epoch: 2 }, now + 3);
    assert_eq!(gone.state, State::Standby { epoch: 2 });
    assert_eq!(acts(&after), ["kill_tree", "write_leftover_patch", "renew"]);
    // Or the store took the give before the renewal reached it.
    let (gone, after) = step(woke, taken(&effects, Verdict::Lost), now + 2);
    assert_eq!(gone.state, State::Standby { epoch: 2 });
    assert_eq!(acts(&after), ["kill_tree", "write_leftover_patch", "renew"]);
    // Or the person took the move back: the turn goes on here, once.
    let (stays, after) = step(woke, held(&effects, None), now + 2);
    assert_eq!(stays.state, State::Holding { epoch: 1 });
    assert_eq!(after, [Effect::Stay]);
}

#[test]
fn a_laptop_that_does_not_hold_the_chat_gives_nothing() {
    let (chat, now) = give_until(GiveStep::Asking);
    let (standby, _) = step(chat, Event::Gave { epoch: 2 }, now + 1);
    let events =
        [Event::Wished { to: CLOUD, at: None }, Event::TurnStopped, Event::Gave { epoch: 3 }];
    for event in events {
        let (after, effects) = step(standby, event, now + 2);
        assert_eq!(after.state, State::Standby { epoch: 2 }, "{event:?}");
        assert!(effects.is_empty(), "{event:?}: {effects:?}");
    }
}

#[test]
fn a_gives_answer_is_read_by_the_stores_own_word() {
    let failed = |error: AutoCloudError| Event::from_give(&Err(error));
    let named = |code: &str| failed(AutoCloudError::http(409, code, "refused"));
    assert_eq!(named("auto.not_copied"), give_failed(GiveFailure::NotCopied));
    assert_eq!(named("auto.no_move"), give_failed(GiveFailure::NoMove));
    assert_eq!(named("auto.no_laptop"), give_failed(GiveFailure::Refused));
    assert_eq!(named("auto.no_machine"), give_failed(GiveFailure::Refused));
    let fence = give_failed(GiveFailure::Lost);
    assert_eq!(failed(AutoCloudError::refused(ErrorCode::StaleEpoch, "stale")), fence);
    assert_eq!(failed(AutoCloudError::refused(ErrorCode::NotHolder, "not the holder")), fence);
    // No answer, or one that says nothing about the chat: asked again.
    let unanswered = give_failed(GiveFailure::Unanswered);
    assert_eq!(failed(AutoCloudError::transport("no network")), unanswered);
    assert_eq!(failed(AutoCloudError::http(500, "internal", "broken")), unanswered);
    assert_eq!(failed(AutoCloudError::from_response(502, b"<html>502</html>")), unanswered);
}
