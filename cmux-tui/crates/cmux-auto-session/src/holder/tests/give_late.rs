//! A give the store answers late, from the design's "Move now" ("The holder's side"): the
//! person takes the move back while the give is on its way, the turn runs here again, the
//! person asks for the move again, and the first give lands at the same epoch. The store took
//! the chat, so its holder has lost it at once, wherever it is by then.

use super::super::*;
use super::{acts, give_laptop, give_machine, has};

/// The chat after the move a give was asked for is taken back: a renewal answers "holder" with
/// no wish and the turn goes on here, while the give is still on its way. Answers the chat and
/// the time.
fn taken_back_on_a_laptop() -> (Chat, u64) {
    let (chat, _) = give_laptop::give_until(GiveStep::Asking);
    let (chat, effects, now) = give_laptop::tick(chat);
    let (chat, effects) = step(chat, give_laptop::held(&effects, None), now);
    assert_eq!(effects, [Effect::Stay]);
    assert_eq!(chat.state, State::Holding { epoch: 1 });
    assert!(chat.may_run());
    (chat, now)
}

/// The same on a Cloud machine that serves the chat at epoch 2.
fn taken_back_on_a_machine() -> (Chat, u64) {
    let (chat, _) = give_machine::give_until(GiveStep::Asking);
    let (chat, effects, now) = give_machine::tick(chat);
    let (chat, effects) = step(chat, give_machine::held(&effects, None), now);
    assert_eq!(effects, [Effect::Stay]);
    assert_eq!(chat.state, State::Serving { epoch: 2 });
    assert!(chat.may_run());
    (chat, now)
}

/// The chat as the person asks for the move again, at each point the first give's answer can
/// find it: before the holder hears the new wish, and at each step of the give that follows.
fn asked_again(chat: Chat, to: MoveTo, now: u64) -> [Chat; 4] {
    let (stopping, effects) = step(chat, Event::Wished { to, at: None }, now + 1);
    assert_eq!(effects, [Effect::StopTurn]);
    let (copying, effects) = step(stopping, Event::TurnStopped, now + 2);
    let copy = effects
        .iter()
        .find_map(|effect| match effect {
            Effect::UploadSnapshot { copy, .. } => Some(*copy),
            _ => None,
        })
        .expect("the give's copy");
    let stored = Event::SnapshotStored { copy, snapshot: 9 };
    let (asking, effects) = step(copying, stored, now + 3);
    assert_eq!(acts(&effects), ["give"]);
    let steps = [stopping, copying, asking].map(|chat| chat.state.giving().map(|(step, _)| step));
    let expected = [GiveStep::Stopping, GiveStep::Copying, GiveStep::Asking].map(Some);
    assert_eq!(steps, expected);
    [chat, stopping, copying, asking]
}

#[test]
fn a_laptops_first_give_answered_after_the_move_was_asked_again_loses_the_chat_at_once() {
    let (holding, now) = taken_back_on_a_laptop();
    for chat in asked_again(holding, MoveTo::Cloud, now) {
        // The store took the first give at epoch 1: the chat is a machine's, at epoch 2.
        let (after, effects) = step(chat, Event::Gave { epoch: 2 }, now + 4);
        assert_eq!(after.state, State::Standby { epoch: 2 }, "{:?}", chat.state);
        assert_eq!(acts(&effects), ["kill_tree", "write_leftover_patch", "renew"]);
        let standby = matches!(effects.get(2), Some(Effect::Renew { epoch: 2, standby: true, .. }));
        assert!(standby, "{effects:?}");
        assert!(!after.here() && !after.may_run() && after.moving().is_none());
        // The answer to a give from before this laptop got the chat says nothing of it now.
        let (same, effects) = step(chat, Event::Gave { epoch: 1 }, now + 4);
        assert_eq!(same.state, chat.state);
        assert!(effects.is_empty(), "{:?}: {effects:?}", chat.state);
    }
}

#[test]
fn a_laptop_whose_tree_is_stopped_loses_the_chat_to_a_give_answered_late() {
    // A give asked, taken back, and the laptop woke: its tree is stopped until the store
    // answers the renewal.
    let (holding, now) = taken_back_on_a_laptop();
    let (stopped, effects) = step(holding, Event::Wake, now + 1);
    assert_eq!(stopped.state, State::Stopped { epoch: 1, why: Stop::Wake });
    assert_eq!(acts(&effects), ["stop_tree", "renew"]);
    let (after, effects) = step(stopped, Event::Gave { epoch: 2 }, now + 2);
    assert_eq!(after.state, State::Standby { epoch: 2 });
    assert_eq!(acts(&effects), ["kill_tree", "write_leftover_patch", "renew"]);
    assert!(!has(&effects, "continue_tree"));

    // The same for a chat that woke before its give asked the store.
    let (chat, now) = give_laptop::give_until(GiveStep::Copying);
    let (stopped, effects) = step(chat, Event::Wake, now + 1);
    assert_eq!(stopped.state, State::Stopped { epoch: 1, why: Stop::Wake });
    assert_eq!(acts(&effects), ["stop_tree", "stay", "renew"]);
    let (after, effects) = step(stopped, Event::Gave { epoch: 2 }, now + 2);
    assert_eq!(after.state, State::Standby { epoch: 2 });
    assert_eq!(acts(&effects), ["kill_tree", "write_leftover_patch", "renew"]);
    assert!(!has(&effects, "continue_tree"));

    let (same, effects) = step(stopped, Event::Gave { epoch: 1 }, now + 2);
    assert_eq!(same.state, stopped.state);
    assert!(effects.is_empty(), "{effects:?}");
}

#[test]
fn a_machines_first_give_answered_after_the_move_was_asked_again_loses_the_chat_at_once() {
    let (serving, now) = taken_back_on_a_machine();
    let [idle, stopping, copying, asking] = asked_again(serving, MoveTo::Local, now);
    // The store took the first give at epoch 2: the chat is a laptop's, at epoch 3. A machine
    // with nothing left to run and its copy stored keeps nothing, and so does one that asked
    // with its newest copy; one in the middle of the new give keeps what it wrote since.
    let kept = [Effect::KillTree, Effect::WriteLeftoverPatch];
    let cases: [(Chat, &[Effect]); 4] = [
        (idle, &[Effect::KillTree]),
        (stopping, &kept),
        (copying, &kept),
        (asking, &[Effect::KillTree]),
    ];
    for (chat, expected) in cases {
        let (after, effects) = step(chat, Event::Gave { epoch: 3 }, now + 4);
        assert_eq!(after.state, State::Away, "{:?}", chat.state);
        assert_eq!(effects, expected, "{:?}", chat.state);
        assert!(!after.here() && !after.may_run());
        assert_eq!(after.wake_at(), None);
        // The answer to a give from before this machine got the chat says nothing of it now.
        let (same, effects) = step(chat, Event::Gave { epoch: 2 }, now + 4);
        assert_eq!(same.state, chat.state);
        assert!(effects.is_empty(), "{:?}: {effects:?}", chat.state);
    }
}

#[test]
fn a_machine_at_work_keeps_what_it_wrote_when_a_give_is_answered_late() {
    let (serving, now) = taken_back_on_a_machine();
    // The turn the give stopped runs here again, and nothing of it is copied yet.
    let started = Event::Changed { change: Change::TurnStarted, needs_run: true };
    let (at_work, _) = step(serving, started, now + 1);
    assert_eq!(at_work.state, State::Serving { epoch: 2 });
    let (after, effects) = step(at_work, Event::Gave { epoch: 3 }, now + 2);
    assert_eq!(after.state, State::Away);
    assert_eq!(effects, [Effect::KillTree, Effect::WriteLeftoverPatch]);
}
