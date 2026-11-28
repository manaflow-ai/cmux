//! RFD 0170 phase 3: a shared document's live room. Presence leases (RFD 0141), access requests
//! (RFD 0077 D2) and revoke cutting a live connection in the same step, plus an ignored bench at 20
//! participants.

mod common;

use std::time::Instant;

use proptest::prelude::*;

use cmux_team_messaging::doc_room::{
    DEFAULT_LEASE_MS, DisconnectReason, DocRoom, LeaveReason, MAX_CONNS_PER_PRINCIPAL,
    MAX_PENDING_REQUESTS, MAX_PEOPLE, RoomError, RoomEvent,
};
use cmux_team_messaging::model::DocRole;
use cmux_team_messaging::shared_doc::{
    Actor, DocKind, DocOp, DocState, DocUpdate, Scope, TextEdit,
};
use cmux_team_messaging::{
    Bridge, Capability, Grants, Principal, RefKind, RefSource, SharedDocument, Space, StableRef,
    Team,
};

use common::*;

fn doc(roles: &[(&str, DocRole)]) -> DocState {
    let d = SharedDocument {
        id: "doc-1".to_owned(),
        owner_ref: StableRef::new(RefKind::Thread, RefSource::Cmux, "thread-1", "Thread").unwrap(),
        thread_id: Some("thread-1".to_owned()),
        session_id: None,
        revision: 0,
        sync_cursor: 0,
        roles: roles.iter().map(|(p, r)| ((*p).to_owned(), *r)).collect(),
        presence_scope: "space-1".to_owned(),
    };
    DocState::new(d, "owner", DocKind::Shared, "hello".to_owned())
}

struct World {
    team: Team,
    space: Space,
}

impl World {
    fn new(members: &[&str]) -> Self {
        Self { team: team(Grants::all()), space: space(members) }
    }
    fn scope(&self) -> Scope<'_> {
        Scope { team: &self.team, space: &self.space }
    }
}

fn me(p: &Principal) -> Actor<'_> {
    Actor { principal: p, owner: None }
}

fn op(id: &str, actor: &str, op: DocOp) -> DocUpdate {
    DocUpdate { id: id.to_owned(), actor_id: actor.to_owned(), op }
}

fn revoke(id: &str, who: &str) -> DocUpdate {
    op(id, "owner", DocOp::Revoke { principal_id: who.to_owned() })
}

#[test]
fn join_needs_a_role_and_offers_a_request() {
    let w = World::new(&["owner", "a", "out"]);
    let d = doc(&[]);
    let mut room = DocRoom::new();
    let a = person("a", Grants::all());
    assert_eq!(
        room.join(&d, w.scope(), me(&a), "c1", DEFAULT_LEASE_MS, 0),
        Err(RoomError::NoAccess { can_request: true })
    );
    let slack = bridged("s", Bridge::Slack);
    assert_eq!(
        room.join(&d, w.scope(), me(&slack), "c2", DEFAULT_LEASE_MS, 0),
        Err(RoomError::NoAccess { can_request: false })
    );
    let stranger = person("x", Grants::all());
    assert_eq!(
        room.join(&d, w.scope(), me(&stranger), "c3", DEFAULT_LEASE_MS, 0),
        Err(RoomError::NoAccess { can_request: false })
    );
    let owner = person("owner", Grants::all());
    assert!(matches!(
        room.join(&d, w.scope(), me(&owner), "c4", DEFAULT_LEASE_MS, 0),
        Ok(RoomEvent::Joined { role: DocRole::Edit, .. })
    ));
    assert_eq!(room.people(), 1);
}

#[test]
fn lease_expires_once_and_renew_extends_it() {
    let w = World::new(&["owner", "a"]);
    let d = doc(&[("a", DocRole::View)]);
    let mut room = DocRoom::new();
    let a = person("a", Grants::all());
    room.join(&d, w.scope(), me(&a), "c1", DEFAULT_LEASE_MS, 0).unwrap();
    assert_eq!(room.next_deadline(), Some(30_000));
    assert!(room.expire(29_999).is_empty());
    room.renew("c1", 20_000).unwrap();
    assert!(room.expire(30_000).is_empty());
    let gone = room.expire(50_000);
    assert_eq!(
        gone,
        vec![RoomEvent::Left {
            principal_id: "a".to_owned(),
            conn_id: "c1".to_owned(),
            reason: LeaveReason::LeaseExpired
        }]
    );
    assert!(room.expire(100_000).is_empty());
    assert_eq!(room.people(), 0);
    assert_eq!(room.renew("c1", 1), Err(RoomError::UnknownConnection));
}

#[test]
fn lease_is_clamped_to_thirty_seconds() {
    let w = World::new(&["owner"]);
    let d = doc(&[]);
    let mut room = DocRoom::new();
    let o = person("owner", Grants::all());
    room.join(&d, w.scope(), me(&o), "c", u32::MAX, 0).unwrap();
    assert_eq!(room.next_deadline(), Some(u64::from(DEFAULT_LEASE_MS)));
    room.join(&d, w.scope(), me(&o), "c", 0, 0).unwrap();
    assert_eq!(room.next_deadline(), Some(1_000));
}

#[test]
fn bounded_people_and_devices() {
    let names: Vec<String> = (0..=MAX_PEOPLE).map(|i| format!("p{i}")).collect();
    let mut members: Vec<&str> = names.iter().map(String::as_str).collect();
    members.push("owner");
    let w = World::new(&members);
    let roles: Vec<(&str, DocRole)> = names.iter().map(|n| (n.as_str(), DocRole::View)).collect();
    let d = doc(&roles);
    let mut room = DocRoom::new();
    for n in &names[..MAX_PEOPLE] {
        let p = person(n, Grants::all());
        room.join(&d, w.scope(), me(&p), &format!("{n}-0"), DEFAULT_LEASE_MS, 0).unwrap();
    }
    let last = person(&names[MAX_PEOPLE], Grants::all());
    assert_eq!(
        room.join(&d, w.scope(), me(&last), "late", DEFAULT_LEASE_MS, 0),
        Err(RoomError::RoomFull { max: MAX_PEOPLE })
    );
    let p0 = person("p0", Grants::all());
    for i in 1..MAX_CONNS_PER_PRINCIPAL {
        room.join(&d, w.scope(), me(&p0), &format!("p0-{i}"), DEFAULT_LEASE_MS, 0).unwrap();
    }
    assert_eq!(
        room.join(&d, w.scope(), me(&p0), "p0-x", DEFAULT_LEASE_MS, 0),
        Err(RoomError::TooManyConnections { max: MAX_CONNS_PER_PRINCIPAL })
    );
    // A connection id held by someone else is refused before room capacity is checked.
    assert_eq!(
        room.join(&d, w.scope(), me(&last), "p0-0", DEFAULT_LEASE_MS, 0),
        Err(RoomError::ConnTaken)
    );
    let p1 = person("p1", Grants::all());
    assert_eq!(
        room.join(&d, w.scope(), me(&p1), "p0-0", DEFAULT_LEASE_MS, 0),
        Err(RoomError::ConnTaken)
    );
    let v = room.viewers();
    assert_eq!(v.len(), MAX_PEOPLE);
    assert_eq!(v.iter().find(|x| x.principal_id == "p0").unwrap().connections, 4);
}

#[test]
fn revoke_disconnects_every_device_and_their_agents_in_the_same_step() {
    let w = World::new(&["owner", "a", "bot", "b"]);
    let mut d = doc(&[("a", DocRole::Edit), ("bot", DocRole::View), ("b", DocRole::View)]);
    let mut room = DocRoom::new();
    let owner = person("owner", Grants::all());
    let a = person("a", Grants::all());
    let b = person("b", Grants::all());
    let bot = agent("bot", "a", Grants::all());
    room.join(&d, w.scope(), me(&a), "a-mac", DEFAULT_LEASE_MS, 0).unwrap();
    room.join(&d, w.scope(), me(&a), "a-phone", DEFAULT_LEASE_MS, 0).unwrap();
    room.join(
        &d,
        w.scope(),
        Actor { principal: &bot, owner: Some(&a) },
        "bot",
        DEFAULT_LEASE_MS,
        0,
    )
    .unwrap();
    room.join(&d, w.scope(), me(&b), "b", DEFAULT_LEASE_MS, 0).unwrap();

    let (_, events) = room.apply(&mut d, w.scope(), me(&owner), &revoke("u1", "a")).unwrap();
    let mut cut: Vec<(String, DisconnectReason)> = events
        .iter()
        .filter_map(|e| match e {
            RoomEvent::Disconnect { conn_id, reason, .. } => Some((conn_id.clone(), *reason)),
            _ => None,
        })
        .collect();
    cut.sort();
    assert_eq!(
        cut,
        vec![
            ("a-mac".to_owned(), DisconnectReason::Revoked),
            ("a-phone".to_owned(), DisconnectReason::Revoked),
            ("bot".to_owned(), DisconnectReason::Revoked),
        ]
    );
    assert_eq!(room.people(), 1);
    assert!(
        room.expire(u64::MAX)
            .iter()
            .all(|e| matches!(e, RoomEvent::Left { conn_id, .. } if conn_id == "b"))
    );
}

#[test]
fn role_change_and_space_removal() {
    let mut w = World::new(&["owner", "a"]);
    let mut d = doc(&[("a", DocRole::Edit)]);
    let mut room = DocRoom::new();
    let owner = person("owner", Grants::all());
    let a = person("a", Grants::all());
    room.join(&d, w.scope(), me(&a), "c", DEFAULT_LEASE_MS, 0).unwrap();
    let grant =
        op("u1", "owner", DocOp::Grant { principal_id: "a".to_owned(), role: DocRole::View });
    let (_, ev) = room.apply(&mut d, w.scope(), me(&owner), &grant).unwrap();
    assert_eq!(
        ev,
        vec![RoomEvent::RoleChanged { principal_id: "a".to_owned(), role: DocRole::View }]
    );
    // An edit by a now-viewer is refused and changes nothing in the room.
    let edit = op(
        "u2",
        "a",
        DocOp::Edit {
            base_revision: d.revision(),
            edit: TextEdit { at: 0, delete: 0, insert: "x".into() },
        },
    );
    assert!(room.apply(&mut d, w.scope(), me(&a), &edit).is_err());
    // Leaving the space ends access on the next reconcile.
    w.space.members.retain(|m| m != "a");
    let ev = room.reconcile(&d, w.scope());
    assert_eq!(
        ev,
        vec![RoomEvent::Disconnect {
            principal_id: "a".to_owned(),
            conn_id: "c".to_owned(),
            reason: DisconnectReason::AccessLost
        }]
    );
}

#[test]
fn access_request_flow() {
    let w = World::new(&["owner", "a", "b", "bot"]);
    let mut d = doc(&[]);
    let mut room = DocRoom::new();
    let owner = person("owner", Grants::all());
    let a = person("a", Grants::all());
    let b = person("b", Grants::all());
    let bot = agent("bot", "a", Grants::all());

    assert_eq!(room.request_access(&d, w.scope(), &bot, 0), Err(RoomError::CannotRequest));
    assert_eq!(room.request_access(&d, w.scope(), &owner, 0), Err(RoomError::AlreadyHasAccess));
    room.request_access(&d, w.scope(), &a, 1).unwrap();
    assert_eq!(room.request_access(&d, w.scope(), &a, 2), Err(RoomError::AlreadyRequested));
    room.request_access(&d, w.scope(), &b, 3).unwrap();
    assert_eq!(room.pending_requests().len(), 2);

    // Only the owner approves; default role is view.
    assert!(room.approve(&mut d, w.scope(), me(&b), "u0", "a", None).is_err());
    let ev = room.approve(&mut d, w.scope(), me(&owner), "u1", "a", None).unwrap();
    assert_eq!(
        ev,
        vec![RoomEvent::AccessGranted { principal_id: "a".to_owned(), role: DocRole::View }]
    );
    assert!(room.join(&d, w.scope(), me(&a), "a", DEFAULT_LEASE_MS, 5).is_ok());

    assert!(room.decline(&d, &a, "b").is_err());
    room.decline(&d, &owner, "b").unwrap();
    assert_eq!(room.request_access(&d, w.scope(), &b, 6), Err(RoomError::Declined));
    assert_eq!(
        room.join(&d, w.scope(), me(&b), "b", DEFAULT_LEASE_MS, 6),
        Err(RoomError::NoAccess { can_request: false })
    );
    assert_eq!(
        room.approve(&mut d, w.scope(), me(&owner), "u2", "b", None),
        Err(RoomError::NoSuchRequest)
    );
}

#[test]
fn pending_requests_are_capped() {
    let names: Vec<String> = (0..=MAX_PENDING_REQUESTS).map(|i| format!("r{i}")).collect();
    let mut members: Vec<&str> = names.iter().map(String::as_str).collect();
    members.push("owner");
    let w = World::new(&members);
    let d = doc(&[]);
    let mut room = DocRoom::new();
    for n in &names[..MAX_PENDING_REQUESTS] {
        room.request_access(&d, w.scope(), &person(n, Grants::all()), 0).unwrap();
    }
    assert_eq!(
        room.request_access(&d, w.scope(), &person(&names[MAX_PENDING_REQUESTS], Grants::all()), 0),
        Err(RoomError::TooManyRequests { max: MAX_PENDING_REQUESTS })
    );
}

#[test]
fn a_person_without_read_cannot_ask() {
    let w = World::new(&["owner", "a"]);
    let d = doc(&[]);
    let mut room = DocRoom::new();
    let a = person("a", Grants::of(&[Capability::Post]));
    assert_eq!(room.request_access(&d, w.scope(), &a, 0), Err(RoomError::CannotRequest));
}

proptest! {
    /// Under any interleaving of joins, renews, leaves, sweeps and revokes: every lease leaves
    /// exactly once, nobody without a role stays, and the bounds hold.
    #[test]
    fn leases_leave_once_and_access_holds(
        steps in prop::collection::vec((0u8..5, 0usize..6, 0usize..3, 0u64..40_000), 0..200)
    ) {
        let ids = ["p0", "p1", "p2", "p3", "p4", "p5"];
        let w = World::new(&["owner", "p0", "p1", "p2", "p3", "p4", "p5"]);
        let owner = person("owner", Grants::all());
        let people: Vec<Principal> = ids.iter().map(|i| person(i, Grants::all())).collect();
        let roles: Vec<(&str, DocRole)> = ids.iter().map(|i| (*i, DocRole::View)).collect();
        let mut d = doc(&roles);
        let mut room = DocRoom::new();
        let mut now = 0u64;
        let mut joined = 0usize;
        let mut left = 0usize;
        let mut live = std::collections::BTreeSet::new();
        for (i, (kind, who, dev, dt)) in steps.into_iter().enumerate() {
            now += dt / 10;
            let p = &people[who];
            let conn = format!("{}-{dev}", p.id);
            match kind {
                0 => {
                    if let Ok(RoomEvent::Joined { .. }) = room.join(&d, w.scope(), me(p), &conn, DEFAULT_LEASE_MS, now)
                        && live.insert(conn.clone()) { joined += 1; }
                }
                1 => { let _ = room.renew(&conn, now); }
                2 => if room.leave(&conn).is_some() { live.remove(&conn); left += 1; },
                3 => for e in room.expire(now) {
                    if let RoomEvent::Left { conn_id, .. } = e { prop_assert!(live.remove(&conn_id)); left += 1; }
                },
                _ => {
                    let u = revoke(&format!("r{i}"), &p.id);
                    if let Ok((_, ev)) = room.apply(&mut d, w.scope(), me(&owner), &u) {
                        for e in ev {
                            if let RoomEvent::Disconnect { conn_id, principal_id, .. } = e {
                                prop_assert_eq!(&principal_id, &p.id);
                                prop_assert!(live.remove(&conn_id));
                                left += 1;
                            }
                        }
                    }
                }
            }
            prop_assert_eq!(room.connections(), live.len());
            prop_assert!(room.people() <= MAX_PEOPLE);
            for v in room.viewers() {
                prop_assert!(d.doc.roles.contains_key(&v.principal_id));
                prop_assert!(v.connections <= MAX_CONNS_PER_PRINCIPAL);
            }
        }
        for e in room.expire(u64::MAX) {
            if let RoomEvent::Left { conn_id, .. } = e { prop_assert!(live.remove(&conn_id)); left += 1; }
        }
        prop_assert!(live.is_empty());
        prop_assert_eq!(joined, left);
    }
}

fn pct(sorted: &[u128], p: f64) -> u128 {
    let i = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[i]
}

/// 20 participants, each on 2 devices, renewing and editing; every round the owner revokes one
/// and re-grants them. Reports renews/s, update+reconcile p50/p95/p99, and revoke-to-disconnect
/// time (the work between the revoke arriving and its disconnect events being ready).
#[test]
#[ignore]
fn bench_room_20_participants() {
    const N: usize = 20;
    const ROUNDS: usize = 20_000;
    let names: Vec<String> = (0..N).map(|i| format!("p{i}")).collect();
    let mut members: Vec<&str> = names.iter().map(String::as_str).collect();
    members.push("owner");
    let w = World::new(&members);
    let owner = person("owner", Grants::all());
    let people: Vec<Principal> = names.iter().map(|n| person(n, Grants::all())).collect();
    let roles: Vec<(&str, DocRole)> = names.iter().map(|n| (n.as_str(), DocRole::Edit)).collect();
    let mut d = doc(&roles);
    let mut room = DocRoom::new();
    for p in &people {
        for dev in 0..2 {
            room.join(&d, w.scope(), me(p), &format!("{}-{dev}", p.id), DEFAULT_LEASE_MS, 0)
                .unwrap();
        }
    }
    let mut update_ns = Vec::with_capacity(ROUNDS);
    let mut revoke_ns = Vec::with_capacity(ROUNDS / 100);
    let mut renews = 0u64;
    let start = Instant::now();
    let mut uid = 0u64;
    for r in 0..ROUNDS {
        let now = r as u64 * 10;
        let p = &people[r % N];
        for dev in 0..2 {
            room.renew(&format!("{}-{dev}", p.id), now).unwrap();
            renews += 1;
        }
        uid += 1;
        let edit = op(
            &format!("u{uid}"),
            &p.id,
            DocOp::Edit {
                base_revision: d.revision(),
                edit: TextEdit { at: 0, delete: 0, insert: "x".into() },
            },
        );
        let t = Instant::now();
        room.apply(&mut d, w.scope(), me(p), &edit).unwrap();
        update_ns.push(t.elapsed().as_nanos());
        if r % 100 == 99 {
            uid += 1;
            let t = Instant::now();
            let (_, ev) = room
                .apply(&mut d, w.scope(), me(&owner), &revoke(&format!("u{uid}"), &p.id))
                .unwrap();
            revoke_ns.push(t.elapsed().as_nanos());
            assert_eq!(ev.iter().filter(|e| matches!(e, RoomEvent::Disconnect { .. })).count(), 2);
            uid += 1;
            let g = op(
                &format!("u{uid}"),
                "owner",
                DocOp::Grant { principal_id: p.id.clone(), role: DocRole::Edit },
            );
            room.apply(&mut d, w.scope(), me(&owner), &g).unwrap();
            for dev in 0..2 {
                room.join(&d, w.scope(), me(p), &format!("{}-{dev}", p.id), DEFAULT_LEASE_MS, now)
                    .unwrap();
            }
        }
        room.expire(now);
    }
    let secs = start.elapsed().as_secs_f64();
    update_ns.sort_unstable();
    revoke_ns.sort_unstable();
    println!(
        "BENCH participants={N} conns={} renews/s={:.0} update+reconcile p50={}ns p95={}ns p99={}ns revoke->disconnect p50={}ns p95={}ns p99={}ns max={}ns",
        room.connections(),
        renews as f64 / secs,
        pct(&update_ns, 0.5),
        pct(&update_ns, 0.95),
        pct(&update_ns, 0.99),
        pct(&revoke_ns, 0.5),
        pct(&revoke_ns, 0.95),
        pct(&revoke_ns, 0.99),
        revoke_ns.last().copied().unwrap_or(0),
    );
    assert_eq!(room.connections(), N * 2);
    assert!(revoke_ns.last().copied().unwrap_or(0) < 1_000_000_000, "revoke past 1 s");
}
