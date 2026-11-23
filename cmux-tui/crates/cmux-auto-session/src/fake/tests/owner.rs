//! The owner's routes: making, listing and closing chats, and who may call what.

use super::*;
use crate::consts::LEASE_MS;
use crate::wire::{
    AssignmentKind, CreateRequest, EventsAppend, FirstMessage, InboxPost, Repo, State,
};

fn repo() -> Repo {
    Repo { remote: "https://example.com/r.git".into(), branch: "main".into() }
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
    assert_eq!(session.repo, Some(repo()));
    assert_eq!(ready(owner.get(CHAT)), Ok(session.clone()));

    // A later put changes what the chat says, not who holds it.
    let renamed = PutRequest {
        title: "Fix the tests".into(),
        keep_in_cloud: Some(true),
        ..put_request("other")
    };
    let again = ready(owner.put(CHAT, &renamed)).expect("changed");
    assert_eq!((again.holder.clone(), again.epoch), (mac(), 1));
    assert_eq!((again.title.as_str(), again.keep_in_cloud), ("Fix the tests", true));
    assert_eq!(again.repo, Some(repo()));
    assert!(again.version > session.version);

    assert_eq!(ready(owner.get("no_such_chat")).expect_err("unknown").status(), Some(404));
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
    assert_eq!(owner.machine_starts(), [VM]);

    let assignments = ready(machine.assignments(0)).expect("assignments");
    let created: Vec<(AssignmentKind, &str)> =
        assignments.iter().map(|a| (a.kind, a.session.id.as_str())).collect();
    assert_eq!(created, [(AssignmentKind::Create, session.id.as_str())]);
    // The first message is message 1 of the chat's inbox.
    let messages = ready(machine.inbox(&session.id, 0)).expect("the inbox");
    let first = messages.first().expect("the first message");
    assert_eq!((first.n, first.id.as_str(), first.text.as_str()), (1, "m1", "start here"));

    let other = ready(owner.create(&request)).expect("made");
    assert_ne!(other.id, session.id);
}

#[test]
fn the_list_pages_in_the_order_the_chats_were_made() {
    let owner = FakeAutoCloud::new();
    for id in ["c1", "c2", "c3", "c4", "c5"] {
        ready(owner.put(id, &put_request("mac"))).expect("made");
    }
    let ids = |limit, cursor: Option<&str>| {
        let page = ready(owner.list(limit, cursor)).expect("a page");
        let ids: Vec<String> = page.sessions.into_iter().map(|session| session.id).collect();
        (ids.join(","), page.next_cursor)
    };
    assert_eq!(ids(Some(2), None), ("c1,c2".to_owned(), Some("c2".to_owned())));
    assert_eq!(ids(Some(2), Some("c2")), ("c3,c4".to_owned(), Some("c4".to_owned())));
    assert_eq!(ids(Some(2), Some("c4")), ("c5".to_owned(), None));
    assert_eq!(ids(None, None), ("c1,c2,c3,c4,c5".to_owned(), None));
    assert_eq!(ready(owner.list(None, Some("nope"))).expect_err("no cursor").status(), Some(400));
}

#[test]
fn switching_auto_off_closes_the_chat() {
    let (owner, _machine) = store();
    renew(&owner, &mac(), 1, true);
    let off = PutRequest { auto: false, ..put_request("mac") };
    let closed = ready(owner.put(CHAT, &off)).expect("closed");
    assert!(!closed.auto);

    // A closed chat takes no renewal, no write and no message.
    let lease = LeaseRequest { holder: mac(), epoch: 1, needs_run: true, standby: None };
    let refused = ready(owner.lease(CHAT, &lease)).expect_err("closed");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::Closed), Some(410)));
    let events = EventsAppend { holder: mac(), epoch: 1, events: Vec::new() };
    assert_eq!(code(ready(owner.append_events(CHAT, &events))), ErrorCode::Closed);
    let message = InboxPost { id: "m1".into(), text: "hello".into() };
    assert_eq!(code(ready(owner.post_inbox(CHAT, &message))), ErrorCode::Closed);

    // Its lease never goes to a machine.
    owner.advance(2 * LEASE_MS);
    let session = chat(&owner);
    assert_eq!((session.holder.clone(), session.epoch, session.auto), (mac(), 1, false));
    assert!(owner.machine_starts().is_empty());

    // Auto on again: the chat is this laptop's, at a new epoch.
    let on = ready(owner.put(CHAT, &put_request("mac"))).expect("on again");
    assert_eq!((on.auto, on.holder.clone(), on.epoch), (true, mac(), 2));
}

#[test]
fn a_chat_a_machine_holds_cannot_be_closed() {
    let (owner, _machine) = taken_over();
    let off = PutRequest { auto: false, ..put_request("mac") };
    let refused = ready(owner.put(CHAT, &off)).expect_err("held in the Cloud");
    assert_eq!((refused.code(), refused.status()), (Some(ErrorCode::HeldInCloud), Some(409)));
    assert!(chat(&owner).auto);
}

#[test]
fn each_caller_has_its_routes() {
    let (owner, machine) = store();
    // A machine that is not the owner's Auto machine is not answered.
    let stranger = owner.as_machine("vm_other");
    assert_eq!(ready(stranger.get(CHAT)).expect_err("not bound").status(), Some(401));
    assert_eq!(ready(stranger.assignments(0)).expect_err("not bound").status(), Some(401));

    // The Auto machine reads a chat, and the owner's routes are not its own.
    assert_eq!(ready(machine.get(CHAT)).map(|session| session.id), Ok(CHAT.to_owned()));
    assert_eq!(
        ready(machine.put(CHAT, &put_request("mac"))).expect_err("owner's").status(),
        Some(403)
    );
    assert_eq!(ready(machine.list(None, None)).expect_err("owner's").status(), Some(403));
    assert_eq!(ready(machine.keep(CHAT, true)).expect_err("owner's").status(), Some(403));
    assert_eq!(ready(machine.machine()).expect_err("owner's").status(), Some(403));

    // A machine's routes are not the owner's.
    assert_eq!(ready(owner.assignments(0)).expect_err("a machine's").status(), Some(403));
    let ack = ready(owner.ack_assignment(CHAT, &Fence::new(mac(), 1)));
    assert_eq!(ack.expect_err("a machine's").status(), Some(403));
}
