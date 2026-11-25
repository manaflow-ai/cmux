//! Moving a chat by hand: the person's wish, the holder's give, and a chat kept in the Cloud.

use super::*;
use crate::consts::{LEASE_MS, MOVE_MS};
use crate::wire::{
    CreateRequest, FirstMessage, MoveRefusal, MoveRequest, MoveTo, MoveWish, Repo, Role, State,
};

fn mac2() -> Holder {
    Holder::device("mac2")
}

/// The code only `move` and `give` refuse with.
fn refusal<T: Debug>(result: CloudResult<T>) -> MoveRefusal {
    let error = result.expect_err("refused");
    assert_eq!((error.status(), error.code()), (Some(409), None), "{error}");
    assert!(error.session().is_some(), "a refusal about a chat carries the chat");
    error.move_refusal().unwrap_or_else(|| panic!("no move refusal: {error}"))
}

fn move_to(cloud: &FakeAutoCloud, request: &MoveRequest) -> SessionView {
    ready(cloud.move_(CHAT, request)).expect("moved")
}

fn give(cloud: &FakeAutoCloud, holder: &Holder, epoch: u64) -> CloudResult<SessionView> {
    ready(cloud.give(CHAT, &Fence::new(holder.clone(), epoch)))
}

/// The laptop's chat with one event and a snapshot that covers it, so a machine can import it.
fn copied() -> (FakeAutoCloud, FakeAutoCloud) {
    let (owner, machine) = store();
    assert_eq!(append_as(&owner, &mac(), 1, 1..=1), Ok(1));
    assert_eq!(snapshot_as(&owner, &mac(), 1, b"the folder", 1), Ok(1));
    (owner, machine)
}

#[test]
fn a_move_to_the_cloud_in_the_middle_of_the_laptops_lease() {
    let (owner, machine) = store();
    renew(&owner, &mac(), 1, true);
    assert_eq!(append_as(&owner, &mac(), 1, 1..=2), Ok(2));
    owner.advance(7_000);
    let before = chat(&owner);

    // One write: the wish, and the chat kept in the Cloud. The laptop still holds it, and the
    // machine is started so it is up when the laptop gives the chat.
    let view = move_to(&owner, &MoveRequest::cloud());
    assert_eq!(view.moving, Some(MoveWish { to: MoveTo::Cloud, device: None, at: 7_000 }));
    assert!(view.keep_in_cloud);
    assert_eq!((view.holder.clone(), view.epoch, view.state), (mac(), 1, State::Local));
    assert_eq!(view.version, before.version + 1);
    assert_eq!(owner.machine_starts(), [VM]);

    // The laptop reads the wish at its next renewal.
    let answer = renew(&owner, &mac(), 1, true);
    assert_eq!((answer.role, answer.move_to), (Role::Holder, Some(MoveTo::Cloud)));

    // The chat never changes hands ahead of its copy.
    assert_eq!(refusal(give(&owner, &mac(), 1)), MoveRefusal::NotCopied);
    assert_eq!(snapshot_as(&owner, &mac(), 1, b"the folder", 1), Ok(1));
    assert_eq!(refusal(give(&owner, &mac(), 1)), MoveRefusal::NotCopied);
    assert_eq!(snapshot_as(&owner, &mac(), 1, b"the folder, later", 2), Ok(2));

    let given = give(&owner, &mac(), 1).expect("given");
    assert_eq!((given.holder.clone(), given.epoch, given.state), (vm(), 2, State::Resuming));
    assert_eq!((given.moving, given.keep_in_cloud), (None, true));
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);
    assert_eq!(owner.machine_starts(), [VM, VM]);

    // The laptop lost the chat, and its give is over. The machine was asked for nothing.
    assert_eq!(renew(&owner, &mac(), 1, true).role, Role::Lost);
    assert_eq!(code(give(&owner, &mac(), 1)), ErrorCode::StaleEpoch);
    assert_eq!(refusal(give(&machine, &vm(), 2)), MoveRefusal::NoMove);
    assert_eq!(owner.calls().iter().filter(|route| **route == "move").count(), 1);
    assert_eq!(owner.calls().iter().filter(|route| **route == "give").count(), 5);
}

#[test]
fn a_move_to_a_laptop_while_a_machine_holds_the_chat() {
    let (owner, machine) = taken_over();
    ready(owner.keep(CHAT, true)).expect("kept");
    let starts = owner.machine_starts().len();

    // A laptop has to stand by: the one named, or any.
    assert_eq!(refusal(ready(owner.move_(CHAT, &MoveRequest::local()))), MoveRefusal::NoLaptop);
    assert_eq!(stand_by(&owner, &mac(), 1).role, Role::Standby);
    let other = MoveRequest::laptop(mac2());
    assert_eq!(refusal(ready(owner.move_(CHAT, &other))), MoveRefusal::NoLaptop);

    // The wish, and the chat no longer kept in the Cloud. The machine is started: it may be
    // paused, and it has to read the wish.
    let view = move_to(&owner, &MoveRequest::laptop(mac()));
    let wish = MoveWish { to: MoveTo::Local, device: Some(mac()), at: owner.now() };
    assert_eq!((view.moving, view.keep_in_cloud), (Some(wish), false));
    assert_eq!((view.holder.clone(), view.epoch), (vm(), 2));
    assert_eq!(owner.machine_starts().len(), starts + 1);

    // Only the holder is told to give: a standby's answer has no `move`.
    assert_eq!(stand_by(&owner, &mac(), 1).move_to, None);
    let answer = renew(&machine, &vm(), 2, true);
    assert_eq!((answer.role, answer.move_to), (Role::Holder, Some(MoveTo::Local)));

    assert_eq!(append_as(&machine, &vm(), 2, 1..=1), Ok(1));
    assert_eq!(refusal(give(&machine, &vm(), 2)), MoveRefusal::NotCopied);
    assert_eq!(snapshot_as(&machine, &vm(), 2, b"the folder", 1), Ok(1));

    // The laptop gets the chat with what the machine stopped still to run, and imports first.
    let given = give(&machine, &vm(), 2).expect("given");
    assert_eq!((given.holder.clone(), given.epoch, given.state), (mac(), 3, State::Local));
    assert_eq!((given.moving, given.needs_run), (None, true));
    assert_eq!(renew(&machine, &vm(), 2, true).role, Role::Lost);
    let home = stand_by(&owner, &mac(), 1);
    assert_eq!((home.role, home.session.epoch, home.move_to), (Role::Holder, 3, None));
    let off = PutRequest { auto: false, ..put_request("mac") };
    assert_eq!(code(ready(owner.put(CHAT, &off))), ErrorCode::HeldInCloud);
}

#[test]
fn a_laptop_that_stopped_standing_by_is_not_given_the_chat() {
    let (owner, machine) = taken_over();
    stand_by(&owner, &mac(), 1);
    move_to(&owner, &MoveRequest::local());
    assert_eq!(append_as(&machine, &vm(), 2, 1..=1), Ok(1));
    assert_eq!(snapshot_as(&machine, &vm(), 2, b"the folder", 1), Ok(1));
    // The laptop's standby lapses while the machine works on its copy.
    owner.advance(LEASE_MS);
    assert_eq!(refusal(give(&machine, &vm(), 2)), MoveRefusal::NoLaptop);
    assert_eq!(chat(&owner).holder, vm());
}

#[test]
fn a_parked_chat_moves_at_once_each_way() {
    // To the Cloud: only with a snapshot for the machine to import.
    let (owner, _machine) = store();
    owner.advance(LEASE_MS);
    assert_eq!((chat(&owner).holder, chat(&owner).epoch), (Holder::Parked, 2));
    assert_eq!(refusal(ready(owner.move_(CHAT, &MoveRequest::cloud()))), MoveRefusal::NotCopied);

    let (owner, machine) = copied();
    owner.advance(LEASE_MS);
    let view = move_to(&owner, &MoveRequest::cloud());
    assert_eq!((view.holder.clone(), view.epoch, view.state), (vm(), 3, State::Resuming));
    assert_eq!((view.moving, view.keep_in_cloud), (None, true));
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);

    // To a laptop that stands by. Another laptop than the one it was parked from imports the
    // Cloud copy first.
    let (owner, _machine) = store();
    ready(owner.keep(CHAT, true)).expect("kept");
    owner.advance(LEASE_MS);
    assert_eq!(refusal(ready(owner.move_(CHAT, &MoveRequest::local()))), MoveRefusal::NoLaptop);
    assert_eq!(stand_by(&owner, &mac2(), 0).role, Role::Standby);
    let view = move_to(&owner, &MoveRequest::local());
    assert_eq!((view.holder.clone(), view.epoch, view.state), (mac2(), 3, State::Local));
    assert_eq!((view.moving, view.keep_in_cloud, view.needs_run), (None, false, false));
    let off = PutRequest { auto: false, ..put_request("mac2") };
    assert_eq!(code(ready(owner.put(CHAT, &off))), ErrorCode::HeldInCloud);

    // The laptop it was parked from takes it as it is: nobody ran it since.
    let (owner, _machine) = store();
    ready(owner.keep(CHAT, true)).expect("kept");
    owner.advance(LEASE_MS);
    assert_eq!(stand_by(&owner, &mac(), 1).role, Role::Standby);
    let view = move_to(&owner, &MoveRequest::laptop(mac()));
    assert_eq!((view.holder.clone(), view.epoch), (mac(), 3));
    let off = PutRequest { auto: false, ..put_request("mac") };
    assert!(!ready(owner.put(CHAT, &off)).expect("closed").auto);
}

#[test]
fn a_parked_chat_kept_in_the_cloud_is_not_taken_back_by_its_laptop() {
    let (owner, machine) = copied();
    ready(owner.keep(CHAT, true)).expect("kept");
    owner.advance(LEASE_MS);
    assert_eq!(chat(&owner).holder, Holder::Parked);

    // Neither its renewal at the epoch it held nor its registration takes the chat back.
    assert_eq!(renew(&owner, &mac(), 1, false).role, Role::Lost);
    let put = ready(owner.put(CHAT, &put_request("mac"))).expect("answered");
    assert_eq!((put.holder, put.epoch), (Holder::Parked, 2));
    // Work goes to the Auto machine.
    send(&owner, "m1", "go on");
    assert_eq!((chat(&owner).holder, chat(&owner).state), (vm(), State::Resuming));
    assert_eq!(kinds(&machine), [AssignmentKind::Takeover]);

    // With no snapshot the laptop has the only chat there is: it takes it back.
    let (owner, _machine) = store();
    ready(owner.keep(CHAT, true)).expect("kept");
    owner.advance(LEASE_MS);
    let back = renew(&owner, &mac(), 1, false);
    assert_eq!((back.role, back.session.epoch), (Role::Holder, 3));

    // A chat that is not kept in the Cloud goes back to its laptop, snapshot or not.
    let (owner, _machine) = copied();
    owner.advance(LEASE_MS);
    assert_eq!(renew(&owner, &mac(), 1, false).role, Role::Holder);
}

#[test]
fn a_wish_ends_with_any_other_change_of_holder_and_when_it_is_asked_back() {
    // The laptop's lease runs out with work: the chat goes to the machine by the lease rules.
    let (owner, _machine) = store();
    renew(&owner, &mac(), 1, true);
    move_to(&owner, &MoveRequest::cloud());
    owner.advance(LEASE_MS);
    let view = chat(&owner);
    assert_eq!((view.holder.clone(), view.epoch, view.moving), (vm(), 2, None));

    // The person asks for it back before the laptop gave it: the chat is where they want it.
    let (owner, _machine) = store();
    let before = move_to(&owner, &MoveRequest::cloud());
    let view = move_to(&owner, &MoveRequest::local());
    assert_eq!((view.moving, view.keep_in_cloud, view.epoch), (None, false, 1));
    assert_eq!(view.version, before.version + 1);
    assert_eq!(refusal(give(&owner, &mac(), 1)), MoveRefusal::NoMove);
    // Asked again, nothing changes.
    assert_eq!(move_to(&owner, &MoveRequest::local()).version, view.version);
}

#[test]
fn a_wish_its_holder_does_not_act_on_ends_after_move_ms() {
    let (owner, _machine) = copied();
    move_to(&owner, &MoveRequest::cloud());
    for _ in 0..3 {
        owner.advance(MOVE_MS / 4);
        assert_eq!(renew(&owner, &mac(), 1, false).move_to, Some(MoveTo::Cloud));
    }
    owner.advance(MOVE_MS / 4);
    let answer = renew(&owner, &mac(), 1, false);
    assert_eq!((answer.role, answer.move_to), (Role::Holder, None));
    // The chat stays where it is, in the mode the person chose.
    let view = answer.session;
    assert_eq!((view.holder.clone(), view.epoch, view.moving), (mac(), 1, None));
    assert!(view.keep_in_cloud);
    assert_eq!(refusal(give(&owner, &mac(), 1)), MoveRefusal::NoMove);
}

#[test]
fn a_move_is_the_owners_and_names_a_laptop_only_to_go_local() {
    let (owner, machine) = store();
    let to_cloud_with_laptop = MoveRequest { to: MoveTo::Cloud, device: Some(mac()) };
    assert_eq!(status(ready(owner.move_(CHAT, &to_cloud_with_laptop))), Some(400));
    for no_laptop in [vm(), Holder::Parked, Holder::device("no laptop")] {
        let request = MoveRequest::laptop(no_laptop);
        assert_eq!(status(ready(owner.move_(CHAT, &request))), Some(400));
    }
    assert_eq!(status(ready(machine.move_(CHAT, &MoveRequest::local()))), Some(403));
    assert_eq!(status(ready(owner.move_("no_chat", &MoveRequest::cloud()))), Some(404));
    assert_eq!(status(ready(owner.give(CHAT, &Fence::new(Holder::Parked, 1)))), Some(400));
    assert_eq!(code(give(&owner, &mac2(), 1)), ErrorCode::NotHolder);
    assert_eq!(chat(&owner).version, 1);

    // A chat that is not an Auto chat does not move.
    let off = PutRequest { auto: false, ..put_request("mac") };
    ready(owner.put(CHAT, &off)).expect("closed");
    assert_eq!(refusal(ready(owner.move_(CHAT, &MoveRequest::cloud()))), MoveRefusal::Off);
    assert_eq!(refusal(ready(owner.move_(CHAT, &MoveRequest::local()))), MoveRefusal::Off);

    // With no Auto machine there is nowhere in the Cloud to go.
    let alone = FakeAutoCloud::new();
    ready(alone.put(CHAT, &put_request("mac"))).expect("the chat");
    assert_eq!(code(ready(alone.move_(CHAT, &MoveRequest::cloud()))), ErrorCode::NoMachine);
}

#[test]
fn a_chat_started_with_no_laptop_can_be_made_in_cloud_mode() {
    let owner = FakeAutoCloud::new();
    ready(owner.set_machine(&machine_setting())).expect("the Auto machine");
    let request = |id: &str| CreateRequest {
        title: None,
        harness: "claude".into(),
        repo: Repo { remote: "git@example.com:a/b.git".into(), branch: "main".into() },
        first_message: FirstMessage { id: id.into(), text: "go".into() },
    };
    let kept = owner.create_kept(&request("first"), true).expect("made");
    assert_eq!((kept.holder.clone(), kept.keep_in_cloud), (vm(), true));
    let plain = ready(owner.create(&request("second"))).expect("made");
    assert_eq!((plain.holder.clone(), plain.keep_in_cloud), (vm(), false));
    // The same request again is the chat the first made, as it is.
    assert_eq!(owner.create_kept(&request("first"), false).expect("the same chat").id, kept.id);
    assert!(owner.peek(&kept.id).expect("the chat").keep_in_cloud);
}
