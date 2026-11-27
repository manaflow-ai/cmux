//! RFD 0170 phase 1: the team navigator, recipient picker and Session Info projections.

mod common;

use std::collections::BTreeMap;
use std::time::Instant;

use cmux_sync::presence::Status;

use cmux_team_messaging::backend::{Room, RoomRole};
use cmux_team_messaging::directory::{Liveness, Recent, SessionAction};
use cmux_team_messaging::model::AgentGrant;
use cmux_team_messaging::presence::Participant;
use cmux_team_messaging::refs::RefKey;
use cmux_team_messaging::{
    Bridge, Candidate, DeliveryMode, Directory, Grants, LinkGraph, Principal, PrincipalKind,
    RefKind, RefSource, RootKind, Space, SpaceKind, ThreadState,
};

use common::*;

fn space_of(id: &str, kind: SpaceKind, title: &str, members: &[&str]) -> Space {
    Space { id: id.to_owned(), kind, title: title.to_owned(), ..space(members) }
}

fn live(p: &Principal, status: Status, working: bool) -> Participant {
    Participant {
        principal_id: p.id.clone(),
        kind: p.kind,
        name: p.display_name.clone(),
        status,
        working,
    }
}

fn named(mut p: Principal, name: &str) -> Principal {
    p.display_name = name.to_owned();
    p
}

/// ana (viewer), bo and cy are people; bo-bot is bo's agent; slacky writes via Slack; zed is in
/// another team. Spaces: a team space, an ana/bo pair, a private bo/cy pair, an RFD space.
fn world() -> Directory {
    let ana = named(person("ana", Grants::all()), "Ana");
    let bo = named(person("bo", Grants::all()), "Bo Li");
    let cy = named(person("cy", Grants::all()), "Cy");
    let mut bot = named(agent("bo-bot", "bo", Grants::all()), "Bo's reviewer");
    bot.session_id = Some("sess-1".to_owned());
    let slacky = bridged("slacky", Bridge::Slack);
    let mut zed = person("zed", Grants::all());
    zed.team_id = "team-b".to_owned();

    let mut team_space =
        space_of("s-team", SpaceKind::Team, "General", &["ana", "bo", "cy", "bo-bot"]);
    team_space.agent_policy.insert(
        "bo-bot".to_owned(),
        AgentGrant { granted_by: "bo".to_owned(), wake: false, default_mode: DeliveryMode::Fyi },
    );
    let mut t = team(Grants::all());
    t.spaces = vec!["s-team".into(), "s-pair".into(), "s-private".into(), "s-rfd".into()];
    let mut thread_a = thread("s-team/1");
    thread_a.space_id = "s-team".to_owned();
    thread_a.subject = "Flaky check on main".to_owned();
    thread_a.linked_session_ids = vec!["sess-1".to_owned()];
    thread_a.linked_rfd_ids = vec!["170".to_owned()];
    thread_a.revision = 3;
    let mut thread_secret = thread("s-private/1");
    thread_secret.space_id = "s-private".to_owned();
    thread_secret.subject = "Secret plans".to_owned();
    let mut thread_closed = thread("s-team/2");
    thread_closed.space_id = "s-team".to_owned();
    thread_closed.state = ThreadState::Closed;
    Directory {
        principals: vec![ana, bo, cy, bot, slacky, zed],
        teams: vec![t],
        spaces: vec![
            team_space,
            space_of("s-pair", SpaceKind::Pair, "Ana and Bo", &["ana", "bo"]),
            space_of("s-private", SpaceKind::Pair, "Bo and Cy", &["bo", "cy"]),
            space_of("s-rfd", SpaceKind::Rfd, "RFD 0170", &["ana", "bo-bot"]),
        ],
        threads: vec![thread_a, thread_secret, thread_closed],
    }
}

fn viewer(d: &Directory) -> Principal {
    d.principal("ana").unwrap().clone()
}

#[test]
fn navigator_lists_only_readable_spaces_in_order_with_unread_and_live() {
    let d = world();
    let ana = viewer(&d);
    let unread = BTreeMap::from([
        ("s-pair".to_owned(), 2),
        ("s-private".to_owned(), 9),
        ("s-rfd".to_owned(), 1),
    ]);
    let here = vec![
        live(d.principal("bo-bot").unwrap(), Status::Active, true),
        live(d.principal("bo").unwrap(), Status::Idle, false),
        live(d.principal("cy").unwrap(), Status::Away, false),
    ];
    let nav = d.navigator(&ana, TEAM, &unread, &here);
    let ids: Vec<&str> = nav.spaces.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["s-team", "s-pair", "s-rfd"], "private pair never listed");
    assert_eq!(nav.spaces[1].unread, 2);
    // The private space's unread never leaks into the team total.
    assert_eq!(nav.teams.len(), 1);
    assert_eq!(nav.teams[0].unread, 3);
    // Live: people first, then agents; away is not live; the viewer and bridge authors excluded.
    let live_ids: Vec<&str> = nav.live.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(live_ids, ["bo", "bo-bot"]);
    let bot = &nav.live[1];
    assert_eq!(bot.kind, PrincipalKind::Agent);
    assert_eq!(bot.owner_name.as_deref(), Some("Bo Li"));
    assert!(bot.working);
    let team_row = &nav.spaces[0];
    assert_eq!(team_row.live.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), ["bo", "bo-bot"]);
}

#[test]
fn picker_orders_people_then_recent_threads_then_agents_then_spaces() {
    let d = world();
    let ana = viewer(&d);
    let recent = vec![
        Recent { thread_id: "s-team/1".into(), at_ms: 50 },
        Recent { thread_id: "s-private/1".into(), at_ms: 90 },
        Recent { thread_id: "s-team/2".into(), at_ms: 99 },
    ];
    let got = d.pick(&ana, TEAM, "", &recent, &[], 50);
    let ids: Vec<&str> = got.iter().map(Candidate::id).collect();
    // No viewer, no bridge author, no other team, no unreadable or closed thread, no pair space
    // twice (it rides on its person).
    assert_eq!(ids, ["bo", "cy", "s-team/1", "bo-bot", "s-team", "s-rfd"]);
    match &got[0] {
        Candidate::Person { pair_space_id, .. } => {
            assert_eq!(pair_space_id.as_deref(), Some("s-pair"))
        }
        other => panic!("{other:?}"),
    }
    match &got[1] {
        Candidate::Person { pair_space_id, .. } => assert_eq!(*pair_space_id, None),
        other => panic!("{other:?}"),
    }
    match &got[3] {
        Candidate::Agent { card, default_mode, can_wake } => {
            assert_eq!(card.owner_id.as_deref(), Some("bo"));
            assert_eq!(card.harness.as_deref(), Some("claude"));
            assert_eq!(card.session_id.as_deref(), Some("sess-1"));
            assert_eq!(card.liveness, Liveness::Offline);
            assert_eq!(*default_mode, DeliveryMode::Fyi, "owner's default in the team space");
            assert!(!can_wake, "no owner wake grant");
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn picker_query_ranks_by_match_and_at_means_principals_only() {
    let d = world();
    let ana = viewer(&d);
    let got = d.pick(&ana, TEAM, "bo", &[], &[], 10);
    let ids: Vec<&str> = got.iter().map(Candidate::id).collect();
    // `bo` is an exact handle; `bo-bot` a prefix.
    assert_eq!(ids, ["bo", "bo-bot"]);

    let got = d.pick(&ana, TEAM, "li", &[], &[], 10);
    let ids: Vec<&str> = got.iter().map(Candidate::id).collect();
    // A word prefix of Bo's display name; his agent matches through its owner's name.
    assert_eq!(ids, ["bo", "bo-bot"]);

    let got = d.pick(&ana, TEAM, "gen", &[], &[], 10);
    assert_eq!(got.iter().map(Candidate::id).collect::<Vec<_>>(), ["s-team"]);
    assert!(
        d.pick(&ana, TEAM, "@gen", &[], &[], 10).is_empty(),
        "@ matches people and agents only"
    );
    assert!(
        d.pick(
            &ana,
            TEAM,
            "secret",
            &[Recent { thread_id: "s-private/1".into(), at_ms: 1 }],
            &[],
            10
        )
        .is_empty()
    );
    assert!(
        d.pick(&ana, TEAM, "slacky", &[], &[], 10).is_empty(),
        "a bridge author is never a recipient"
    );
    assert!(d.pick(&ana, "team-b", "", &[], &[], 10).is_empty());
}

#[test]
fn picker_wake_only_with_owner_grant_and_live_first_within_group() {
    let mut d = world();
    let ana = viewer(&d);
    // Someone other than the owner granting wake does nothing.
    d.spaces[0].agent_policy.insert(
        "bo-bot".to_owned(),
        AgentGrant { granted_by: "ana".into(), wake: true, default_mode: DeliveryMode::Wake },
    );
    let got = d.pick(&ana, TEAM, "@bo-bot", &[], &[], 1);
    assert!(matches!(&got[0], Candidate::Agent { can_wake: false, .. }));
    d.spaces[0].agent_policy.get_mut("bo-bot").unwrap().granted_by = "bo".into();
    let got = d.pick(&ana, TEAM, "@bo-bot", &[], &[], 1);
    assert!(matches!(
        &got[0],
        Candidate::Agent { can_wake: true, default_mode: DeliveryMode::Wake, .. }
    ));
    // A grant in a space the owner cannot read counts for nothing: the owner bounds the agent.
    d.spaces[0].agent_policy.clear();
    d.spaces[3].agent_policy.insert(
        "bo-bot".to_owned(),
        AgentGrant { granted_by: "bo".into(), wake: true, default_mode: DeliveryMode::Wake },
    );
    let got = d.pick(&ana, TEAM, "@bo-bot", &[], &[], 1);
    assert!(matches!(
        &got[0],
        Candidate::Agent { can_wake: false, default_mode: DeliveryMode::Ask, .. }
    ));

    let here = vec![live(d.principal("cy").unwrap(), Status::Active, false)];
    let got = d.pick(&ana, TEAM, "@", &[], &here, 2);
    assert_eq!(got.iter().map(Candidate::id).collect::<Vec<_>>(), ["cy", "bo"], "live first");
}

#[test]
fn session_info_shows_participants_links_and_actions_without_leaking() {
    let d = world();
    let ana = viewer(&d);
    let session = RefKey::new(RefKind::Session, RefSource::Cmux, "sess-1").unwrap();
    let mut links = LinkGraph::new();
    links.link(&session, &RefKey::new(RefKind::Rfd, RefSource::Hq, "0140").unwrap());
    links.link(&session, &RefKey::new(RefKind::Thread, RefSource::Cmux, "s-private/1").unwrap());
    let room = Room {
        session_id: "sess-1".into(),
        owner_id: "bo".into(),
        members: vec![("ana".into(), RoomRole::View), ("cy".into(), RoomRole::Talk)],
    };
    let here = vec![live(d.principal("bo-bot").unwrap(), Status::Active, true)];
    let titles = BTreeMap::from([("rfd:hq/0170".to_owned(), "Native team messaging".to_owned())]);
    let info = d.session_info(&ana, "sess-1", &links, Some(&room), &here, &titles);

    assert_eq!(info.team_id.as_deref(), Some(TEAM));
    assert_eq!(info.space.as_ref().map(|s| s.title.as_str()), Some("General"));
    assert_eq!(info.thread.as_ref().map(|t| t.title.as_str()), Some("Flaky check on main"));
    assert_eq!(
        info.current_ask.as_ref().map(|t| t.canonical.as_str()),
        Some("thread:cmux/s-team/1")
    );
    let rfds: Vec<(&str, &str)> =
        info.rfds.iter().map(|r| (r.canonical.as_str(), r.title.as_str())).collect();
    assert_eq!(rfds, [("rfd:hq/0140", "0140"), ("rfd:hq/0170", "Native team messaging")]);
    assert_eq!(info.hidden_links, 1, "the private thread is counted, not named");
    assert!(!format!("{info:?}").contains("Secret"));

    let ps: Vec<(&str, Option<RoomRole>, bool)> =
        info.participants.iter().map(|p| (p.card.id.as_str(), p.role, p.owner)).collect();
    assert_eq!(
        ps,
        [
            ("bo", Some(RoomRole::Talk), true),
            ("ana", Some(RoomRole::View), false),
            ("cy", Some(RoomRole::Talk), false),
            ("bo-bot", None, false),
        ]
    );
    assert_eq!(info.viewer_role, Some(RoomRole::View));
    assert_eq!(info.owner.as_ref().map(|o| o.id.as_str()), Some("bo"));
    assert_eq!(
        info.actions,
        [
            SessionAction::OpenThread { target: "thread:cmux/s-team/1".into() },
            SessionAction::OpenRfd { target: "rfd:hq/0140".into() },
            SessionAction::JoinRoom { session_id: "sess-1".into() },
            SessionAction::CopyLink { link: "session:cmux/sess-1".into() },
        ]
    );

    // Not admitted to the room and no readable thread: no join, no thread, still a link to copy.
    let zed = d.principal("zed").unwrap().clone();
    let info = d.session_info(&zed, "sess-1", &links, Some(&room), &[], &titles);
    assert_eq!(info.viewer_role, None);
    assert!(info.thread.is_none() && info.current_ask.is_none() && info.space.is_none());
    assert_eq!(
        info.actions,
        [
            SessionAction::OpenRfd { target: "rfd:hq/0140".into() },
            SessionAction::CopyLink { link: "session:cmux/sess-1".into() },
        ]
    );
}

#[test]
fn surfaces_serialize_for_the_webview() {
    let d = world();
    let ana = viewer(&d);
    let got = d.pick(&ana, TEAM, "bo-bot", &[], &[], 1);
    let json = serde_json::to_value(&got[0]).unwrap();
    assert_eq!(json["kind"], "agent");
    assert_eq!(json["card"]["ownerName"], "Bo Li");
    assert_eq!(json["defaultMode"], "fyi");
    let nav = d.navigator(&ana, TEAM, &BTreeMap::new(), &[]);
    let json = serde_json::to_value(&nav).unwrap();
    assert_eq!(json["spaces"][0]["kind"], "team");
    let _ = RootKind::Ask;
}

/// The duress number for the PR: a 1000-person, 1000-agent team with 200 spaces and 5000 recent
/// threads. Run with `--ignored --nocapture` for timings; the assertion is a loose ceiling.
#[test]
#[ignore = "measurement"]
fn picker_and_navigator_at_team_scale() {
    let mut d = world();
    let mut members: Vec<String> = Vec::new();
    for i in 0..1000 {
        let id = format!("p{i}");
        d.principals.push(named(person(&id, Grants::all()), &format!("Person {i}")));
        d.principals
            .push(named(agent(&format!("a{i}"), &id, Grants::all()), &format!("Agent {i}")));
        members.push(id);
        members.push(format!("a{i}"));
    }
    members.push("ana".into());
    for s in 0..200 {
        let m: Vec<&str> = members
            .iter()
            .skip(s * 7 % 1500)
            .take(300)
            .map(String::as_str)
            .chain(["ana"])
            .collect();
        d.spaces.push(space_of(&format!("x{s}"), SpaceKind::Project, &format!("Project {s}"), &m));
    }
    let mut recent = Vec::new();
    for t in 0..5000u64 {
        let mut th = thread(&format!("x{}/{t}", t % 200));
        th.space_id = format!("x{}", t % 200);
        th.subject = format!("Thread {t}");
        d.threads.push(th);
        recent.push(Recent { thread_id: format!("x{}/{t}", t % 200), at_ms: t });
    }
    let here: Vec<Participant> =
        d.principals.iter().step_by(3).map(|p| live(p, Status::Active, false)).collect();
    let ana = viewer(&d);
    let mut samples = Vec::new();
    for q in ["", "p", "person 99", "@a12", "thread 4"] {
        for _ in 0..5 {
            let t = Instant::now();
            let got = d.pick(&ana, TEAM, q, &recent, &here, 50);
            samples.push(t.elapsed());
            assert!(!got.is_empty(), "{q}");
        }
    }
    samples.sort();
    let p50 = samples[samples.len() / 2];
    let p95 = samples[samples.len() * 95 / 100];
    let t = Instant::now();
    let nav = d.navigator(&ana, TEAM, &BTreeMap::new(), &here);
    let nav_t = t.elapsed();
    println!(
        "picker p50 {p50:?} p95 {p95:?}; navigator {nav_t:?} over {} spaces",
        nav.spaces.len()
    );
    assert!(p95.as_millis() < 2000);
}
