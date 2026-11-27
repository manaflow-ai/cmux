//! RFD 0170 phase 1, team navigator and search.

mod common;

use std::collections::BTreeMap;

use cmux_sync::presence::Status;

use cmux_team_messaging::navigator::{HitKind, NavContext, SessionEntry, navigator, search};
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
