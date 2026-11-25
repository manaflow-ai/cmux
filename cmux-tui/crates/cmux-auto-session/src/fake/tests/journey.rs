//! A chat's whole way, with the holder's `step` deciding and a small daemon (`daemon.rs`)
//! running its effects against the fake store: to the Cloud when the laptop goes away, and
//! home when it is back.

use serde_json::json;

use super::daemon::Daemon;
use super::*;
use crate::consts::{LEASE_MS, RENEW_MS};
use crate::holder::{Change, Event, State, Stop};
use crate::wire::{Delivery, State as Shown};

#[test]
fn a_chat_goes_to_the_cloud_and_comes_home() {
    let cloud = FakeAutoCloud::new();
    ready(cloud.set_machine(&machine_setting())).expect("the Auto machine");

    // Auto on: the laptop registers and sends its first copy.
    let mut mac = Daemon::laptop(&cloud, "mac");
    mac.folder = b"as the laptop left it".to_vec();
    mac.log = vec![json!({ "user": "fix the build" })];
    mac.send(Event::AutoOn);
    assert_eq!(mac.chat.state, State::Holding { epoch: 1 });
    let session = chat(&cloud);
    assert_eq!((session.snapshot, session.last_seq, session.needs_run), (1, 1, false));

    // A turn starts: the store learns the chat has work.
    mac.send(Event::Changed { change: Change::TurnStarted, needs_run: true });
    assert!(chat(&cloud).needs_run);

    // The lid closes mid-turn. Nothing runs on the laptop, and its lease runs out.
    cloud.advance(LEASE_MS);
    let session = chat(&cloud);
    assert_eq!((session.holder.clone(), session.epoch), (vm(), 2));
    assert_eq!(cloud.machine_starts(), [VM]);

    // The machine starts, reads its assignment, imports the chat and goes on with the turn.
    let mut machine = Daemon::machine(&cloud, VM);
    machine.busy = true;
    machine.read_assignments();
    assert_eq!(machine.chat.state, State::Serving { epoch: 2 });
    assert!(machine.ran("import") && machine.ran("ack_assignment"));
    assert_eq!((machine.folder.as_slice(), machine.log.len()), (mac.folder.as_slice(), 1));
    assert_eq!(chat(&cloud).state, Shown::Cloud);
    machine.folder = b"as the machine left it".to_vec();
    machine.log.push(json!({ "assistant": "the build is fixed" }));

    // The lid opens. The laptop stops its tree, asks, and learns a machine has the chat.
    cloud.advance(60_000);
    mac.send(Event::Wake);
    assert_eq!(mac.chat.state, State::Standby { epoch: 2 });
    assert!(mac.ran("stop_tree") && mac.ran("kill_tree") && mac.ran("write_leftover_patch"));
    assert!(!mac.ran("continue_tree") && !mac.chat.may_run());
    let session = chat(&cloud);
    assert_eq!(session.standby, [mac.me.clone()]);
    assert_eq!(session.state, Shown::ComingBack);

    // The turn ends on the machine with nothing queued. It sends one last copy, then says it
    // has nothing left to run: at that renewal the store gives the chat home.
    machine.busy = false;
    machine.send(Event::Changed { change: Change::TurnEnded, needs_run: false });
    assert_eq!(machine.chat.state, State::Away);
    assert!(machine.ran("kill_tree") && !machine.ran("write_leftover_patch"));
    let session = chat(&cloud);
    assert_eq!((session.holder.clone(), session.epoch), (mac.me.clone(), 3));
    assert_eq!((session.state, session.last_seq), (Shown::Local, 2));

    // The laptop's next standby renewal answers "holder": it imports the copy and goes on.
    cloud.advance(RENEW_MS);
    mac.tick();
    assert_eq!(mac.chat.state, State::Holding { epoch: 3 });
    assert!(mac.ran("import") && mac.chat.may_run());
    assert_eq!((mac.folder.as_slice(), mac.log.len()), (machine.folder.as_slice(), 2));

    // What the machine still has is fenced off, and the chat is gone for it.
    let stale = ready(machine.cloud.release(CHAT, &machine.fence(2)));
    assert_eq!(code(stale), ErrorCode::StaleEpoch);
    assert_eq!(status(ready(machine.cloud.get(CHAT))), Some(404));
}

#[test]
fn a_message_wakes_a_parked_chat_in_the_cloud_and_it_comes_home() {
    let cloud = FakeAutoCloud::new();
    ready(cloud.set_machine(&machine_setting())).expect("the Auto machine");
    let mut mac = Daemon::laptop(&cloud, "mac");
    mac.folder = b"as the laptop left it".to_vec();
    mac.log = vec![json!({ "user": "fix the build" })];
    mac.send(Event::AutoOn);

    // The lid closes on an idle chat: it is parked. Then the phone sends a message.
    cloud.advance(LEASE_MS);
    assert_eq!(chat(&cloud).holder, Holder::Parked);
    assert_eq!(send(&cloud, "m1", "carry on").state, Delivery::Resuming);
    assert_eq!(cloud.machine_starts(), [VM]);

    // The machine imports the chat, takes the message and runs it.
    let mut machine = Daemon::machine(&cloud, VM);
    machine.read_assignments();
    assert_eq!(machine.chat.state, State::Serving { epoch: 3 });
    assert_eq!(machine.log.last(), Some(&json!({ "user": "carry on" })));
    let session = chat(&cloud);
    assert_eq!(
        (session.state, session.inbox_pending(), session.needs_run),
        (Shown::Cloud, false, true)
    );

    // The turn ends. Nobody stands by, so the chat stays in the Cloud, copied and idle.
    machine.folder = b"as the machine left it".to_vec();
    machine.log.push(json!({ "assistant": "done" }));
    machine.busy = false;
    machine.send(Event::Changed { change: Change::TurnEnded, needs_run: false });
    assert_eq!(machine.chat.state, State::Serving { epoch: 3 });
    let session = chat(&cloud);
    assert_eq!((session.needs_run, session.last_seq, session.snapshot), (false, 3, 3));

    // The lid opens: the laptop stands by, and the machine's next renewal gives the chat home.
    cloud.advance(20_000);
    mac.send(Event::Wake);
    assert_eq!(mac.chat.state, State::Standby { epoch: 3 });
    cloud.advance(RENEW_MS);
    machine.tick();
    assert_eq!(machine.chat.state, State::Away);
    assert!(machine.ran("kill_tree") && !machine.ran("write_leftover_patch"));
    mac.tick();
    assert_eq!(mac.chat.state, State::Holding { epoch: 4 });
    assert_eq!((mac.folder.as_slice(), mac.log.len()), (machine.folder.as_slice(), 3));
    let session = chat(&cloud);
    assert_eq!(
        (session.holder.clone(), session.epoch, session.state),
        (mac.me.clone(), 4, Shown::Local)
    );
}

#[test]
fn a_laptop_with_no_network_stops_and_goes_on_when_it_is_back() {
    let cloud = FakeAutoCloud::new();
    ready(cloud.set_machine(&machine_setting())).expect("the Auto machine");
    let mut mac = Daemon::laptop(&cloud, "mac");
    mac.send(Event::AutoOn);
    assert_eq!(mac.chat.state, State::Holding { epoch: 1 });

    // The network goes. The laptop keeps running, so it stops the chat by itself before the
    // store's lease runs out.
    mac.cloud.set_offline(true);
    for _ in 0..3 {
        cloud.advance(RENEW_MS);
        mac.tick();
    }
    assert_eq!(mac.chat.state, State::Holding { epoch: 1 });
    assert_eq!(chat(&cloud).holder, mac.me);
    cloud.advance(RENEW_MS);
    mac.tick();
    assert_eq!(mac.chat.state, State::Stopped { epoch: 1, why: Stop::Offline });
    assert!(mac.ran("stop_tree") && !mac.chat.may_run());
    assert_eq!(chat(&cloud).holder, mac.me);

    // The idle chat is parked. A message for it would start the machine; none comes.
    cloud.advance(RENEW_MS);
    mac.tick();
    assert_eq!(chat(&cloud).holder, Holder::Parked);

    // The network is back. Nobody ran the chat since, so the store gives it back as it is, at
    // a new epoch, and the tree goes on.
    mac.cloud.set_offline(false);
    cloud.advance(RENEW_MS);
    mac.tick();
    assert_eq!(mac.chat.state, State::Holding { epoch: 3 });
    assert!(mac.ran("continue_tree") && !mac.ran("kill_tree") && mac.chat.may_run());
    assert_eq!(chat(&cloud).epoch, 3);

    // A message now waits for the laptop's next renewal, which drains it.
    assert_eq!(send(&cloud, "m1", "one more thing").state, Delivery::Delivered);
    cloud.advance(RENEW_MS);
    mac.tick();
    assert!(mac.ran("drain_inbox"));
    assert!(!chat(&cloud).inbox_pending());
    assert_eq!(mac.log.last(), Some(&json!({ "user": "one more thing" })));
}
