//! RFD 0170 phase 1 team navigator, picker and Session Info RPCs through the daemon dispatcher.

use super::*;
use crate::hub::TeamView;
use crate::mesh::{AddressBook, BookDaemon, BookSession};
use cmux_sync::presence::Status;
use cmux_team_messaging::navigator::SessionEntry;
use cmux_team_messaging::presence::Participant;
use cmux_team_messaging::{
    Grants, Principal, PrincipalKind, RootKind, Space, SpaceKind, Team, Thread, ThreadState,
};
use std::collections::BTreeMap;
use std::time::Instant;

const TEAM: &str = "team_1";
const ME: &str = "user_me";
const PEER: &str = "user_peer";

fn book() -> AddressBook {
    let daemon = |id: &str, user: &str| BookDaemon {
        daemon_id: id.into(),
        host: format!("{id}-host"),
        user: user.into(),
        last_seen_at: 1,
    };
    let session = |id: &str, daemon: &str, name: &str, state: &str| BookSession {
        name: name.into(),
        session_id: id.into(),
        host: format!("{daemon}-host"),
        daemon_id: daemon.into(),
        harness: "claude".into(),
        state: state.into(),
        ..BookSession::default()
    };
    AddressBook {
        daemons: vec![daemon("d_me", ME), daemon("d_peer", PEER)],
        sessions: vec![
            session(OWN, "d_me", "reader", "working"),
            session(OTHER, "d_peer", "reviewer", "idle"),
        ],
    }
}

fn seeded(enabled: bool) -> Arc<Hub> {
    let (hub, _) = setup(enabled);
    assert!(hub.apply_team_book(TEAM, Some(ME), &book()));
    hub
}

#[tokio::test]
async fn directory_rpcs_are_gated_by_team_messaging() {
    let hub = seeded(false);
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    for m in [method::MUX_TEAM_NAVIGATOR, method::MUX_TEAM_PICK, method::MUX_TEAM_SESSION_INFO] {
        let refused = owner.call(m, json!({"sessionId": OWN})).await;
        assert_eq!(refused["error"]["data"]["reason"], "team_messaging_disabled", "{refused}");
    }
}

#[tokio::test]
async fn directory_rpcs_wait_for_the_first_address_book() {
    let (hub, _) = setup(true);
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    let reply = owner.call(method::MUX_TEAM_NAVIGATOR, json!({})).await;
    assert_eq!(reply["error"]["data"]["reason"], "team_directory_unavailable", "{reply}");
}

#[tokio::test]
async fn navigator_lists_the_team_space_with_who_is_live() {
    let hub = seeded(true);
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    let nav = owner.call(method::MUX_TEAM_NAVIGATOR, json!({"query": "review"})).await;
    let nav = &nav["result"];
    assert_eq!(nav["generation"], 1, "{nav}");
    assert_eq!(nav["teams"][0]["id"], TEAM, "{nav}");
    assert_eq!(nav["teams"][0]["current"], true);
    let space = &nav["spaces"][0];
    assert_eq!(space["id"], format!("team:{TEAM}"));
    assert_eq!(space["kind"], "team");
    let people: Vec<&str> = space["people"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["principalId"].as_str().unwrap())
        .collect();
    assert_eq!(people, [ME, PEER]);
    let reader = space["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["principalId"] == format!("agent:{OWN}"))
        .unwrap();
    assert_eq!(reader["working"], true, "{space}");
    assert!(
        nav["hits"].as_array().unwrap().iter().any(|h| h["id"] == format!("agent:{OTHER}")),
        "search finds the reviewer agent: {nav}"
    );
}

#[tokio::test]
async fn pick_answers_camel_case_candidates_and_resolves_a_handle() {
    let hub = seeded(true);
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    let picked = owner.call(method::MUX_TEAM_PICK, json!({"query": "@reviewer"})).await;
    let picked = &picked["result"];
    assert_eq!(picked["resolved"], json!([format!("agent:{OTHER}")]), "{picked}");
    let agent = picked["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == format!("agent:{OTHER}"))
        .unwrap_or_else(|| panic!("{picked}"));
    assert_eq!(agent["kind"], "agent");
    assert_eq!(agent["owner"], PEER, "{agent}");
    assert_eq!(agent["sessionId"], OTHER);
    assert_eq!(agent["spaceId"], format!("team:{TEAM}"));
    assert!(agent.get("wakeAllowed").is_some(), "{agent}");

    let all = owner.call(method::MUX_TEAM_PICK, json!({"limit": 1})).await;
    assert_eq!(all["result"]["candidates"].as_array().unwrap().len(), 1, "{all}");
}

#[tokio::test]
async fn an_agent_connection_picks_as_its_own_agent() {
    let hub = seeded(true);
    let mut agent = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    let picked = agent.call(method::MUX_TEAM_PICK, json!({"query": ""})).await;
    let ids: Vec<&str> = picked["result"]["candidates"]
        .as_array()
        .unwrap_or_else(|| panic!("{picked}"))
        .iter()
        .map(|c| c["id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&ME), "{picked}");
    // A session the book does not list has no principal to speak as.
    let view = hub.team_view().unwrap();
    assert!(view.viewer(false, Some("not-in-book")).is_none());
    assert_eq!(view.viewer(false, Some(OWN)).unwrap().id, format!("agent:{OWN}"));
    assert_eq!(view.viewer(true, Some(OWN)).unwrap().id, ME);
}

#[tokio::test]
async fn session_info_projects_the_owner_and_room() {
    let hub = seeded(true);
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    let info = owner.call(method::MUX_TEAM_SESSION_INFO, json!({"sessionId": OWN})).await;
    let info = &info["result"];
    assert_eq!(info["teamId"], TEAM, "{info}");
    assert_eq!(info["ownerId"], ME, "{info}");
    assert_eq!(info["standing"], "owner", "{info}");
    assert_eq!(info["spaceKind"], "team");
    assert!(info["actions"].as_array().is_some_and(|a| !a.is_empty()), "{info}");

    let missing = owner.call(method::MUX_TEAM_SESSION_INFO, json!({})).await;
    assert!(missing["error"]["message"].as_str().unwrap().contains("sessionId"), "{missing}");
}

#[test]
fn the_same_book_keeps_the_snapshot() {
    let (hub, _) = setup(true);
    assert!(hub.apply_team_book(TEAM, Some(ME), &book()));
    let first = hub.team_view().unwrap();
    assert!(!hub.apply_team_book(TEAM, Some(ME), &book()), "an unchanged book is not a rebuild");
    assert!(Arc::ptr_eq(&first, &hub.team_view().unwrap()));
    let mut changed = book();
    changed.sessions[1].state = "working".into();
    assert!(hub.apply_team_book(TEAM, Some(ME), &changed));
    assert_eq!(hub.team_view().unwrap().generation, first.generation + 1);
}

/// The phase-1 surfaces scale (`cmux-team-messaging/tests/surfaces.rs`): 1000 people and 1000
/// agents, 200 spaces of about 300 members, 5000 recent threads, a third of everyone live.
fn surfaces_scale() -> TeamView {
    let principal = |id: String, kind: PrincipalKind, owner: Option<String>| Principal {
        handle: id.clone(),
        display_name: format!("Name {id}"),
        team_id: TEAM.into(),
        session_id: (kind == PrincipalKind::Agent).then(|| format!("s{id}")),
        harness: (kind == PrincipalKind::Agent).then(|| "claude".into()),
        owner_person_id: owner,
        model: None,
        host_id: None,
        capabilities: Grants::all(),
        via: None,
        kind,
        id,
    };
    let mut principals: Vec<Principal> =
        (0..1000).map(|i| principal(format!("p{i}"), PrincipalKind::Person, None)).collect();
    principals.extend(
        (0..1000).map(|i| principal(format!("a{i}"), PrincipalKind::Agent, Some(format!("p{i}")))),
    );
    principals[0].id = ME.into();
    principals[0].handle = ME.into();
    let ids: Vec<String> = principals.iter().map(|p| p.id.clone()).collect();
    let spaces: Vec<Space> = (0..200)
        .map(|s| {
            let mut members: Vec<String> =
                (0..300).map(|k| ids[(s * 37 + k * 7) % ids.len()].clone()).collect();
            members.push(ME.into());
            members.sort();
            members.dedup();
            Space {
                id: format!("space{s}"),
                team_id: TEAM.into(),
                kind: if s % 10 == 0 { SpaceKind::Pair } else { SpaceKind::Project },
                title: format!("Space {s}"),
                members,
                agent_policy: BTreeMap::new(),
                notification_policy: BTreeMap::new(),
            }
        })
        .collect();
    let threads: Vec<Thread> = (0..5000)
        .map(|t| Thread {
            id: format!("thread{t}"),
            space_id: format!("space{}", t % 200),
            root_kind: RootKind::Message,
            subject: format!("Subject {t}"),
            participants: vec![ME.into(), ids[(t * 13) % ids.len()].clone()],
            linked_rfd_ids: Vec::new(),
            linked_session_ids: vec![format!("sa{}", t % 1000)],
            revision: t as u64,
            state: ThreadState::Open,
        })
        .collect();
    let here: BTreeMap<String, Vec<Participant>> = spaces
        .iter()
        .map(|s| {
            let live = s
                .members
                .iter()
                .enumerate()
                .filter(|(i, _)| i % 3 == 0)
                .map(|(_, id)| Participant {
                    principal_id: id.clone(),
                    kind: if id.starts_with('a') {
                        PrincipalKind::Agent
                    } else {
                        PrincipalKind::Person
                    },
                    name: format!("Name {id}"),
                    status: Status::Active,
                    working: false,
                })
                .collect();
            (s.id.clone(), live)
        })
        .collect();
    let sessions = (0..1000)
        .map(|i| SessionEntry {
            id: format!("sa{i}"),
            title: format!("Session {i}"),
            space_id: format!("space{}", i % 200),
        })
        .collect();
    TeamView {
        team_id: TEAM.into(),
        person_id: Some(ME.into()),
        teams: vec![Team {
            id: TEAM.into(),
            name: "Team".into(),
            members: ids,
            spaces: spaces.iter().map(|s| s.id.clone()).collect(),
            integrations: Vec::new(),
            policy: Grants::all(),
            customization: BTreeMap::new(),
        }],
        unread: threads.iter().step_by(4).map(|t| (t.id.clone(), 1)).collect(),
        spaces,
        principals,
        threads,
        here,
        sessions,
        ..TeamView::default()
    }
    .indexed()
}

fn percentile(sorted: &[Duration], p: f64) -> Duration {
    sorted[((sorted.len() as f64 * p).ceil() as usize).saturating_sub(1).min(sorted.len() - 1)]
}

/// Duress: picker, navigator and Session Info latency through the RPC at the surfaces scale.
/// `cargo test --release -p acpmux directory_rpcs_at_surfaces_scale -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "duress measurement; run in release"]
async fn directory_rpcs_at_surfaces_scale() {
    let (hub, _) = setup(true);
    let built = Instant::now();
    hub.set_team_view(surfaces_scale());
    eprintln!("publish (index) once: {:?}", built.elapsed());
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    let queries = ["", "n", "na", "nam", "name", "name 4", "name 42", "@a42", "space 1", "subj"];
    let calls: [(&str, Box<dyn Fn(usize) -> Value>); 3] = [
        (method::MUX_TEAM_PICK, Box::new(|i| json!({"query": queries[i % queries.len()]}))),
        (method::MUX_TEAM_NAVIGATOR, Box::new(|i| json!({"query": queries[i % queries.len()]}))),
        (
            method::MUX_TEAM_SESSION_INFO,
            Box::new(|i| json!({"sessionId": format!("sa{}", i % 1000)})),
        ),
    ];
    for (m, params) in &calls {
        for i in 0..20 {
            let warm = owner.call(m, params(i)).await;
            assert!(warm.get("error").is_none(), "{warm}");
        }
        let mut took = Vec::new();
        for i in 0..400 {
            let t = Instant::now();
            let reply = owner.call(m, params(i)).await;
            took.push(t.elapsed());
            assert!(reply.get("error").is_none(), "{reply}");
        }
        took.sort();
        eprintln!(
            "{m}: p50 {:?} p95 {:?} max {:?} (n={})",
            percentile(&took, 0.50),
            percentile(&took, 0.95),
            took.last().unwrap(),
            took.len()
        );
    }
}
