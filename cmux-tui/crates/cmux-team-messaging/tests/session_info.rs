//! RFD 0170 phase 1, Session Info: the projection shows only what the viewer may read.

mod common;

use std::collections::BTreeMap;

use cmux_team_messaging::backend::{Room, RoomRole};
use cmux_team_messaging::session_info::{Action, SessionContext, Standing, session_info};
use cmux_team_messaging::{Bridge, Grants, LinkGraph, Space, ThreadState, VoteBoard};

use common::*;

fn pair_space() -> Space {
    Space { id: "pair".to_owned(), title: "Pair".to_owned(), ..space(&["alice", "bob"]) }
}

#[test]
fn a_hidden_pair_thread_and_its_rfds_never_show() {
    let t = team(Grants::all());
    let project = space(&["alice", "bob", "carol"]);
    let spaces = vec![project.clone(), pair_space()];
    let principals = vec![
        person("alice", Grants::all()),
        person("bob", Grants::all()),
        person("carol", Grants::all()),
        agent("bobs-agent", "bob", Grants::all()),
    ];
    let mut open = thread("space-1/1");
    open.linked_session_ids = vec!["s1".to_owned()];
    open.linked_rfd_ids = vec!["0170".to_owned()];
    let mut pair = thread("pair/1");
    pair.space_id = "pair".to_owned();
    pair.linked_session_ids = vec!["s1".to_owned()];
    pair.linked_rfd_ids = vec!["0999".to_owned()];
    pair.revision = 9;
    let mut handled = thread("space-1/2");
    handled.linked_session_ids = vec!["s1".to_owned()];
    handled.state = ThreadState::Handled;
    handled.revision = 5;
    let threads = vec![handled, pair, open];
    let room = Room {
        session_id: "s1".to_owned(),
        owner_id: "bob".to_owned(),
        members: vec![
            ("carol".to_owned(), RoomRole::View),
            ("bobs-agent".to_owned(), RoomRole::Talk),
        ],
    };
    let links = LinkGraph::new();
    let titles = BTreeMap::new();
    let board = VoteBoard::new();
    let cx = SessionContext {
        session_id: "s1",
        team: &t,
        space: Some(&project),
        spaces: &spaces,
        principals: &principals,
        threads: &threads,
        room: Some(&room),
        here: &[],
        links: &links,
        titles: &titles,
        messages: &[],
        feedback: &board,
    };

    // Carol is not in the pair space: neither the pair thread nor RFD 0999 shows.
    let carol = session_info(&principals[2], &cx).unwrap();
    assert_eq!(carol.standing, Standing::View);
    let ids: Vec<&str> = carol.threads.iter().map(|l| l.key.id.as_str()).collect();
    assert_eq!(ids, vec!["space-1/1", "space-1/2"], "open first, hidden pair thread absent");
    let rfds: Vec<&str> = carol.rfds.iter().map(|r| r.label.as_str()).collect();
    assert_eq!(rfds, vec!["RFD 0170"]);
    assert_eq!(carol.people[0].principal_id, "bob", "owner first");
    assert_eq!(carol.agents[0].owner.as_deref(), Some("bob"));
    assert!(matches!(&carol.actions[0], Action::OpenThread { target } if target.id == "space-1/1"));
    assert!(carol.actions.iter().any(|a| matches!(a, Action::JoinRoom { .. })));
    assert!(matches!(carol.actions.last(), Some(Action::CopyLink { link }) if link.contains("s1")));

    // Bob reads the pair space: he sees the pair thread and its RFD.
    let bob = session_info(&principals[1], &cx).unwrap();
    assert_eq!(bob.standing, Standing::Owner);
    assert_eq!(bob.threads.len(), 3);
    assert_eq!(bob.rfds.len(), 2);

    // A bridge author holds no cmux rights; an outsider sees nothing.
    assert!(session_info(&bridged("slack-x", Bridge::Slack), &cx).is_none());
    let mut dave = person("dave", Grants::all());
    dave.team_id = "other".to_owned();
    assert!(session_info(&dave, &cx).is_none());
}
