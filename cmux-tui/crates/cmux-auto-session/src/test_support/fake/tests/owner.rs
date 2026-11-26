//! The owner's routes: making, listing and closing chats.

use super::*;
use crate::consts::LEASE_MS;
use crate::wire::{CreateRequest, FirstMessage, Repo, Role, State};

fn repo() -> Repo {
    Repo { remote: "https://example.com/r.git".into(), branch: "main".into() }
}

fn off() -> PutRequest {
    PutRequest { auto: false, ..put_request("mac") }
}

#[test]
fn the_first_put_makes_the_chat_this_laptops_at_epoch_one() {
    let owner = FakeAutoCloud::new();
    owner.set_now(1_000);
    let request = PutRequest { repo: Some(repo()), ..put_request("mac") };
    let session = ready(owner.put(CHAT, &request)).expect("made");
    assert_eq!((session.holder.clone(), session.epoch, session.state), (mac(), 1, State::Local));
    assert!(session.auto && !session.keep_in_cloud && !session.needs_run);
    assert_eq!((session.title.as_str(), session.harness.as_str()), ("Fix the build", "claude"));
    assert_eq!((session.created_at, session.lease_expires_at), (1_000, 1_000 + LEASE_MS));
    assert_eq!((session.repo.clone(), session.team.clone()), (Some(repo()), None));
    assert_eq!(ready(owner.get(CHAT)), Ok(session.clone()));

    // A later put changes what the chat says, not who holds it.
    let renamed = PutRequest {
        title: " Fix the tests ".into(),
        keep_in_cloud: Some(true),
        ..put_request("other")
    };
    let again = ready(owner.put(CHAT, &renamed)).expect("changed");
    assert_eq!((again.holder.clone(), again.epoch), (mac(), 1));
    assert_eq!((again.title.as_str(), again.keep_in_cloud), ("Fix the tests", true));
    assert_eq!(again.repo, Some(repo()));
    assert!(again.version > session.version);
    // The same put again changes nothing a viewer could see.
    assert_eq!(ready(owner.put(CHAT, &renamed)).map(|same| same.version), Ok(again.version));

    assert_eq!(status(ready(owner.get("no_such_chat"))), Some(404));
    assert_eq!(status(ready(owner.put("no_such_chat", &off()))), Some(404));
}

#[test]
fn a_chat_started_with_no_laptop_goes_to_the_auto_machine() {
    let owner = FakeAutoCloud::new();
    let request = CreateRequest {
        title: Some("From the phone".into()),
        harness: "claude".into(),
        repo: repo(),
        first_message: FirstMessage { id: "m1".into(), text: "start here".into() },
    };
    let refused = ready(owner.create(&request)).expect_err("no machine");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::NoMachine), Some(409)));

    ready(owner.set_machine(&machine_setting())).expect("the Auto machine");
    let machine = owner.as_machine(VM);
    let session = ready(owner.create(&request)).expect("made");
    assert_eq!((session.holder.clone(), session.epoch, session.state), (vm(), 1, State::Resuming));
    assert_eq!((session.title.as_str(), session.repo.clone()), ("From the phone", Some(repo())));
    assert_eq!(
        (session.team.as_deref(), session.inbox, session.lease_expires_at),
        (Some(TEAM), 1, 0)
    );
    assert!(session.id.starts_with("as_") && session.id.len() == 23);
    assert_eq!(owner.machine_starts(), [VM]);

    let assignments = ready(machine.assignments(0)).expect("assignments");
    let created: Vec<(AssignmentKind, &str)> =
        assignments.iter().map(|a| (a.kind, a.session.id.as_str())).collect();
    assert_eq!(created, [(AssignmentKind::Create, session.id.as_str())]);
    // The first message is message 1 of the chat's inbox.
    let messages = ready(machine.inbox(&session.id, 0)).expect("the inbox");
    let first = messages.first().expect("the first message");
    assert_eq!((first.n, first.id.as_str(), first.text.as_str()), (1, "m1", "start here"));

    // The same request again (its answer was lost) reaches the chat it made.
    let again = ready(owner.create(&request)).expect("the same chat");
    assert_eq!((again.id.as_str(), again.inbox), (session.id.as_str(), 1));
    assert_eq!(owner.machine_starts(), [VM]);
    // Another first message is another chat.
    let first_message = FirstMessage { id: "m2".into(), text: "and this".into() };
    let other = ready(owner.create(&CreateRequest { first_message, ..request })).expect("made");
    assert_ne!(other.id, session.id);
}

#[test]
fn the_list_pages_newest_first_and_leaves_closed_chats_out() {
    let owner = FakeAutoCloud::new();
    for (at, id) in [(1, "c1"), (2, "c2"), (3, "c3"), (3, "c4"), (5, "c5")] {
        owner.set_now(at);
        ready(owner.put(id, &put_request("mac"))).expect("made");
    }
    let ids = |limit, cursor: Option<&str>| {
        let page = ready(owner.list(limit, cursor)).expect("a page");
        let ids: Vec<String> = page.sessions.into_iter().map(|session| session.id).collect();
        (ids.join(","), page.next_cursor)
    };
    let (first, next) = ids(Some(2), None);
    assert_eq!(first, "c5,c4");
    let (second, next) = ids(Some(2), next.as_deref());
    assert_eq!(second, "c3,c2");
    assert_eq!(ids(Some(2), next.as_deref()), ("c1".to_owned(), None));
    assert_eq!(ids(None, None), ("c5,c4,c3,c2,c1".to_owned(), None));
    assert_eq!(status(ready(owner.list(None, Some("nope")))), Some(400));

    ready(owner.put("c3", &off())).expect("closed");
    assert_eq!(ids(None, None).0, "c5,c4,c2,c1");
}

#[test]
fn switching_auto_off_closes_the_chat_and_drops_its_copy() {
    let (owner, _machine) = store();
    renew(&owner, &mac(), 1, true);
    assert_eq!(append_as(&owner, &mac(), 1, 1..=2), Ok(2));
    assert_eq!(snapshot_as(&owner, &mac(), 1, b"the folder", 2), Ok(1));
    let closed = ready(owner.put(CHAT, &off())).expect("closed");
    assert_eq!((closed.auto, closed.holder.clone(), closed.epoch), (false, Holder::Parked, 2));
    assert_eq!((closed.last_seq, closed.snapshot), (0, 0));
    // Closing again is the same answer.
    assert_eq!(ready(owner.put(CHAT, &off())).map(|again| again.version), Ok(closed.version));

    // A closed chat takes no renewal, no write and no message, and a wait on it answers.
    let lease = LeaseRequest { holder: mac(), epoch: 1, needs_run: true, standby: None };
    let refused = ready(owner.lease(CHAT, &lease)).expect_err("closed");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::Closed), Some(409)));
    assert_eq!(refused.session().map(|session| session.auto), Some(false));
    assert_eq!(code(append_as(&owner, &mac(), 1, 3..=3)), ErrorCode::Closed);
    let message = InboxPost { id: "m1".into(), text: "hello".into() };
    assert_eq!(code(ready(owner.post_inbox(CHAT, &message))), ErrorCode::Closed);
    assert_eq!(code(ready(owner.keep(CHAT, true))), ErrorCode::Closed);
    assert_eq!(ready(owner.wait(CHAT, closed.version, 25_000)), Ok(closed));

    // Its lease never goes to a machine.
    owner.advance(2 * LEASE_MS);
    assert!(owner.machine_starts().is_empty());

    // Auto on again: the chat is this laptop's, at a new epoch, with an empty copy.
    let on = ready(owner.put(CHAT, &put_request("mac"))).expect("on again");
    assert_eq!((on.auto, on.holder.clone(), on.epoch), (true, mac(), 3));
    assert!(ready(owner.events(CHAT, 0, None)).expect("a page").events.is_empty());
    assert_eq!(code(ready(owner.snapshot(CHAT))), ErrorCode::NoSnapshot);
    assert_eq!(append_as(&owner, &mac(), 3, 1..=1), Ok(1));
}

#[test]
fn a_chat_the_cloud_has_the_only_copy_of_cannot_be_closed() {
    let (owner, machine) = taken_over();
    let refused = ready(owner.put(CHAT, &off())).expect_err("held in the Cloud");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::HeldInCloud), Some(409)));

    // Parked after a machine ran it: the Cloud copy is still the only whole one.
    ready(machine.release(CHAT, &Fence::new(vm(), 2))).expect("released");
    assert_eq!(code(ready(owner.put(CHAT, &off()))), ErrorCode::HeldInCloud);
    assert!(chat(&owner).auto);

    // A laptop takes the chat first. Until it stored a copy of its own it has not shown it
    // imported the Cloud's, so Auto off still waits; then it turns Auto off.
    assert_eq!(stand_by(&owner, &mac(), 2).role, Role::Holder);
    assert_eq!(code(ready(owner.put(CHAT, &off()))), ErrorCode::HeldInCloud);
    snapshot_as(&owner, &mac(), 4, b"imported", 0).expect("stored");
    assert_eq!(ready(owner.put(CHAT, &off())).map(|closed| closed.auto), Ok(false));
}

/// A laptop that was handed the chat and lets its lease run out before it imported it leaves
/// the chat the Cloud's: it may not take it back as it is, and Auto off stays refused.
#[test]
fn a_laptop_that_never_imported_a_handed_back_chat_does_not_get_it_as_its_own() {
    let (owner, machine) = taken_over();
    assert_eq!(stand_by(&owner, &mac(), 1).role, Role::Standby);
    // The machine is idle with its copy stored: its renewal hands the chat back.
    snapshot_as(&machine, &vm(), 2, b"done", 0).expect("stored");
    assert_eq!(renew(&machine, &vm(), 2, false).role, Role::Lost);
    assert_eq!((chat(&owner).holder, chat(&owner).epoch), (mac(), 3));
    assert_eq!(code(ready(owner.put(CHAT, &off()))), ErrorCode::HeldInCloud);

    // The laptop goes away before its import: the chat is parked as the Cloud's.
    owner.advance(LEASE_MS);
    assert_eq!((chat(&owner).holder, chat(&owner).epoch), (Holder::Parked, 4));
    assert_eq!(code(ready(owner.put(CHAT, &off()))), ErrorCode::HeldInCloud);
    assert_eq!(renew(&owner, &mac(), 3, false).role, Role::Lost);
    assert_eq!(stand_by(&owner, &mac(), 3).role, Role::Holder);
    assert_eq!(code(ready(owner.put(CHAT, &off()))), ErrorCode::HeldInCloud);
    snapshot_as(&owner, &mac(), 5, b"imported", 0).expect("stored");
    assert_eq!(ready(owner.put(CHAT, &off())).map(|closed| closed.auto), Ok(false));
}

/// A registration sent again by the laptop that holds the chat is a renewal too: the lease
/// runs from it, so a laptop that reads its answer as the lease's is not past the lease.
#[test]
fn a_put_from_the_holder_renews_its_lease() {
    let (owner, _machine) = store();
    owner.advance(LEASE_MS - 5_000);
    let again = ready(owner.put(CHAT, &put_request("mac"))).expect("held");
    assert_eq!((again.holder.clone(), again.epoch), (mac(), 1));
    owner.advance(LEASE_MS - 5_000);
    assert_eq!((chat(&owner).holder, chat(&owner).epoch), (mac(), 1));
    owner.advance(5_000);
    assert_eq!((chat(&owner).holder, chat(&owner).epoch), (Holder::Parked, 2));
}
