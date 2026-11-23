//! A machine's chat going home, and a holder giving a chat up.

use super::*;
use crate::consts::LEASE_MS;
use crate::wire::{Blocked, InboxAck, Role, State};

/// The machine holds the chat at epoch 2 and the laptop stands by.
fn coming_back() -> (FakeAutoCloud, FakeAutoCloud) {
    let (owner, machine) = taken_over();
    let listed = stand_by(&owner, &mac(), 1);
    assert_eq!((listed.role, listed.session.standby.clone()), (Role::Standby, vec![mac()]));
    assert_eq!(listed.session.state, State::ComingBack);
    assert!(listed.session.handback_due());
    (owner, machine)
}

/// The machine's renewal: whether it still holds the chat.
fn still_held(machine: &FakeAutoCloud, needs_run: bool) -> bool {
    let answer = renew(machine, &vm(), 2, needs_run);
    assert_eq!(answer.session.holder == vm(), answer.role == Role::Holder);
    answer.role == Role::Holder
}

#[test]
fn a_machine_hands_back_at_its_renewal_once_everything_is_copied() {
    let (owner, machine) = coming_back();
    assert_eq!(append_as(&machine, &vm(), 2, 1..=2), Ok(2));

    // At work: it keeps the chat.
    assert!(still_held(&machine, true));
    // Idle, but the store's snapshot does not cover its last event.
    assert!(still_held(&machine, false));
    assert_eq!(snapshot_as(&machine, &vm(), 2, b"the folder", 2), Ok(1));

    // Idle and copied, but a message it has not taken waits.
    send(&owner, "m1", "one more thing");
    assert!(still_held(&machine, false));
    let ack = InboxAck { holder: vm(), epoch: 2, through: 1 };
    ready(machine.ack_inbox(CHAT, &ack)).expect("acked");
    // The message is acked, the assignment it made is not.
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);
    assert!(still_held(&machine, false));
    ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");

    // The person keeps the chat in the Cloud.
    ready(owner.keep(CHAT, true)).expect("kept");
    assert!(still_held(&machine, false));
    assert!(!chat(&owner).handback_due());
    ready(owner.keep(CHAT, false)).expect("not kept");

    // Nothing left: this renewal gives the chat home, and tells the machine it lost it.
    let answer = renew(&machine, &vm(), 2, false);
    assert_eq!((answer.role, answer.session.epoch), (Role::Lost, 3));
    let session = answer.session;
    assert_eq!((session.holder.clone(), session.state), (mac(), State::Local));
    assert!(session.standby.is_empty());
    assert_eq!(session.lease_expires_at, owner.now() + LEASE_MS);

    // The laptop learns it from its next standby renewal: the chat is its own, to import.
    let home = stand_by(&owner, &mac(), 2);
    assert_eq!((home.role, home.session.epoch), (Role::Holder, 3));
    // The machine is no longer the holder.
    assert_eq!(renew(&machine, &vm(), 2, false).role, Role::Lost);
    assert!(kinds(&machine).is_empty());
}

#[test]
fn a_snapshot_covers_the_chat_only_through_the_events_the_store_had() {
    let (_owner, machine) = coming_back();
    // The manifest says it was taken after event 2, and the store has no event yet.
    assert_eq!(snapshot_as(&machine, &vm(), 2, b"the folder", 2), Ok(1));
    assert_eq!(append_as(&machine, &vm(), 2, 1..=2), Ok(2));
    assert!(still_held(&machine, false));

    // Events first, then the snapshot, then the renewal.
    assert_eq!(snapshot_as(&machine, &vm(), 2, b"the folder", 2), Ok(2));
    assert!(!still_held(&machine, false));
}

#[test]
fn a_paused_idle_machine_loses_the_chat_to_a_standby() {
    let (owner, machine) = taken_over();
    // The machine said it had nothing left to run, with no laptop to give the chat to, and
    // then was paused: it renews no more.
    assert!(still_held(&machine, false));
    owner.advance(LEASE_MS - 1);
    assert_eq!(stand_by(&owner, &mac(), 1).role, Role::Standby);

    owner.advance(1);
    let home = stand_by(&owner, &mac(), 2);
    assert_eq!((home.role, home.session.epoch), (Role::Holder, 3));
    assert_eq!((home.session.holder.clone(), home.session.state), (mac(), State::Local));
    assert_eq!(renew(&machine, &vm(), 2, false).role, Role::Lost);
}

#[test]
fn a_paused_machine_at_work_keeps_the_chat() {
    let (owner, machine) = taken_over();
    assert!(still_held(&machine, true));
    owner.advance(3 * LEASE_MS);
    let waiting = stand_by(&owner, &mac(), 1);
    assert_eq!((waiting.role, waiting.session.holder), (Role::Standby, vm()));

    // So does an idle one whose last events no snapshot covers.
    assert_eq!(append_as(&machine, &vm(), 2, 1..=1), Ok(1));
    ready(owner.keep(CHAT, true)).expect("kept");
    assert!(still_held(&machine, false));
    ready(owner.keep(CHAT, false)).expect("not kept");
    owner.advance(3 * LEASE_MS);
    assert_eq!(stand_by(&owner, &mac(), 2).role, Role::Standby);
}

#[test]
fn a_machines_release_gives_the_chat_to_its_standby_laptop() {
    let (_owner, machine) = coming_back();
    let released = ready(machine.release(CHAT, &Fence::new(vm(), 2))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch, released.state), (mac(), 3, State::Local));
    assert!(released.standby.is_empty());
    assert_eq!(code(ready(machine.release(CHAT, &Fence::new(vm(), 2)))), ErrorCode::StaleEpoch);

    // Kept in the Cloud, a released chat is parked instead.
    let (owner, machine) = coming_back();
    ready(owner.keep(CHAT, true)).expect("kept");
    let released = ready(machine.release(CHAT, &Fence::new(vm(), 2))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (Holder::Parked, 3));
}

#[test]
fn a_laptops_release_parks_the_chat_for_any_laptop_to_take() {
    let (owner, _machine) = store();
    let other = Holder::device("other");
    assert_eq!(stand_by(&owner, &other, 1).role, Role::Standby);

    // It does not go to the other laptop by itself: that one takes it at its next renewal.
    let released = ready(owner.release(CHAT, &Fence::new(mac(), 1))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (Holder::Parked, 2));
    assert_eq!(released.lease_expires_at, 0);
    let taken = stand_by(&owner, &other, 1);
    assert_eq!(
        (taken.role, taken.session.holder.clone(), taken.session.epoch),
        (Role::Holder, other, 3)
    );
}

#[test]
fn a_release_with_an_unread_message_keeps_or_reassigns() {
    // A laptop gives up a chat with a message it never took: the Auto machine gets it.
    let (owner, machine) = store();
    send(&owner, "m1", "are you there");
    let released = ready(owner.release(CHAT, &Fence::new(mac(), 1))).expect("released");
    assert_eq!(
        (released.holder.clone(), released.epoch, released.state),
        (vm(), 2, State::Resuming)
    );
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);
    assert_eq!(owner.machine_starts(), [VM]);

    // The Auto machine releases with a message unread: the chat stays with it, at the same
    // epoch, with the delivery still to pick up.
    let (owner, machine) = taken_over();
    send(&owner, "m1", "one more thing");
    let released = ready(machine.release(CHAT, &Fence::new(vm(), 2))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (vm(), 2));
    assert_eq!(kinds(&machine), [AssignmentKind::Deliver]);

    // Another machine releases with a message unread: the chat goes to the Auto machine.
    let next = MachineSetting { team: TEAM.into(), machine: "vm_2".into() };
    ready(owner.set_machine(&next)).expect("the Auto machine");
    let released = ready(machine.release(CHAT, &Fence::new(vm(), 2))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (Holder::vm("vm_2"), 3));
    assert_eq!(kinds(&owner.as_machine("vm_2")), [AssignmentKind::Takeover]);

    // With no Auto machine the message waits with the parked chat.
    let owner = FakeAutoCloud::new();
    ready(owner.put(CHAT, &put_request("mac"))).expect("the chat");
    send(&owner, "m1", "are you there");
    let released = ready(owner.release(CHAT, &Fence::new(mac(), 1))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (Holder::Parked, 2));
    assert_eq!(released.blocked, Some(Blocked::NoMachine));
}
