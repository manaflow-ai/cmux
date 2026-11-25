//! Who may call what: the owner's routes, a machine's routes, and the chats a machine reaches.

use super::*;
use crate::wire::{CreateRequest, FirstMessage, InboxAck, InboxPost, Repo, Role};

#[test]
fn a_machine_reads_only_a_chat_it_holds() {
    let (owner, machine) = store();
    // The Auto machine does not hold the laptop's chat: to it there is no such chat.
    assert_eq!(status(ready(machine.get(CHAT))), Some(404));
    assert_eq!(status(ready(machine.events(CHAT, 0, None))), Some(404));
    assert_eq!(status(ready(machine.inbox(CHAT, 0))), Some(404));
    let lease = LeaseRequest { holder: vm(), epoch: 1, needs_run: false, standby: None };
    assert_eq!(status(ready(machine.lease(CHAT, &lease))), Some(404));

    // Once it holds the chat it reads it.
    renew(&owner, &mac(), 1, true);
    owner.advance(crate::consts::LEASE_MS);
    assert_eq!(ready(machine.get(CHAT)).map(|session| session.epoch), Ok(2));
    assert!(ready(machine.events(CHAT, 0, None)).is_ok());
    assert!(ready(machine.inbox(CHAT, 0)).is_ok());

    // Another of the owner's machines reaches nothing of it, and has nothing to pick up.
    let other = owner.as_machine("vm_other");
    assert_eq!(status(ready(other.get(CHAT))), Some(404));
    assert_eq!(
        status(ready(other.release(CHAT, &Fence::new(Holder::vm("vm_other"), 2)))),
        Some(404)
    );
    assert_eq!(ready(other.assignments(0)), Ok(Vec::new()));
}

#[test]
fn a_machine_that_lost_the_chat_reads_404_and_its_writes_are_stale() {
    let (owner, machine) = taken_over();
    let released = ready(machine.release(CHAT, &Fence::new(vm(), 2))).expect("released");
    assert_eq!((released.holder.clone(), released.epoch), (Holder::Parked, 3));

    // Its reads: the chat is gone for it.
    assert_eq!(status(ready(machine.get(CHAT))), Some(404));
    assert_eq!(status(ready(machine.events(CHAT, 0, None))), Some(404));
    assert_eq!(status(ready(machine.snapshot(CHAT))), Some(404));
    assert_eq!(status(ready(machine.inbox(CHAT, 0))), Some(404));

    // Its writes: refused as stale, with the chat as it is now.
    let refused = append_as(&machine, &vm(), 2, 1..=1).expect_err("stale");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::StaleEpoch), Some(409)));
    let now = refused.session().expect("the chat");
    assert_eq!((now.holder.clone(), now.epoch), (Holder::Parked, 3));
    assert_eq!(code(snapshot_as(&machine, &vm(), 2, b"x", 0)), ErrorCode::StaleEpoch);
    let ack = InboxAck { holder: vm(), epoch: 2, through: 0 };
    assert_eq!(code(ready(machine.ack_inbox(CHAT, &ack))), ErrorCode::StaleEpoch);
    let held = Fence::new(vm(), 2);
    assert_eq!(code(ready(machine.ack_assignment(CHAT, &held))), ErrorCode::StaleEpoch);
    assert_eq!(code(ready(machine.release(CHAT, &held))), ErrorCode::StaleEpoch);
    // A machine does not write as a laptop.
    assert_eq!(code(ready(machine.release(CHAT, &Fence::new(mac(), 3)))), ErrorCode::NotHolder);
    // Its renewal is answered a role.
    assert_eq!(renew(&machine, &vm(), 2, true).role, Role::Lost);
    assert_eq!(chat(&owner).epoch, 3);
}

#[test]
fn each_caller_has_its_routes() {
    let (owner, machine) = taken_over();
    // The owner's routes are not a machine's.
    assert_eq!(status(ready(machine.put(CHAT, &put_request("mac")))), Some(403));
    assert_eq!(status(ready(machine.list(None, None))), Some(403));
    assert_eq!(status(ready(machine.keep(CHAT, true))), Some(403));
    assert_eq!(status(ready(machine.machine())), Some(403));
    assert_eq!(status(ready(machine.set_machine(&machine_setting()))), Some(403));
    assert_eq!(status(ready(machine.wait(CHAT, 0, 0))), Some(403));
    let message = InboxPost { id: "m1".into(), text: "hello".into() };
    assert_eq!(status(ready(machine.post_inbox(CHAT, &message))), Some(403));
    let create = CreateRequest {
        title: None,
        harness: "claude".into(),
        repo: Repo { remote: "https://example.com/r.git".into(), branch: "main".into() },
        first_message: FirstMessage { id: "m1".into(), text: "start".into() },
    };
    assert_eq!(status(ready(machine.create(&create))), Some(403));

    // A machine's routes are not the owner's.
    assert_eq!(status(ready(owner.assignments(0))), Some(401));
    assert_eq!(status(ready(owner.ack_assignment(CHAT, &Fence::new(vm(), 2)))), Some(401));
    assert_eq!(chat(&owner).inbox, 0);
}

#[test]
fn an_id_the_cloud_would_not_take_is_refused() {
    let (owner, _machine) = store();
    // No chat has such an id, and `machine` and `assignments` are routes.
    for id in ["has space", "machine", "assignments", ""] {
        assert_eq!(status(ready(owner.put(id, &put_request("mac")))), Some(404), "{id:?}");
    }
    let bad = |request: PutRequest| status(ready(owner.put("chat_2", &request)));
    assert_eq!(bad(PutRequest { harness: "Claude Code".into(), ..put_request("mac") }), Some(400));
    assert_eq!(bad(put_request("my mac")), Some(400));
    assert_eq!(bad(PutRequest { title: "x".repeat(201), ..put_request("mac") }), Some(400));
    assert!(owner.peek("chat_2").is_none());

    let team = MachineSetting { team: "team_1".into(), machine: VM.into() };
    assert_eq!(status(ready(owner.set_machine(&team))), Some(400));
    let machine = MachineSetting { team: TEAM.into(), machine: "vm 1".into() };
    assert_eq!(status(ready(owner.set_machine(&machine))), Some(400));

    let empty = InboxPost { id: "m1".into(), text: String::new() };
    assert_eq!(status(ready(owner.post_inbox(CHAT, &empty))), Some(400));
    let spaced = InboxPost { id: "m 1".into(), text: "hello".into() };
    assert_eq!(status(ready(owner.post_inbox(CHAT, &spaced))), Some(400));
    assert_eq!(chat(&owner).inbox, 0);
}
