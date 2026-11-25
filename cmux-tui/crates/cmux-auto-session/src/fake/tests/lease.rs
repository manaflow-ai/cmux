//! The lease: who holds a chat, the epoch, the alarm, a parked chat and the fence.

use super::*;
use crate::consts::{LEASE_MS, RENEW_MS};
use crate::wire::{Blocked, InboxAck, Role, State};

#[test]
fn a_renewal_keeps_the_lease() {
    let (owner, _machine) = store();
    for _ in 0..10 {
        owner.advance(RENEW_MS);
        let answer = renew(&owner, &mac(), 1, true);
        assert_eq!((answer.role, answer.session.epoch), (Role::Holder, 1));
        assert_eq!(
            (answer.lease_ms, answer.session.lease_expires_at),
            (LEASE_MS, owner.now() + LEASE_MS)
        );
    }
    assert!(owner.machine_starts().is_empty());
}

#[test]
fn a_renewal_answers_a_role_never_stale_epoch() {
    let (owner, machine) = taken_over();
    let before = chat(&owner);

    // The laptop renews as the holder it was, at the epoch it held. The answer is a role
    // beside the chat as it is, and nothing is written.
    let request = LeaseRequest { holder: mac(), epoch: 1, needs_run: true, standby: None };
    let lost = ready(owner.lease(CHAT, &request)).expect("an answer, not auto.stale_epoch");
    assert_eq!((lost.role, lost.session.epoch), (Role::Lost, 2));
    assert_eq!(lost.session.holder, vm());

    // The holder itself at an epoch that is over: what it still runs from then may be behind.
    assert_eq!(renew(&machine, &vm(), 1, false).role, Role::Lost);
    assert_eq!(chat(&owner), before);

    // A laptop that renews as standby is remembered, and the holder at the chat's epoch holds.
    assert_eq!(stand_by(&owner, &mac(), 1).role, Role::Standby);
    let held = renew(&machine, &vm(), 2, true);
    assert_eq!((held.role, held.session.epoch), (Role::Holder, 2));
}

#[test]
fn a_lease_that_runs_out_with_work_goes_to_the_auto_machine() {
    let (owner, machine) = store();
    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS - 1);
    assert_eq!(chat(&owner).holder, mac());
    assert!(owner.machine_starts().is_empty());
    assert!(kinds(&machine).is_empty());

    owner.advance(1);
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch, session.state), (vm(), 2, State::Resuming));
    assert_eq!(session.team.as_deref(), Some(TEAM));
    assert_eq!(owner.machine_starts(), [VM]);

    // The assignment stays until the machine acks it. Until then the machine has no lease.
    for _ in 0..2 {
        let assignments = ready(machine.assignments(0)).expect("assignments");
        let assigned: Vec<(AssignmentKind, &str, u64, u64)> = assignments
            .iter()
            .map(|a| (a.kind, a.session.id.as_str(), a.session.epoch, a.session.lease_expires_at))
            .collect();
        assert_eq!(assigned, [(AssignmentKind::Takeover, CHAT, 2, 0)]);
    }
    let acked = ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    assert_eq!((acked.state, acked.lease_expires_at), (State::Cloud, owner.now() + LEASE_MS));
    assert!(kinds(&machine).is_empty());
}

#[test]
fn a_lease_that_runs_out_with_an_unacked_message_goes_to_the_auto_machine() {
    let (owner, machine) = store();
    // The laptop's copy is stored. It said it had nothing to run, and a message came that it
    // never took.
    snapshot_as(&owner, &mac(), 1, b"folder", 0).expect("stored");
    renew(&owner, &mac(), 1, false);
    send(&owner, "m1", "are you there");
    owner.advance(LEASE_MS);
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch, session.state), (vm(), 2, State::Resuming));
    assert!(session.inbox_pending());
    assert_eq!(owner.machine_starts(), [VM]);
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);
}

#[test]
fn an_idle_lease_that_runs_out_parks_the_chat_and_its_laptop_takes_it_back_as_it_is() {
    let (owner, machine) = store();
    owner.advance(LEASE_MS);
    let session = chat(&owner);
    assert_eq!(
        (session.holder.clone(), session.epoch, session.state, session.blocked),
        (Holder::Parked, 2, State::Parked, None)
    );
    assert_eq!(session.lease_expires_at, 0);
    assert!(owner.machine_starts().is_empty() && kinds(&machine).is_empty());

    // Another laptop does not take it by renewing as a holder.
    assert_eq!(renew(&owner, &Holder::device("other"), 1, false).role, Role::Lost);

    // The laptop is back and renews as it did before, naming the epoch it held: nobody ran
    // the chat since, so it goes on as it is, at the new epoch.
    let answer = renew(&owner, &mac(), 1, true);
    assert_eq!((answer.role, answer.session.epoch), (Role::Holder, 3));
    assert_eq!((answer.session.holder.clone(), answer.session.state), (mac(), State::Local));
    assert!(answer.session.needs_run);

    // Its answer was lost and it renews the same way again: the same renewal.
    let again = renew(&owner, &mac(), 1, true);
    assert_eq!((again.role, again.session.epoch), (Role::Holder, 3));
}

#[test]
fn a_parked_chat_goes_to_a_laptop_that_stands_by() {
    let (owner, _machine) = store();
    owner.advance(LEASE_MS);
    let other = Holder::device("other");
    let taken = stand_by(&owner, &other, 0);
    assert_eq!((taken.role, taken.session.epoch), (Role::Holder, 3));
    assert_eq!((taken.session.holder.clone(), taken.session.state), (other, State::Local));

    // The laptop that held it is too late now: what it has is not the chat any more.
    assert_eq!(renew(&owner, &mac(), 1, false).role, Role::Lost);
}

#[test]
fn a_parked_chat_kept_in_the_cloud_goes_only_to_the_laptop_that_held_it() {
    let (owner, _machine) = store();
    ready(owner.keep(CHAT, true)).expect("kept");
    owner.advance(LEASE_MS);

    let other = Holder::device("other");
    let waiting = stand_by(&owner, &other, 2);
    assert_eq!((waiting.role, waiting.session.holder.clone()), (Role::Standby, Holder::Parked));
    assert_eq!(waiting.session.standby, [other]);

    let back = renew(&owner, &mac(), 1, false);
    assert_eq!(
        (back.role, back.session.holder.clone(), back.session.epoch),
        (Role::Holder, mac(), 3)
    );
}

#[test]
fn a_laptop_does_not_take_back_as_it_is_a_chat_a_machine_ran() {
    let (owner, machine) = taken_over();
    let released = ready(machine.release(CHAT, &Fence::new(vm(), 2))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (Holder::Parked, 3));

    // The Cloud copy is ahead of the laptop's, whatever epoch the laptop names.
    assert_eq!(renew(&owner, &mac(), 2, false).role, Role::Lost);
    assert_eq!(renew(&owner, &mac(), 1, false).role, Role::Lost);
    // It takes the chat as a standby, which imports the Cloud copy first.
    let home = stand_by(&owner, &mac(), 2);
    assert_eq!(
        (home.role, home.session.holder.clone(), home.session.epoch),
        (Role::Holder, mac(), 4)
    );
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
fn with_no_auto_machine_the_work_waits_parked_and_blocked() {
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
fn a_chat_given_to_a_machine_that_never_picked_it_up_goes_to_the_next_auto_machine() {
    let (owner, machine) = store();
    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS);
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);

    let next = MachineSetting { team: TEAM.into(), machine: "vm_2".into() };
    ready(owner.set_machine(&next)).expect("the Auto machine");
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch), (Holder::vm("vm_2"), 3));
    assert_eq!(owner.machine_starts(), [VM, "vm_2"]);
    assert!(kinds(&machine).is_empty());
    assert_eq!(kinds(&owner.as_machine("vm_2")), [AssignmentKind::Takeover]);

    // A chat its machine picked up stays there when the Auto machine changes.
    ready(owner.as_machine("vm_2").ack_assignment(CHAT, &Fence::new(Holder::vm("vm_2"), 3)))
        .expect("acked");
    ready(owner.set_machine(&machine_setting())).expect("the Auto machine");
    assert_eq!(chat(&owner).holder, Holder::vm("vm_2"));
}

#[test]
fn every_holder_write_is_fenced_by_holder_and_epoch() {
    let (owner, _machine) = store();
    owner.advance(LEASE_MS);
    assert_eq!(renew(&owner, &mac(), 1, false).session.epoch, 3);

    // The laptop still writes under the epoch it had.
    let stale = Fence::new(mac(), 1);
    assert_eq!(code(append_as(&owner, &mac(), 1, 1..=1)), ErrorCode::StaleEpoch);
    assert_eq!(code(ready(owner.release(CHAT, &stale))), ErrorCode::StaleEpoch);
    assert_eq!(code(snapshot_as(&owner, &mac(), 1, b"x", 0)), ErrorCode::StaleEpoch);
    let ack = InboxAck { holder: mac(), epoch: 1, through: 0 };
    let refused = ready(owner.ack_inbox(CHAT, &ack)).expect_err("a stale epoch");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::StaleEpoch), Some(409)));
    assert!(!refused.retryable());
    // A refusal carries the chat as it is, so the writer learns the epoch it missed.
    let now = refused.session().expect("the chat");
    assert_eq!((now.holder.clone(), now.epoch), (mac(), 3));

    // Another laptop is not the holder, even at the chat's epoch.
    let other = Fence::new(Holder::device("other"), 3);
    assert_eq!(code(ready(owner.release(CHAT, &other))), ErrorCode::NotHolder);
    // The owner's credential does not speak for a machine.
    assert_eq!(code(ready(owner.release(CHAT, &Fence::new(vm(), 3)))), ErrorCode::NotHolder);
    // No write names `parked` as its holder.
    let parked = LeaseRequest { holder: Holder::Parked, epoch: 3, needs_run: false, standby: None };
    assert_eq!(status(ready(owner.lease(CHAT, &parked))), Some(400));

    // Nothing of that reached the chat, and the current epoch writes.
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch, session.last_seq), (mac(), 3, 0));
    assert_eq!(append_as(&owner, &mac(), 3, 1..=1), Ok(1));
}

#[test]
fn the_view_lists_only_the_standbys_that_still_renew() {
    let (owner, _machine) = taken_over();
    let other = Holder::device("other");
    stand_by(&owner, &mac(), 2);
    owner.advance(LEASE_MS - RENEW_MS);
    stand_by(&owner, &other, 2);
    let session = ready(owner.get(CHAT)).expect("the chat");
    assert_eq!(
        (session.standby.clone(), session.state),
        (vec![mac(), other.clone()], State::ComingBack)
    );

    // The first laptop stopped renewing a lease ago: it no longer counts.
    owner.advance(RENEW_MS);
    let session = ready(owner.get(CHAT)).expect("the chat");
    assert_eq!((session.standby.clone(), session.state), (vec![other], State::ComingBack));

    owner.advance(LEASE_MS);
    let session = ready(owner.get(CHAT)).expect("the chat");
    assert!(session.standby.is_empty());
    assert_eq!(session.state, State::Cloud);
}
