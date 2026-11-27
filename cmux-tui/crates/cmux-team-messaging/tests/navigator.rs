//! RFD 0170 phase 1, team navigator and search.

mod common;

use std::collections::BTreeMap;

use cmux_sync::presence::Status;

use cmux_team_messaging::navigator::{
    HitKind, LIVE_PREVIEW, NavContext, SessionEntry, navigator, search,
};
use cmux_team_messaging::presence::Participant;
use cmux_team_messaging::refs::RefKey;
use cmux_team_messaging::{
    Bridge, Grants, PrincipalKind, RefKind, RefSource, Space, SpaceKind, Team,
};

use common::*;

fn live(id: &str, kind: PrincipalKind) -> Participant {
    Participant {
        principal_id: id.to_owned(),
        kind,
        name: id.to_owned(),
        status: Status::Active,
        working: false,
    }
}

#[test]
fn sidebar_lists_teams_readable_spaces_unread_and_live() {
    let principals = vec![
        person("alice", Grants::all()),
        person("bob", Grants::all()),
        agent("bobs-agent", "bob", Grants::all()),
        bridged("slack-x", Bridge::Slack),
    ];
    let mut t = team(Grants::all());
    t.spaces = vec!["space-1".to_owned(), "aa".to_owned()];
    let other = Team {
        id: "team-b".to_owned(),
        name: "Team B".to_owned(),
        members: vec!["alice".to_owned()],
        ..team(Grants::all())
    };
    let stranger =
        Team { id: "team-c".to_owned(), name: "Team C".to_owned(), ..team(Grants::all()) };
    let teams = vec![t, other, stranger];
    let project = space(&["alice", "bob", "bobs-agent", "slack-x"]);
    let first = Space { id: "aa".to_owned(), title: "Alpha".to_owned(), ..space(&["alice"]) };
    let zz = Space { id: "zz".to_owned(), title: "Zed".to_owned(), ..space(&["alice"]) };
    let hidden = Space {
        id: "bc".to_owned(),
        kind: SpaceKind::Pair,
        title: "Bob only".to_owned(),
        ..space(&["bob"])
    };
    let spaces = vec![zz, hidden, first, project];
    let mut secret = thread("bc/1");
    secret.space_id = "bc".to_owned();
    secret.subject = "Deploy secret".to_owned();
    let mut t1 = thread("space-1/1");
    t1.subject = "Deploy plan".to_owned();
    let threads = vec![t1, thread("space-1/2"), secret];
    let unread: BTreeMap<String, u32> =
        [("space-1/1".to_owned(), 2), ("space-1/2".to_owned(), 1), ("bc/1".to_owned(), 7)].into();
    let here: BTreeMap<String, Vec<Participant>> = [(
        "space-1".to_owned(),
        vec![
            live("bob", PrincipalKind::Person),
            live("bobs-agent", PrincipalKind::Agent),
            live("slack-x", PrincipalKind::Person),
            live("dave", PrincipalKind::Person),
        ],
    )]
    .into();
    let sessions = vec![
        SessionEntry {
            id: "s1".to_owned(),
            title: "Deploy session".to_owned(),
            space_id: "space-1".to_owned(),
        },
        SessionEntry {
            id: "s2".to_owned(),
            title: "Deploy hidden".to_owned(),
            space_id: "bc".to_owned(),
        },
    ];
    let rfds = vec![(
        RefKey::new(RefKind::Rfd, RefSource::Hq, "170").unwrap(),
        "Native team messaging".to_owned(),
    )];
    let cx = NavContext {
        teams: &teams,
        current_team_id: TEAM,
        spaces: &spaces,
        principals: &principals,
        threads: &threads,
        unread: &unread,
        here: &here,
        sessions: &sessions,
        rfds: &rfds,
    };

    let nav = navigator(&principals[0], &cx).unwrap();
    let teams: Vec<(&str, bool)> = nav.teams.iter().map(|t| (t.id.as_str(), t.current)).collect();
    assert_eq!(
        teams,
        vec![(TEAM, true), ("team-b", false)],
        "a team the viewer is not in never shows"
    );
    assert_eq!(nav.teams[0].unread, 3, "a hidden space's unread is not counted");
    let ids: Vec<&str> = nav.spaces.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, vec!["space-1", "aa", "zz"], "team order, then title; hidden space absent");
    let p = &nav.spaces[0];
    assert_eq!((p.unread, p.open), (3, 2));
    let people: Vec<&str> = p.people.iter().map(|r| r.principal_id.as_str()).collect();
    assert_eq!(people, vec!["bob"], "bridge authors and non-members are not live rows");
    assert_eq!(p.agents[0].principal_id, "bobs-agent");
    assert_eq!((p.people_live, p.agents_live), (1, 1));

    let hits = search(&principals[0], "deploy", &cx);
    let found: Vec<(HitKind, &str)> = hits.iter().map(|h| (h.kind, h.id.as_str())).collect();
    assert_eq!(found, vec![(HitKind::Thread, "space-1/1"), (HitKind::Session, "s1")]);
    let rfd = search(&principals[0], "0170", &cx);
    assert_eq!(rfd[0].kind, HitKind::Rfd);
    assert_eq!(rfd[0].open.as_ref().unwrap().canonical(), "rfd:hq/0170");
    let agent = search(&principals[0], "agent", &cx);
    assert_eq!(agent[0].kind, HitKind::Agent);
    assert_eq!(agent[0].detail.as_deref(), Some("bob"));
    assert!(search(&principals[0], "slack", &cx).is_empty());
    assert!(navigator(&principals[3], &cx).is_none());
}

/// The duress number, at the acpmux surfaces scale: a 1000-person, 1000-agent team, 200 spaces of
/// ~300 members with a third of each live, 5000 threads (a quarter unread) and 1000 sessions.
/// Times one sidebar: `navigator` plus `search`, as the `_acpmux/team/navigator` RPC answers.
/// Prints a digest of every answer so a change can show the output is the same. Run with
/// `--release -- --ignored --nocapture`; the assertion is a loose ceiling.
#[test]
#[ignore = "measurement"]
fn navigator_at_team_scale() {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    use std::time::Instant;

    use cmux_team_messaging::{RootKind, Thread, ThreadState};

    let mut principals = vec![person("viewer", Grants::all())];
    for i in 0..1000 {
        let mut p = person(&format!("p{i}"), Grants::all());
        p.display_name = format!("Person {i}");
        principals.push(p);
    }
    for i in 0..1000 {
        let mut a = agent(&format!("a{i}"), &format!("p{i}"), Grants::all());
        a.display_name = format!("Agent {i}");
        principals.push(a);
    }
    let ids: Vec<String> = principals.iter().map(|p| p.id.clone()).collect();
    let spaces: Vec<Space> = (0..200)
        .map(|s| {
            let mut members: Vec<String> =
                (0..300).map(|k| ids[(s * 37 + k * 7) % ids.len()].clone()).collect();
            members.push("viewer".into());
            members.sort();
            members.dedup();
            Space {
                id: format!("space{s}"),
                kind: if s % 10 == 0 { SpaceKind::Pair } else { SpaceKind::Project },
                title: format!("Space {s}"),
                members,
                ..space(&[])
            }
        })
        .collect();
    let mut t = team(Grants::all());
    t.spaces = (0..200).rev().step_by(3).map(|s| format!("space{s}")).collect();
    let teams = vec![t];
    let threads: Vec<Thread> = (0..5000)
        .map(|n| Thread {
            id: format!("thread{n}"),
            space_id: format!("space{}", n % 200),
            root_kind: RootKind::Message,
            subject: format!("Subject {n}"),
            participants: vec!["viewer".into(), ids[(n * 13) % ids.len()].clone()],
            linked_rfd_ids: Vec::new(),
            linked_session_ids: vec![format!("sa{}", n % 1000)],
            revision: n as u64,
            state: if n % 5 == 0 { ThreadState::Closed } else { ThreadState::Open },
        })
        .collect();
    let unread: BTreeMap<String, u32> =
        threads.iter().step_by(4).map(|t| (t.id.clone(), 1)).collect();
    let here: BTreeMap<String, Vec<Participant>> = spaces
        .iter()
        .map(|s| {
            let live = s
                .members
                .iter()
                .enumerate()
                .filter(|(i, _)| i % 3 == 0)
                .map(|(_, id)| {
                    let kind = if id.starts_with('a') {
                        PrincipalKind::Agent
                    } else {
                        PrincipalKind::Person
                    };
                    let mut p = live(id, kind);
                    p.name = format!("Name {id}");
                    p
                })
                .collect();
            (s.id.clone(), live)
        })
        .collect();
    let sessions: Vec<SessionEntry> = (0..1000)
        .map(|i| SessionEntry {
            id: format!("sa{i}"),
            title: format!("Session {i}"),
            space_id: format!("space{}", i % 200),
        })
        .collect();
    let rfds: Vec<(RefKey, String)> = (0..200)
        .map(|i| {
            let key = RefKey::new(RefKind::Rfd, RefSource::Hq, &format!("{i:04}")).unwrap();
            (key, format!("Design {i}"))
        })
        .collect();
    let cx = NavContext {
        teams: &teams,
        current_team_id: TEAM,
        spaces: &spaces,
        principals: &principals,
        threads: &threads,
        unread: &unread,
        here: &here,
        sessions: &sessions,
        rfds: &rfds,
    };

    let mut samples = Vec::new();
    let mut digest = DefaultHasher::new();
    for q in ["", "p", "name 99", "@a12", "subject 4", "space 1", "0170"] {
        let mut per = Vec::new();
        for i in 0..20 {
            let start = Instant::now();
            let nav = navigator(&principals[0], &cx).unwrap();
            let hits = search(&principals[0], q, &cx);
            per.push(start.elapsed());
            if i == 0 {
                assert_eq!(nav.spaces.len(), 200);
                serde_json::to_string(&(&nav, &hits)).unwrap().hash(&mut digest);
            }
        }
        per.sort();
        println!("navigator+search {q:?}: median {:?}", per[per.len() / 2]);
        samples.extend(per);
    }
    samples.sort();
    let p50 = samples[samples.len() / 2];
    let p95 = samples[samples.len() * 95 / 100];
    println!("navigator+search p50 {p50:?} p95 {p95:?} over {} samples", samples.len());
    println!("navigator+search output digest {:016x}", digest.finish());
    assert!(p95.as_millis() < 5000);

    // What the RPC adds on top: the answer turned into JSON, as `_acpmux/team/navigator` sends it.
    let nav = navigator(&principals[0], &cx).unwrap();
    let hits = search(&principals[0], "", &cx);
    let mut ser = Vec::new();
    let mut bytes = 0;
    for _ in 0..20 {
        let start = Instant::now();
        let mut v = serde_json::to_value(&nav).unwrap();
        v["hits"] = serde_json::json!(hits);
        bytes = serde_json::to_string(&v).unwrap().len();
        ser.push(start.elapsed());
    }
    ser.sort();
    let live: u32 = nav.spaces.iter().map(|s| s.people_live + s.agents_live).sum();
    println!(
        "navigator json p50 {:?} p95 {:?}: {bytes} bytes, {} spaces, {live} live rows",
        ser[ser.len() / 2],
        ser[ser.len() * 95 / 100],
        nav.spaces.len()
    );
}

#[test]
fn a_crowded_space_sends_the_first_live_rows_by_name_and_counts_the_rest() {
    let mut principals = vec![person("viewer", Grants::all())];
    let mut members = vec!["viewer".to_owned()];
    let mut live_here = Vec::new();
    for i in (0..30).rev() {
        let id = format!("p{i:02}");
        principals.push(person(&id, Grants::all()));
        members.push(id.clone());
        live_here.push(live(&id, PrincipalKind::Person));
    }
    let teams = vec![team(Grants::all())];
    let spaces = vec![Space { id: "crowd".into(), members, ..space(&[]) }];
    let here = BTreeMap::from([("crowd".to_owned(), live_here)]);
    let cx = NavContext {
        teams: &teams,
        current_team_id: TEAM,
        spaces: &spaces,
        principals: &principals,
        threads: &[],
        unread: &BTreeMap::new(),
        here: &here,
        sessions: &[],
        rfds: &[],
    };
    let row = &navigator(&principals[0], &cx).unwrap().spaces[0];
    let shown: Vec<&str> = row.people.iter().map(|r| r.principal_id.as_str()).collect();
    let want: Vec<String> = (0..LIVE_PREVIEW).map(|i| format!("p{i:02}")).collect();
    assert_eq!(shown, want, "the first by name, in order, whatever order presence came in");
    assert_eq!((row.people_live, row.agents_live), (30, 0));
}
