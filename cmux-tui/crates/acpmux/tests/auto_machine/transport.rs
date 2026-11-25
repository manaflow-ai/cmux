//! The machine's transport: every route a Cloud machine may call goes through the agent's
//! socket and comes back as the store answered it; the owner's routes never leave the daemon.

use acpmux::auto_session::machine::MachineCloud;
use cmux_auto_session::chunks::name_of;
use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::wire::{
    AssignmentKind, ErrorCode, EventsAppend, Fence, InboxAck, InboxPost, LeaseRequest,
    MachineSetting, Role, SnapshotPost,
};

use super::agent::FakeAgent;
use super::{CHAT, VM, folder_manifest, laptop_copy, laptop_goes_away, record, store, vm};

#[tokio::test]
async fn a_machine_takes_a_chat_over_and_works_on_it_through_the_agent() {
    let owner = store().await;
    let folder = b"the laptop's folder".to_vec();
    let chunk = laptop_copy(&owner, 3, &folder).await;
    laptop_goes_away(&owner);
    let agent = FakeAgent::start(&owner, VM);
    let cloud = agent.cloud();

    // Who this machine is, and what it is asked to do.
    assert_eq!(cloud.holder().await.unwrap(), vm());
    let assigned = cloud.assignments(25_000).await.unwrap();
    assert_eq!(assigned.len(), 1);
    assert_eq!(assigned[0].kind, AssignmentKind::Takeover);
    assert_eq!((assigned[0].session.id.as_str(), assigned[0].session.epoch), (CHAT, 2));
    assert_eq!(cloud.get(CHAT).await.unwrap().holder, vm());

    // The copy the laptop left.
    let page = cloud.events(CHAT, 0, None).await.unwrap();
    assert_eq!(page.events, (1..=3).map(record).collect::<Vec<_>>());
    assert_eq!(cloud.events(CHAT, 2, Some(1)).await.unwrap().events, vec![record(3)]);
    let snapshot = cloud.snapshot(CHAT).await.unwrap();
    assert_eq!(snapshot.manifest, folder_manifest(std::slice::from_ref(&chunk), 3));
    assert_eq!(cloud.chunk(CHAT, &chunk).await.unwrap(), folder);

    // It acks, renews, and reads a message sent meanwhile.
    let fence = Fence::new(vm(), 2);
    cloud.ack_assignment(CHAT, &fence).await.unwrap();
    assert!(cloud.assignments(0).await.unwrap().is_empty());
    let renew = LeaseRequest { holder: vm(), epoch: 2, needs_run: true, standby: None };
    assert_eq!(cloud.lease(CHAT, &renew).await.unwrap().role, Role::Holder);
    let message = InboxPost { id: "m1".into(), text: "also fix the tests".into() };
    owner.post_inbox(CHAT, &message).await.unwrap();
    let inbox = cloud.inbox(CHAT, 0).await.unwrap();
    assert_eq!(inbox.len(), 1);
    assert_eq!((inbox[0].id.as_str(), inbox[0].text.as_str()), ("m1", "also fix the tests"));
    let ack = InboxAck { holder: vm(), epoch: 2, through: inbox[0].n };
    assert!(!cloud.ack_inbox(CHAT, &ack).await.unwrap().inbox_pending());

    // Its own work goes back into the copy: events, a chunk of every byte value, a snapshot.
    let events = EventsAppend { holder: vm(), epoch: 2, events: vec![record(4), record(5)] };
    assert_eq!(cloud.append_events(CHAT, &events).await.unwrap(), 5);
    let work: Vec<u8> = (0..=255u8).cycle().take(300_000).collect();
    let name = name_of(&work);
    cloud.put_chunk(CHAT, &name, &work, &fence).await.unwrap();
    let manifest = folder_manifest(std::slice::from_ref(&name), 5);
    let post = SnapshotPost { holder: vm(), epoch: 2, manifest: manifest.clone() };
    let number = cloud.post_snapshot(CHAT, &post).await.unwrap();
    assert!(number > snapshot.snapshot);
    assert_eq!(owner.snapshot(CHAT).await.unwrap().manifest, manifest);
    assert_eq!(owner.chunk(CHAT, &name).await.unwrap(), work);

    // And it may give the chat up.
    let released = cloud.release(CHAT, &fence).await.unwrap();
    assert_ne!(released.holder, vm());
}

#[tokio::test]
async fn the_stores_refusals_arrive_as_the_store_made_them() {
    let owner = store().await;
    laptop_copy(&owner, 3, b"folder").await;
    laptop_goes_away(&owner);
    let agent = FakeAgent::start(&owner, VM);
    let cloud = agent.cloud();

    // A write under the epoch the laptop had.
    let stale = EventsAppend { holder: vm(), epoch: 1, events: vec![record(4)] };
    let error = cloud.append_events(CHAT, &stale).await.unwrap_err();
    assert_eq!(error.code(), Some(ErrorCode::StaleEpoch), "{error}");
    assert_eq!(error.session().map(|session| session.epoch), Some(2));
    // A gap names the last event the store has.
    let gap = EventsAppend { holder: vm(), epoch: 2, events: vec![record(7)] };
    let error = cloud.append_events(CHAT, &gap).await.unwrap_err();
    assert_eq!(error.code(), Some(ErrorCode::SeqGap), "{error}");
    assert_eq!(error.last_seq(), Some(3));
    // A chunk whose bytes are not its name.
    let fence = Fence::new(vm(), 2);
    let error = cloud.put_chunk(CHAT, &name_of(b"one"), b"another", &fence).await.unwrap_err();
    assert_eq!(error.code(), Some(ErrorCode::ChunkMismatch), "{error}");
    // A chat this machine does not hold, and a chunk nobody stored.
    assert_eq!(cloud.get("chat_2").await.unwrap_err().status(), Some(404));
    assert_eq!(cloud.chunk(CHAT, &name_of(b"none")).await.unwrap_err().status(), Some(404));
}

#[tokio::test]
async fn the_owners_routes_are_refused_without_a_call() {
    let owner = store().await;
    laptop_goes_away(&owner);
    let agent = FakeAgent::start(&owner, VM);
    let cloud = agent.cloud();
    let setting = MachineSetting { team: "team_0123456789abcdef0123".into(), machine: VM.into() };
    let message = InboxPost { id: "m1".into(), text: "hello".into() };
    let refused = [
        cloud.machine().await.unwrap_err(),
        cloud.set_machine(&setting).await.unwrap_err(),
        cloud.list(None, None).await.unwrap_err(),
        cloud.wait(CHAT, 0, 0).await.unwrap_err(),
        cloud.post_inbox(CHAT, &message).await.unwrap_err(),
        cloud.keep(CHAT, true).await.unwrap_err(),
    ];
    for error in &refused {
        assert_eq!(error.status(), Some(403), "{error}");
        assert!(!error.retryable());
    }
    // The fake store refuses a machine the same way, so the two agree.
    let machine = owner.as_machine(VM);
    assert_eq!(machine.list(None, None).await.unwrap_err().status(), Some(403));
    assert_eq!(machine.keep(CHAT, true).await.unwrap_err().status(), Some(403));
    assert!(agent.calls().is_empty(), "{:?}", agent.calls());
}

#[tokio::test]
async fn an_agent_that_cannot_send_a_call_is_a_failure_to_try_again() {
    let owner = store().await;
    laptop_goes_away(&owner);
    let agent = FakeAgent::start(&owner, VM);
    let cloud = agent.cloud();
    for code in ["busy", "vm.unbound", "vm.agent_stopping", "auto.unreachable"] {
        agent.refuse_next(code);
        let error = cloud.get(CHAT).await.unwrap_err();
        assert!(error.is_transport() && error.retryable(), "{code}: {error}");
        assert!(error.to_string().contains(code), "{error}");
    }
    // A machine that resumed mid-wait has nothing to report yet; the next wait does.
    agent.refuse_next("auto.resumed");
    assert!(cloud.assignments(25_000).await.unwrap().is_empty());
    assert_eq!(cloud.assignments(25_000).await.unwrap().len(), 1);
    // The agent refuses a call it cannot read; that one is not worth trying again.
    let error = cloud.get("not a chat id").await.unwrap_err();
    assert_eq!(error.status(), Some(400), "{error}");
    // No agent at all (an image older than Auto mode), or one that went away.
    let nowhere = MachineCloud::new(agent.socket().with_file_name("nothing.sock"));
    assert!(!nowhere.present());
    assert!(nowhere.get(CHAT).await.unwrap_err().is_transport());
    assert!(nowhere.holder().await.unwrap_err().is_transport());
    assert!(cloud.present());
    drop(agent);
    assert!(cloud.get(CHAT).await.unwrap_err().is_transport());
}

#[tokio::test]
async fn a_held_wait_ends_when_a_chat_is_assigned_and_renewals_pass_it() {
    let owner = store().await;
    let agent = FakeAgent::start(&owner, VM);
    let cloud = agent.cloud();
    // Nothing is assigned yet: the wait is held.
    let waiting = tokio::spawn({
        let cloud = cloud.clone();
        async move { cloud.assignments(25_000).await }
    });
    // Other calls go through meanwhile; this machine holds no chat, so the store says 404.
    for _ in 0..3 {
        assert_eq!(cloud.get(CHAT).await.unwrap_err().status(), Some(404));
    }
    assert!(!waiting.is_finished());
    laptop_goes_away(&owner);
    let assigned = waiting.await.unwrap().unwrap();
    assert_eq!(assigned.len(), 1);
    assert_eq!(assigned[0].kind, AssignmentKind::Takeover);
}
