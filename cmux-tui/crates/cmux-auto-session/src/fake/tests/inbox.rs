//! The inbox: who a message goes to, and how the holder takes it.

use super::*;
use crate::consts::LEASE_MS;
use crate::wire::{Blocked, Delivery, InboxAck, Role, State};

fn ack(holder: Holder, epoch: u64, through: u64) -> InboxAck {
    InboxAck { holder, epoch, through }
}

#[test]
fn a_laptop_reads_and_acks_its_inbox() {
    let (owner, machine) = store();
    let posted = send(&owner, "m1", "hello");
    assert_eq!(posted.state, Delivery::Delivered);
    assert_eq!((posted.session.inbox, posted.session.inbox_acked), (1, 0));

    // The same id again stores nothing new.
    let again = send(&owner, "m1", "hello, again");
    assert_eq!((again.state, again.session.inbox), (Delivery::Delivered, 1));
    send(&owner, "m2", "and this");

    // The laptop sees them at its renewal, reads them and acks.
    assert!(renew(&owner, &mac(), 1, false).session.inbox_pending());
    let messages = ready(owner.inbox(CHAT, 0)).expect("the inbox");
    let read: Vec<(u64, &str, &str)> =
        messages.iter().map(|m| (m.n, m.id.as_str(), m.text.as_str())).collect();
    assert_eq!(read, [(1, "m1", "hello"), (2, "m2", "and this")]);
    assert_eq!(ready(owner.inbox(CHAT, 1)).expect("the inbox").len(), 1);
    // The machine does not hold the chat, so the chat is not its to read.
    assert_eq!(status(ready(machine.inbox(CHAT, 0))), Some(404));

    // An ack past the newest message acks the newest.
    let acked = ready(owner.ack_inbox(CHAT, &ack(mac(), 1, 5))).expect("acked");
    assert_eq!((acked.inbox_acked, acked.inbox_pending()), (2, false));
    assert!(ready(owner.inbox(CHAT, 0)).expect("the inbox").is_empty());

    // A message sent again after the holder took it is still known.
    assert_eq!(send(&owner, "m1", "hello").session.inbox, 2);
    assert!(owner.machine_starts().is_empty());
}

#[test]
fn a_message_for_a_parked_chat_starts_the_auto_machine() {
    let (owner, machine) = store();
    // The laptop's first copy is stored: from here a message alone can start a machine.
    snapshot_as(&owner, &mac(), 1, b"folder", 0).expect("stored");
    owner.advance(LEASE_MS);
    assert_eq!(chat(&owner).state, State::Parked);

    let posted = send(&owner, "m1", "go on");
    assert_eq!(posted.state, Delivery::Resuming);
    let session = posted.session;
    assert_eq!((session.holder.clone(), session.epoch, session.state), (vm(), 3, State::Resuming));
    assert_eq!(owner.machine_starts(), [VM]);
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);

    // The machine imports the chat, takes the message and acks both.
    assert_eq!(ready(machine.inbox(CHAT, 0)).expect("the inbox").len(), 1);
    ready(machine.ack_inbox(CHAT, &ack(vm(), 3, 1))).expect("acked");
    let acked = ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 3))).expect("acked");
    assert_eq!(acked.state, State::Cloud);
    assert!(kinds(&machine).is_empty());
    // The same id again is answered what the first was.
    assert_eq!(send(&owner, "m1", "go on").state, Delivery::Resuming);
}

#[test]
fn a_message_for_a_chat_a_machine_runs_is_a_delivery() {
    let (owner, machine) = taken_over();
    assert!(kinds(&machine).is_empty());

    // The machine runs: it reads the message. It is still started, in case it stopped since.
    assert_eq!(send(&owner, "m1", "one more thing").state, Delivery::Delivered);
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);
    assert_eq!(owner.machine_starts(), [VM, VM]);

    // A second message while the delivery waits is part of it.
    assert_eq!(send(&owner, "m2", "and another").state, Delivery::Resuming);
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);
    assert_eq!(owner.machine_starts().len(), 2);

    assert_eq!(ready(machine.inbox(CHAT, 0)).expect("the inbox").len(), 2);
    ready(machine.ack_inbox(CHAT, &ack(vm(), 2, 2))).expect("acked");
    let acked = ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert_eq!((acked.state, acked.inbox_pending()), (State::Cloud, false));
    assert!(kinds(&machine).is_empty());

    // A machine that stopped renewing is paused: a message for it is "resuming".
    owner.advance(LEASE_MS);
    assert_eq!(send(&owner, "m3", "still there").state, Delivery::Resuming);
    assert_eq!(owner.machine_starts().len(), 3);
}

#[test]
fn an_assignment_ack_with_unread_inbox_leaves_a_deliver() {
    let (owner, machine) = store();
    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS);
    assert_eq!(send(&owner, "m1", "are you there").state, Delivery::Resuming);
    // The takeover still waits; the message does not replace it or start the machine again.
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);
    assert_eq!(owner.machine_starts(), [VM]);

    // The machine acks the takeover without having read the message: a delivery is left, so
    // the message is not stuck on a machine that thinks it has nothing to do.
    let acked = ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert_eq!((acked.state, acked.inbox_pending()), (State::Resuming, true));
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);
    // It stays for as long as the message is unread.
    ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);

    ready(machine.ack_inbox(CHAT, &ack(vm(), 2, 1))).expect("acked");
    let acked = ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert_eq!(acked.state, State::Cloud);
    assert!(kinds(&machine).is_empty());
}

#[test]
fn with_no_auto_machine_a_message_for_a_parked_chat_waits() {
    let owner = FakeAutoCloud::new();
    ready(owner.put(CHAT, &put_request("mac"))).expect("the chat");
    snapshot_as(&owner, &mac(), 1, b"folder", 0).expect("stored");
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

#[test]
fn a_laptop_that_comes_back_takes_the_waiting_message_itself() {
    // The store has no snapshot of the chat, so no machine could go on with it: Auto machine
    // or not, the message waits for the laptop.
    let (owner, machine) = store();
    owner.advance(LEASE_MS);
    let posted = send(&owner, "m1", "go on");
    assert_eq!((posted.state, posted.session.blocked), (Delivery::Queued, None));
    assert!(kinds(&machine).is_empty() && owner.machine_starts().is_empty());

    let back = renew(&owner, &mac(), 1, false);
    assert_eq!((back.role, back.session.epoch, back.session.blocked), (Role::Holder, 3, None));
    assert!(back.session.inbox_pending());
    assert_eq!(ready(owner.inbox(CHAT, 0)).expect("the inbox").len(), 1);
}

#[test]
fn an_inbox_holds_at_most_256_unread_messages() {
    let (owner, _machine) = store();
    for n in 1..=256 {
        send(&owner, &format!("m{n}"), "hello");
    }
    let message = InboxPost { id: "m257".into(), text: "hello".into() };
    let full = ready(owner.post_inbox(CHAT, &message)).expect_err("full");
    assert_eq!((full.code(), full.status()), (Some(ErrorCode::TooLarge), Some(413)));
    // One read answers at most 64, and the next goes on from there.
    let page = ready(owner.inbox(CHAT, 0)).expect("the inbox");
    assert_eq!((page.len(), page.last().map(|last| last.n)), (64, Some(64)));
    assert_eq!(ready(owner.inbox(CHAT, 64)).expect("the inbox").first().map(|m| m.n), Some(65));

    ready(owner.ack_inbox(CHAT, &ack(mac(), 1, 256))).expect("acked");
    assert_eq!(ready(owner.post_inbox(CHAT, &message)).map(|posted| posted.session.inbox), Ok(257));
}
