//! The lease: who holds a chat, the epoch, the alarm, standby and release.

use serde_json::json;

use super::*;
use crate::chunks::name_of;
use crate::consts::{LEASE_MS, RENEW_MS};
use crate::wire::{AssignmentKind, Blocked, EventsAppend, InboxAck, Role, SeqRecord, State};

#[test]
fn a_lease_that_runs_out_with_work_goes_to_the_auto_machine() {
    let (owner, machine) = store();
    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS - 1);
    assert_eq!(chat(&owner).holder, mac());
    assert!(owner.machine_starts().is_empty());
    assert!(ready(machine.assignments(0)).expect("assignments").is_empty());

    owner.advance(1);
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch, session.state), (vm(), 2, State::Resuming));
    assert_eq!(owner.machine_starts(), [VM]);

    // The assignment stays until the machine acks it.
    for _ in 0..2 {
        let assignments = ready(machine.assignments(0)).expect("assignments");
        assert_eq!(assignments.len(), 1);
        let assignment = assignments.first().expect("one");
        assert_eq!(assignment.kind, AssignmentKind::Takeover);
        assert_eq!((assignment.session.id.as_str(), assignment.session.epoch), (CHAT, 2));
    }
    let acked = ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert_eq!(acked.state, State::Cloud);
    assert!(ready(machine.assignments(0)).expect("assignments").is_empty());
}

#[test]
fn an_idle_lease_that_runs_out_parks_the_chat() {
    let (owner, machine) = store();
    owner.advance(LEASE_MS);
    let session = chat(&owner);
    assert_eq!(
        (session.holder.clone(), session.epoch, session.state, session.blocked),
        (Holder::Parked, 2, State::Parked, None)
    );
    assert!(owner.machine_starts().is_empty());
    assert!(ready(machine.assignments(0)).expect("assignments").is_empty());

    // The laptop is back and renews as it did before: holder again, at the new epoch.
    let answer = renew(&owner, &mac(), 1, false);
    assert_eq!((answer.role, answer.lease_ms), (Role::Holder, LEASE_MS));
    assert_eq!((answer.session.holder.clone(), answer.session.epoch), (mac(), 3));
    assert_eq!(answer.session.state, State::Local);
}

#[test]
fn a_renewal_keeps_the_lease() {
    let (owner, _machine) = store();
    for _ in 0..10 {
        owner.advance(RENEW_MS);
        let answer = renew(&owner, &mac(), 1, true);
        assert_eq!((answer.role, answer.session.epoch), (Role::Holder, 1));
        assert_eq!(answer.session.lease_expires_at, owner.now() + LEASE_MS);
    }
    assert!(owner.machine_starts().is_empty());
}

#[test]
fn a_machines_lease_does_not_run_out() {
    let (owner, machine) = taken_over();
    owner.advance(10 * LEASE_MS);
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch), (vm(), 2));
    let answer = renew(&machine, &vm(), 2, false);
    assert_eq!((answer.role, answer.session.epoch), (Role::Holder, 2));
}

#[test]
fn with_no_auto_machine_the_chat_is_parked_and_blocked() {
    let owner = FakeAutoCloud::new();
    ready(owner.put(CHAT, &put_request("mac"))).expect("the chat");
    let none = ready(owner.machine()).expect_err("no machine");
    assert_eq!((none.code(), none.status()), (Some(ErrorCode::NoMachine), Some(404)));

    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS);
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch), (Holder::Parked, 2));
    assert_eq!((session.blocked, session.needs_run), (Some(Blocked::NoMachine), true));
    assert!(owner.machine_starts().is_empty());

    // The person makes one: the work goes to it.
    assert_eq!(ready(owner.set_machine(&machine_setting())), Ok(machine_setting()));
    assert_eq!(ready(owner.machine()), Ok(machine_setting()));
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch, session.state), (vm(), 3, State::Resuming));
    assert_eq!(session.blocked, None);
    assert_eq!(owner.machine_starts(), [VM]);
}

#[test]
fn every_holder_write_is_fenced_by_holder_and_epoch() {
    let (owner, machine) = store();
    owner.advance(LEASE_MS);
    assert_eq!(renew(&owner, &mac(), 1, false).session.epoch, 3);

    // The laptop still writes under the epoch it had.
    let stale = Fence::new(mac(), 1);
    let record = SeqRecord { seq: 1, record: json!({ "n": 1 }) };
    let events = EventsAppend { holder: mac(), epoch: 1, events: vec![record.clone()] };
    assert_eq!(code(ready(owner.append_events(CHAT, &events))), ErrorCode::StaleEpoch);
    assert_eq!(code(ready(owner.release(CHAT, &stale))), ErrorCode::StaleEpoch);
    let chunk = ready(owner.put_chunk(CHAT, &name_of(b"x"), b"x", &stale));
    assert_eq!(code(chunk), ErrorCode::StaleEpoch);
    let ack = InboxAck { holder: mac(), epoch: 1, through: 0 };
    assert_eq!(code(ready(owner.ack_inbox(CHAT, &ack))), ErrorCode::StaleEpoch);

    // Another laptop is not the holder, whatever epoch it names.
    let other = Fence::new(Holder::device("other"), 3);
    let refused = ready(owner.release(CHAT, &other)).expect_err("not the holder");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::StaleEpoch), Some(409)));
    assert!(!refused.retryable());

    // A caller that cannot be the holder it names.
    assert_eq!(code(ready(machine.release(CHAT, &Fence::new(mac(), 3)))), ErrorCode::NotHolder);
    assert_eq!(code(ready(owner.release(CHAT, &Fence::new(vm(), 3)))), ErrorCode::NotHolder);
    let parked = LeaseRequest { holder: Holder::Parked, epoch: 3, needs_run: false, standby: None };
    assert_eq!(code(ready(owner.lease(CHAT, &parked))), ErrorCode::NotHolder);

    // Nothing of that reached the chat, and the current epoch writes.
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch, session.last_seq), (mac(), 3, 0));
    let events = EventsAppend { holder: mac(), epoch: 3, events: vec![record] };
    assert_eq!(ready(owner.append_events(CHAT, &events)), Ok(1));
}

#[test]
fn a_laptop_that_lost_the_chat_stands_by_and_gets_it_back_at_release() {
    let (owner, machine) = taken_over();
    let held = Fence::new(vm(), 2);

    // The laptop is back. It renews as the holder it was, then as a laptop standing by.
    let lost = renew(&owner, &mac(), 1, true);
    assert_eq!((lost.role, lost.session.epoch), (Role::Lost, 2));
    assert_eq!(lost.session.state, State::Cloud);
    let listed = stand_by(&owner, &mac(), 2);
    assert_eq!((listed.role, listed.session.standby.clone()), (Role::Standby, vec![mac()]));
    assert_eq!(listed.session.state, State::ComingBack);
    assert!(listed.session.handback_due());

    // The machine learns of it at its renewal, and releases at its turn end.
    let answer = renew(&machine, &vm(), 2, false);
    assert!(answer.role == Role::Holder && answer.session.handback_due());
    let released = ready(machine.release(CHAT, &held)).expect("released");
    assert_eq!((released.holder.clone(), released.epoch, released.state), (mac(), 3, State::Local));
    assert!(released.standby.is_empty());
    assert!(ready(machine.assignments(0)).expect("assignments").is_empty());

    // The laptop learns it holds the chat from its next standby renewal.
    let home = stand_by(&owner, &mac(), 2);
    assert_eq!((home.role, home.session.epoch), (Role::Holder, 3));

    // The machine is no longer the holder.
    assert_eq!(code(ready(machine.release(CHAT, &held))), ErrorCode::StaleEpoch);
    assert_eq!(renew(&machine, &vm(), 2, false).role, Role::Lost);
}

#[test]
fn a_standby_listing_runs_out_with_its_lease() {
    let (owner, machine) = taken_over();
    stand_by(&owner, &mac(), 2);
    owner.advance(LEASE_MS - 1);
    assert_eq!(chat(&owner).state, State::ComingBack);
    owner.advance(1);
    let session = chat(&owner);
    assert!(session.standby.is_empty());
    assert_eq!(session.state, State::Cloud);

    // With no laptop standing by, a released chat is parked.
    let released = ready(machine.release(CHAT, &Fence::new(vm(), 2))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (Holder::Parked, 3));
    assert_eq!(released.state, State::Parked);
}

#[test]
fn a_chat_kept_in_the_cloud_is_not_handed_back() {
    let (owner, machine) = taken_over();
    stand_by(&owner, &mac(), 2);
    let kept = ready(owner.keep(CHAT, true)).expect("kept");
    assert!(kept.keep_in_cloud && !kept.handback_due());
    assert_eq!(kept.state, State::Cloud);
    assert!(!renew(&machine, &vm(), 2, false).session.handback_due());

    // No longer kept: the handback is due again.
    let back = ready(owner.keep(CHAT, false)).expect("not kept");
    assert_eq!(back.state, State::ComingBack);
}

#[test]
fn a_second_laptop_does_not_take_a_chat_another_holds() {
    let (owner, _machine) = store();
    let other = Holder::device("other");
    assert_eq!(renew(&owner, &other, 1, false).role, Role::Lost);
    let listed = stand_by(&owner, &other, 1);
    assert_eq!((listed.role, listed.session.holder.clone()), (Role::Standby, mac()));
    assert_eq!(listed.session.state, State::Local);

    // The holder gives it up: it goes to the laptop standing by.
    let released = ready(owner.release(CHAT, &Fence::new(mac(), 1))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (other, 2));
}
