//! The RFD 0170 phase 0 flows end to end over the fake backends.

mod common;

use cmux_forum_hosted::model as wire;
use cmux_sync::presence::{Activity, Beat, DeviceKind, Kind, Member};

use cmux_team_messaging::backend::{Room, RoomRole};
use cmux_team_messaging::fake::{FakeForum, FakePresence, FakeRooms};
use cmux_team_messaging::model::Notify;
use cmux_team_messaging::{
    Bridge, Capability, DeliveryMode, Draft, ForumBackend, Grants, IdentityError, LinkGraph,
    Messenger, PresenceBackend, PrincipalKind, RefKind, RefSource, RoomBackend, RootKind, Route,
    SendError, StableRef, ThreadState, forum, refs::RefKey,
};

use common::*;

fn draft(audience: &[&str], mode: DeliveryMode, key: &str) -> Draft {
    Draft {
        thread_id: "space-1/1".to_owned(),
        body: "Can you look at the failing check?".to_owned(),
        audience: audience.iter().map(|a| (*a).to_owned()).collect(),
        mode,
        refs: vec![StableRef::rfd(170, "Native team messaging")],
        reply_to: None,
        idempotency_key: key.to_owned(),
        created_at: 10,
    }
}

fn messenger(space: cmux_team_messaging::Space) -> Messenger<FakeForum> {
    let forum = FakeForum::new();
    forum.put_thread(thread("space-1/1")).unwrap();
    let principals = vec![
        person("alice", Grants::all()),
        person("bob", Grants::all()),
        agent("bobs-agent", "bob", Grants::all()),
        agent("alices-agent", "alice", Grants::of(&[Capability::Read])),
        person("carol", Grants::all()),
    ];
    Messenger::new(forum, principals, vec![team(Grants::all())], vec![space])
}

#[test]
fn person_to_person_never_wakes_an_agent() {
    let m = messenger(space(&["alice", "bob", "bobs-agent"]));
    let alice = person("alice", Grants::all());
    let p = m.preview(&alice, &draft(&["@bob"], DeliveryMode::Wake, "k1")).unwrap();
    assert_eq!(p.recipients.len(), 1);
    assert_eq!(p.recipients[0].route, Route::Inbox);
    assert!(p.wakes().is_empty());
}

#[test]
fn wake_needs_the_owners_grant_in_this_space() {
    let mut s = space(&["alice", "bob", "bobs-agent"]);
    let alice = person("alice", Grants::all());

    // No grant: the wake lands in the agent's digest and the preview says so.
    let m = messenger(s.clone());
    let p = m.preview(&alice, &draft(&["@bobs-agent"], DeliveryMode::Wake, "k1")).unwrap();
    assert_eq!(p.recipients[0].route, Route::AgentDigest);
    assert!(p.recipients[0].wake_downgraded);

    // Someone other than the owner granting it does not count.
    grant_wake(&mut s, "bobs-agent", "alice");
    let m = messenger(s.clone());
    let p = m.preview(&alice, &draft(&["@bobs-agent"], DeliveryMode::Wake, "k1")).unwrap();
    assert!(p.wakes().is_empty());

    // The owner's grant wakes it.
    grant_wake(&mut s, "bobs-agent", "bob");
    let m = messenger(s);
    let p = m.preview(&alice, &draft(&["@bobs-agent"], DeliveryMode::Wake, "k1")).unwrap();
    assert_eq!(p.wakes(), vec!["bobs-agent"]);
    let fyi = m.preview(&alice, &draft(&["@bobs-agent"], DeliveryMode::Fyi, "k2")).unwrap();
    assert_eq!(fyi.recipients[0].route, Route::Store);
}

#[test]
fn notification_policy_sets_a_persons_route() {
    let mut s = space(&["alice", "bob"]);
    set_notify(&mut s, "bob", Notify::Digest);
    let m = messenger(s);
    let p = m
        .preview(&person("alice", Grants::all()), &draft(&["bob"], DeliveryMode::Ask, "k"))
        .unwrap();
    assert_eq!(p.recipients[0].route, Route::PersonDigest);
}

#[test]
fn a_recipient_outside_the_space_is_refused_not_added() {
    let m = messenger(space(&["alice", "bob"]));
    let err = m
        .preview(&person("alice", Grants::all()), &draft(&["@carol"], DeliveryMode::Ask, "k"))
        .unwrap_err();
    assert!(
        matches!(err, SendError::RecipientCannotRead { ref recipient, .. } if recipient == "carol")
    );
    assert_eq!(m.forum().stored_count(), 0);
}

#[test]
fn unknown_and_ambiguous_handles_are_refused() {
    let m = messenger(space(&["alice", "bob"]));
    let alice = person("alice", Grants::all());
    assert!(matches!(
        m.preview(&alice, &draft(&["@nobody"], DeliveryMode::Ask, "k")),
        Err(SendError::UnknownRecipient(h)) if h == "nobody"
    ));

    let forum = FakeForum::new();
    forum.put_thread(thread("space-1/1")).unwrap();
    let mut twin = person("bob-2", Grants::all());
    twin.handle = "bob".to_owned();
    let m = Messenger::new(
        forum,
        vec![alice.clone(), person("bob", Grants::all()), twin],
        vec![team(Grants::all())],
        vec![space(&["alice", "bob", "bob-2"])],
    );
    assert!(matches!(
        m.preview(&alice, &draft(&["@bob"], DeliveryMode::Ask, "k")),
        Err(SendError::AmbiguousRecipient { .. })
    ));
}

#[test]
fn an_agent_posts_as_itself_bounded_by_its_owner() {
    let m = messenger(space(&["alice", "bob", "bobs-agent"]));
    let a = agent("bobs-agent", "bob", Grants::all());
    let r = m.send(&a, &draft(&["@alice"], DeliveryMode::Ask, "k1")).unwrap();
    let stored = m.forum().messages("space-1/1", 0).unwrap();
    assert_eq!(stored[0].message.author.id, "bobs-agent");
    assert_eq!(stored[0].message.author.kind, PrincipalKind::Agent);
    assert_eq!(stored[0].message.author.owner_person_id.as_deref(), Some("bob"));
    assert_eq!(r.seq, 1);

    // An agent whose owner is not in the space gets nothing there, even as a member.
    let m = messenger(space(&["bob", "alices-agent"]));
    let a = agent("alices-agent", "alice", Grants::all());
    assert!(matches!(
        m.send(&a, &draft(&["@bob"], DeliveryMode::Ask, "k")),
        Err(SendError::CannotPost { .. })
    ));

    // An agent with only Read cannot post, whatever its owner holds.
    let m = messenger(space(&["alice", "bob", "alices-agent"]));
    let a = agent("alices-agent", "alice", Grants::of(&[Capability::Read]));
    assert!(matches!(
        m.send(&a, &draft(&["@bob"], DeliveryMode::Ask, "k")),
        Err(SendError::CannotPost { .. })
    ));
}

#[test]
fn an_agent_credential_cannot_write_as_its_owner() {
    let m = messenger(space(&["alice", "bob", "bobs-agent"]));
    let mut caller = agent("bobs-agent", "bob", Grants::all());
    caller.id = "bobs-agent".to_owned();
    let owner = person("bob", Grants::all());
    assert!(matches!(
        cmux_team_messaging::identity::check_author(&owner, &caller),
        Err(IdentityError::AgentAsOwner { .. })
    ));
    // And the messenger always writes the caller's own record.
    m.send(&caller, &draft(&["@alice"], DeliveryMode::Fyi, "k")).unwrap();
    assert_eq!(m.forum().messages("space-1/1", 0).unwrap()[0].message.author.id, "bobs-agent");
}

#[test]
fn a_bridge_author_cannot_send_or_wake() {
    let mut s = space(&["alice", "bob", "bobs-agent", "slack-dana"]);
    grant_wake(&mut s, "bobs-agent", "bob");
    let m = messenger(s);
    let dana = bridged("slack-dana", Bridge::Slack);
    assert!(matches!(
        m.send(&dana, &draft(&["@bobs-agent"], DeliveryMode::Wake, "k")),
        Err(SendError::Identity(IdentityError::BridgeHasNoRights { .. }))
    ));
    let r = cmux_team_messaging::route(
        DeliveryMode::Wake,
        &dana,
        &agent("bobs-agent", "bob", Grants::all()),
        true,
        Notify::Inbox,
    );
    assert_eq!(r, Route::AgentDigest);
}

#[test]
fn a_retry_after_an_outage_is_one_message() {
    let m = messenger(space(&["alice", "bob"]));
    let alice = person("alice", Grants::all());
    m.forum().fail_next(1);
    let d = draft(&["@bob"], DeliveryMode::Ask, "draft-7");
    assert!(matches!(m.send(&alice, &d), Err(SendError::Backend(_))));
    let first = m.send(&alice, &d).unwrap();
    let again = m.send(&alice, &d).unwrap();
    assert!(!first.duplicate && again.duplicate);
    assert_eq!(first.message_id, again.message_id);
    assert_eq!(m.forum().stored_count(), 1);
}

#[test]
fn empty_body_and_unknown_thread_are_refused() {
    let m = messenger(space(&["alice", "bob"]));
    let alice = person("alice", Grants::all());
    let mut d = draft(&["@bob"], DeliveryMode::Ask, "k");
    d.body = "  ".to_owned();
    assert_eq!(m.preview(&alice, &d), Err(SendError::EmptyBody));
    let mut d = draft(&["@bob"], DeliveryMode::Ask, "k");
    d.thread_id = "space-1/9".to_owned();
    assert_eq!(m.preview(&alice, &d), Err(SendError::UnknownThread("space-1/9".to_owned())));
}

#[test]
fn rfd_session_and_thread_links_read_from_every_end() {
    let rfd = StableRef::rfd(170, "Native team messaging").key;
    let session = RefKey::new(RefKind::Session, RefSource::Cmux, "sess-42").unwrap();
    let th = forum::thread_key("space-1", 1);
    let mut g = LinkGraph::new();
    assert!(g.link(&rfd, &th));
    assert!(g.link(&session, &th));
    assert!(g.link(&rfd, &session));
    assert!(!g.link(&th, &rfd), "a link is made once");
    assert_eq!(g.links_of_kind(&th, RefKind::Rfd), vec![rfd.clone()]);
    assert_eq!(g.links_of_kind(&rfd, RefKind::Session), vec![session.clone()]);
    assert_eq!(g.links_of_kind(&session, RefKind::Thread), vec![th.clone()]);
    // A viewer who cannot read the session does not learn of it from the RFD.
    let visible = g.visible_links(&rfd, |k| k.kind != RefKind::Session);
    assert_eq!(visible, vec![th]);
}

#[test]
fn forum_wire_types_map_without_widening() {
    let author = wire::Author {
        kind: wire::AuthorKind::Agent,
        id: "bobs-agent".to_owned(),
        name: "bobs-agent".to_owned(),
        org: None,
        on_behalf_of: Some("bob".to_owned()),
        session: Some("sess-42".to_owned()),
        host: Some("cmux16".to_owned()),
    };
    let p = forum::principal(&author, TEAM, Grants::all(), None).unwrap();
    assert_eq!(p.kind, PrincipalKind::Agent);
    assert_eq!(p.owner_person_id.as_deref(), Some("bob"));
    assert_eq!(p.session_id.as_deref(), Some("sess-42"));

    let via = forum::principal(&author, TEAM, Grants::all(), Some(Bridge::Slack)).unwrap();
    assert!(via.capabilities.is_empty());

    let anon = wire::Author { kind: wire::AuthorKind::Anonymous, ..author.clone() };
    assert!(forum::principal(&anon, TEAM, Grants::all(), None).is_none());

    let t = wire::Thread {
        number: 7,
        title: "Why is CI red".to_owned(),
        state: wire::ThreadState::Closed,
        labels: vec![
            wire::Label { name: "bug".to_owned() },
            wire::Label { name: "ask".to_owned() },
        ],
        author: author.clone(),
        space: "space-1".to_owned(),
        ..Default::default()
    };
    let mt = forum::thread(&t);
    assert_eq!(mt.id, "space-1/7");
    assert_eq!(mt.root_kind, RootKind::Ask);
    assert_eq!(mt.state, ThreadState::Closed);

    let c = wire::Comment {
        id: 3,
        body: "Looking".to_owned(),
        author,
        thread: 7,
        ..Default::default()
    };
    let msg = forum::message(&c, "space-1", p);
    assert_eq!(msg.thread_id, "space-1/7");
    assert_eq!(msg.delivery, DeliveryMode::Fyi);

    let e = wire::FeedEvent { origin: Some("slack".to_owned()), ..Default::default() };
    assert_eq!(forum::event_bridge(&e), Some(Bridge::Slack));
    assert_eq!(forum::event_bridge(&wire::FeedEvent::default()), None);
}

#[test]
fn presence_and_rooms_read_through_the_fakes() {
    let presence = FakePresence::new();
    presence.beat(
        Beat {
            member: Member {
                id: "bobs-agent".to_owned(),
                name: "Bob's agent".to_owned(),
                kind: Kind::Agent,
            },
            device: "vm-1".to_owned(),
            device_kind: DeviceKind::Vm,
            seq: 1,
            activity: Activity::Working,
            idle_ms: 0,
            scopes: vec!["space-1".to_owned()],
        },
        1_000,
    );
    let here = presence.here("space-1", 1_000);
    assert_eq!(here.len(), 1);
    assert_eq!(here[0].principal_id, "bobs-agent");
    assert_eq!(here[0].kind, PrincipalKind::Agent);
    assert!(here[0].working);
    assert!(presence.here("elsewhere", 1_000).is_empty());

    let rooms = FakeRooms::new();
    rooms.put(Room {
        session_id: "sess-42".to_owned(),
        owner_id: "bob".to_owned(),
        members: vec![("alice".to_owned(), RoomRole::View)],
    });
    assert_eq!(rooms.room("sess-42").unwrap().members[0].1, RoomRole::View);
    assert!(rooms.room("sess-9").is_err());
}

#[test]
fn records_round_trip_as_json() {
    let p = agent("bobs-agent", "bob", Grants::of(&[Capability::Read, Capability::Post]));
    let back: cmux_team_messaging::Principal =
        serde_json::from_str(&serde_json::to_string(&p).unwrap()).unwrap();
    assert_eq!(back, p);
    let r = StableRef::rfd(170, "x");
    let back: StableRef = serde_json::from_str(&serde_json::to_string(&r).unwrap()).unwrap();
    assert_eq!(back, r);
}
