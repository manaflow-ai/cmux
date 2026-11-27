//! RFD 0170 phase 1, recipient picker: tiers, `@handle`, grants and wake mode before send.

mod common;

use cmux_sync::presence::Status;

use cmux_team_messaging::model::AgentGrant;
use cmux_team_messaging::picker::{CandidateKind, PickerContext, pick};
use cmux_team_messaging::presence::Participant;
use cmux_team_messaging::{
    Bridge, Capability, DeliveryMode, Grants, Principal, PrincipalKind, Space, SpaceKind, Thread,
};

use common::*;

fn pair(id: &str, a: &str, b: &str) -> Space {
    Space {
        id: id.to_owned(),
        kind: SpaceKind::Pair,
        title: format!("{a} & {b}"),
        ..space(&[a, b])
    }
}

fn team_space(members: &[&str]) -> Space {
    Space {
        id: "all".to_owned(),
        kind: SpaceKind::Team,
        title: "Everyone".to_owned(),
        ..space(members)
    }
}

fn fixture() -> (Vec<Principal>, Vec<Space>, Vec<Thread>) {
    let principals = vec![
        person("alice", Grants::all()),
        person("bob", Grants::all()),
        person("carol", Grants::all()),
        agent("bobs-agent", "bob", Grants::all()),
        bridged("slack-bob", Bridge::Slack),
    ];
    let mut project = space(&["alice", "bob", "bobs-agent"]);
    project.agent_policy.insert(
        "bobs-agent".to_owned(),
        AgentGrant { granted_by: "bob".to_owned(), wake: false, default_mode: DeliveryMode::Wake },
    );
    let spaces = vec![
        project,
        pair("ab", "alice", "bob"),
        pair("bc", "bob", "carol"),
        team_space(&["alice", "bob", "carol"]),
    ];
    let mut t1 = thread("space-1/1");
    t1.subject = "Flaky check".to_owned();
    let mut hidden = thread("bc/1");
    hidden.space_id = "bc".to_owned();
    hidden.subject = "Flaky secret".to_owned();
    (principals, spaces, vec![t1, hidden])
}

#[test]
fn people_and_pairs_first_then_agents_spaces_threads() {
    let (principals, spaces, recent) = fixture();
    let t = team(Grants::all());
    let here = vec![Participant {
        principal_id: "bobs-agent".to_owned(),
        kind: PrincipalKind::Agent,
        name: "bobs-agent".to_owned(),
        status: Status::Active,
        working: true,
    }];
    let cx = PickerContext {
        team: &t,
        spaces: &spaces,
        principals: &principals,
        recent: &recent,
        here: &here,
    };
    let p = pick(&principals[0], "", &cx);
    let kinds: Vec<CandidateKind> = p.candidates.iter().map(|c| c.kind).collect();
    let mut sorted = kinds.clone();
    sorted.sort();
    assert_eq!(kinds, sorted, "tiers in order");
    let ids: Vec<&str> = p.candidates.iter().map(|c| c.id.as_str()).collect();
    assert!(!ids.contains(&"alice"), "the viewer is not a recipient");
    assert!(!ids.contains(&"slack-bob"), "a bridge author is never a recipient");
    assert!(!ids.contains(&"bc") && !ids.contains(&"bc/1"), "an unreadable space never shows");
    assert!(!ids.contains(&"ab"), "a pair space folds into its person");

    let bob = p.candidates.iter().find(|c| c.id == "bob").unwrap();
    assert_eq!(bob.space_id.as_deref(), Some("ab"));
    assert!(bob.grants.has(Capability::Post));
    assert_eq!(bob.mode, DeliveryMode::Ask);
    let carol = p.candidates.iter().find(|c| c.id == "carol").unwrap();
    assert_eq!(carol.space_id, None, "no pair space yet");

    let agent = p.candidates.iter().find(|c| c.id == "bobs-agent").unwrap();
    assert_eq!(agent.kind, CandidateKind::Agent);
    assert_eq!(agent.owner.as_deref(), Some("bob"));
    assert_eq!(agent.harness.as_deref(), Some("claude"));
    assert_eq!(agent.status, Some(Status::Active));
    assert!(agent.working);
    assert!(!agent.wake_allowed);
    assert_eq!(agent.mode, DeliveryMode::Ask, "an ungranted wake default is downgraded");
}

#[test]
fn at_handle_resolves_person_and_agent() {
    let (principals, spaces, recent) = fixture();
    let t = team(Grants::all());
    let cx = PickerContext {
        team: &t,
        spaces: &spaces,
        principals: &principals,
        recent: &recent,
        here: &[],
    };
    let p = pick(&principals[0], "@bob", &cx);
    assert_eq!(p.resolved, vec!["bob"]);
    assert_eq!(p.candidates[0].id, "bob");
    let a = pick(&principals[0], "@bobs-agent", &cx);
    assert_eq!(a.resolved, vec!["bobs-agent"]);
    assert_eq!(a.candidates[0].id, "bobs-agent");
    assert!(pick(&principals[0], "@slack-bob", &cx).resolved.is_empty());
}

#[test]
fn wake_granted_by_the_owner_is_suggested() {
    let (principals, mut spaces, recent) = fixture();
    spaces[0].agent_policy.get_mut("bobs-agent").unwrap().wake = true;
    let t = team(Grants::all());
    let cx = PickerContext {
        team: &t,
        spaces: &spaces,
        principals: &principals,
        recent: &recent,
        here: &[],
    };
    let p = pick(&principals[0], "agent", &cx);
    let a = p.candidates.iter().find(|c| c.id == "bobs-agent").unwrap();
    assert!(a.wake_allowed);
    assert_eq!(a.mode, DeliveryMode::Wake);
}

#[test]
fn query_matches_threads_only_where_readable() {
    let (principals, spaces, recent) = fixture();
    let t = team(Grants::all());
    let cx = PickerContext {
        team: &t,
        spaces: &spaces,
        principals: &principals,
        recent: &recent,
        here: &[],
    };
    let p = pick(&principals[0], "flaky", &cx);
    let ids: Vec<&str> = p.candidates.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(ids, vec!["space-1/1"]);
    assert!(pick(&bridged("slack-x", Bridge::Slack), "", &cx).candidates.is_empty());
}
