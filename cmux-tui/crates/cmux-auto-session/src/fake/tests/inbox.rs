//! The inbox: who a message goes to, and how the holder takes it.

use super::*;
use crate::consts::LEASE_MS;
use crate::wire::{
    Assignment, AssignmentKind, Blocked, Delivery, InboxAck, InboxPost, InboxPosted, State,
};

fn send(cloud: &FakeAutoCloud, id: &str, text: &str) -> InboxPosted {
    let message = InboxPost { id: id.into(), text: text.into() };
    ready(cloud.post_inbox(CHAT, &message)).expect("posted")
}

fn kinds(machine: &FakeAutoCloud) -> Vec<AssignmentKind> {
    let assignments: Vec<Assignment> = ready(machine.assignments(0)).expect("assignments");
    assignments.iter().map(|assignment| assignment.kind).collect()
}

fn ack(holder: Holder, epoch: u64, through: u64) -> InboxAck {
    InboxAck { holder, epoch, through }
}

#[test]
fn a_laptop_drains_its_inbox() {
    let (owner, machine) = store();
    let posted = send(&owner, "m1", "hello");
    assert_eq!(posted.state, Delivery::Queued);
    assert_eq!((posted.session.inbox, posted.session.inbox_acked), (1, 0));

    // The same id again stores nothing new.
    let again = send(&owner, "m1", "hello, again");
    assert_eq!((again.state, again.session.inbox), (Delivery::Queued, 1));
    send(&owner, "m2", "and this");

    // The laptop sees them at its renewal, reads them and acks.
    assert!(renew(&owner, &mac(), 1, false).session.inbox_pending());
    let messages = ready(owner.inbox(CHAT, 0)).expect("the inbox");
    let read: Vec<(u64, &str, &str)> =
        messages.iter().map(|m| (m.n, m.id.as_str(), m.text.as_str())).collect();
    assert_eq!(read, [(1, "m1", "hello"), (2, "m2", "and this")]);
    assert_eq!(ready(owner.inbox(CHAT, 1)).expect("the inbox").len(), 1);
    // The machine does not hold the chat, so the inbox is not its to read.
    assert_eq!(code(ready(machine.inbox(CHAT, 0))), ErrorCode::NotHolder);

    let past = ready(owner.ack_inbox(CHAT, &ack(mac(), 1, 5))).expect_err("past the inbox");
    assert_eq!(past.status(), Some(400));
    let acked = ready(owner.ack_inbox(CHAT, &ack(mac(), 1, 2))).expect("acked");
    assert_eq!((acked.inbox_acked, acked.inbox_pending()), (2, false));

    // A message the holder took answers "delivered" when it is sent again.
    assert_eq!(send(&owner, "m1", "hello").state, Delivery::Delivered);
    assert!(owner.machine_starts().is_empty());
}

#[test]
fn a_message_for_a_parked_chat_starts_the_auto_machine() {
    let (owner, machine) = store();
    owner.advance(LEASE_MS);
    assert_eq!(chat(&owner).state, State::Parked);

    let posted = send(&owner, "m1", "go on");
    assert_eq!(posted.state, Delivery::Resuming);
    let session = posted.session;
    assert_eq!((session.holder.clone(), session.epoch, session.state), (vm(), 3, State::Resuming));
    assert_eq!(owner.machine_starts(), [VM]);
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);

    // The machine imports the chat, takes the message and acks both.
    assert_eq!(code(ready(owner.inbox(CHAT, 0))), ErrorCode::NotHolder);
    assert_eq!(ready(machine.inbox(CHAT, 0)).expect("the inbox").len(), 1);
    ready(machine.ack_inbox(CHAT, &ack(vm(), 3, 1))).expect("acked");
    let acked = ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 3))).expect("acked");
    assert_eq!(acked.state, State::Cloud);
    assert!(kinds(&machine).is_empty());
    assert_eq!(send(&owner, "m1", "go on").state, Delivery::Delivered);
}

#[test]
fn a_message_for_a_chat_a_machine_runs_is_a_delivery() {
    let (owner, machine) = taken_over();
    assert!(kinds(&machine).is_empty());

    assert_eq!(send(&owner, "m1", "one more thing").state, Delivery::Resuming);
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);
    // The machine may be paused, so it is started for the delivery.
    assert_eq!(owner.machine_starts(), [VM, VM]);

    // A second message while the delivery waits is part of it.
    send(&owner, "m2", "and another");
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);
    assert_eq!(owner.machine_starts().len(), 2);

    assert_eq!(ready(machine.inbox(CHAT, 0)).expect("the inbox").len(), 2);
    ready(machine.ack_inbox(CHAT, &ack(vm(), 2, 2))).expect("acked");
    let acked = ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert_eq!((acked.state, acked.inbox_pending()), (State::Cloud, false));
    assert!(kinds(&machine).is_empty());
}

#[test]
fn messages_that_came_during_a_takeover_are_delivered_after_it() {
    let (owner, machine) = store();
    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS);
    assert_eq!(send(&owner, "m1", "are you there").state, Delivery::Resuming);
    // The takeover still waits; the message does not replace it.
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);
    assert_eq!(owner.machine_starts(), [VM]);

    ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);
    // The machine is told of a message once.
    ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert!(kinds(&machine).is_empty());
    assert!(chat(&owner).inbox_pending());
}

#[test]
fn with_no_auto_machine_a_message_for_a_parked_chat_waits() {
    let owner = FakeAutoCloud::new();
    ready(owner.put(CHAT, &put_request("mac"))).expect("the chat");
    owner.advance(LEASE_MS);

    let posted = send(&owner, "m1", "go on");
    assert_eq!(posted.state, Delivery::Queued);
    assert_eq!(
        (posted.session.holder.clone(), posted.session.epoch, posted.session.blocked),
        (Holder::Parked, 2, Some(Blocked::NoMachine))
    );

    ready(owner.set_machine(&machine_setting())).expect("the Auto machine");
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch, session.blocked), (vm(), 3, None));
    assert_eq!(kinds(&owner.as_machine(VM)), [AssignmentKind::Takeover]);
}
