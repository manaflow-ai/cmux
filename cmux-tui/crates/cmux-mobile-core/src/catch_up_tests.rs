use super::*;

#[test]
fn escaped_ids_and_generations_survive_encode_and_decode() {
    let mut cursors = Cursors::default();
    let id = "50%\tdone\n-";
    cursors.chats.insert(id.to_string(), ChatCursor { last_seq: 3, opened_at: 1 });
    cursors.list.tree_revision = Some("-".to_string());
    let decoded = Cursors::decode(&cursors.encode());
    assert_eq!(decoded.chats.get(id).map(|chat| chat.last_seq), Some(3));
    assert_eq!(decoded.list.tree_revision.as_deref(), Some("-"));
    assert_eq!(unescape("%4"), None);
    assert_eq!(unescape("%zz"), None);
}

fn cursors() -> Cursors {
    let mut cursors = Cursors::default();
    for (index, id) in ["a", "b", "c", "d", "e"].into_iter().enumerate() {
        cursors.chats.insert(
            id.to_string(),
            ChatCursor { last_seq: 10 * index as u64, opened_at: index as u64 },
        );
    }
    cursors.terminals.insert(
        "7".to_string(),
        TerminalCursor { offset: 500, generation: "ab.1".into(), replay_bytes: 3000, opened_at: 1 },
    );
    cursors
}

fn bytes(requests: &[Request]) -> u64 {
    requests
        .iter()
        .map(|request| match request {
            Request::Workspaces { .. } | Request::ChatList { .. } => LIST_ESTIMATE_BYTES,
            Request::Chat { max_bytes, .. } => *max_bytes,
            Request::Terminal { .. } => 0,
        })
        .sum()
}

#[test]
fn a_refresh_asks_lists_then_the_three_most_recent_chats_within_the_budget() {
    let requests = plan(&cursors(), &Wake::Refresh, WAKE_BUDGET_BYTES);
    let chats: Vec<_> = requests
        .iter()
        .filter_map(|request| match request {
            Request::Chat { session, after_seq, .. } => Some((session.as_str(), *after_seq)),
            _ => None,
        })
        .collect();
    assert_eq!(chats, [("e", 40), ("d", 30), ("c", 20)]);
    assert!(matches!(requests[0], Request::Workspaces { .. }));
    assert!(matches!(requests[1], Request::ChatList { .. }));
    assert!(bytes(&requests) <= WAKE_BUDGET_BYTES, "{requests:?}");
    assert!(!requests.iter().any(|request| matches!(request, Request::Terminal { .. })));
}

#[test]
fn a_push_asks_its_chat_first_and_a_new_chat_from_the_start() {
    let requests = plan(&cursors(), &Wake::Push { chat: Some("new".into()) }, WAKE_BUDGET_BYTES);
    let Request::Chat { session, after_seq, max_bytes } = &requests[2] else { panic!() };
    assert_eq!((session.as_str(), *after_seq), ("new", 0));
    assert!(*max_bytes >= (WAKE_BUDGET_BYTES - 2 * LIST_ESTIMATE_BYTES) / 2);
    assert_eq!(requests.len(), 2 + 1 + RECENT_CHATS);
    assert!(bytes(&requests) <= WAKE_BUDGET_BYTES);
}

#[test]
fn the_foreground_asks_the_screen_and_bounds_the_terminal_resume_by_its_last_replay() {
    let wake = Wake::Foreground { chat: Some("b".into()), terminal: Some("7".into()) };
    let requests = plan(&cursors(), &wake, WAKE_BUDGET_BYTES);
    assert_eq!(
        &requests[2..],
        [
            Request::Chat {
                session: "b".into(),
                after_seq: 10,
                max_bytes: WAKE_BUDGET_BYTES - 2 * LIST_ESTIMATE_BYTES
            },
            Request::Terminal {
                surface: "7".into(),
                offset: 500,
                generation: "ab.1".into(),
                max_bytes: 3000
            },
        ]
    );
}

#[test]
fn a_spent_budget_stops_the_plan_after_the_lists() {
    let requests = plan(&cursors(), &Wake::Refresh, 2 * LIST_ESTIMATE_BYTES);
    assert_eq!(requests.len(), 2);
}

#[test]
fn a_cursor_never_moves_back_and_a_new_epoch_or_generation_resets_it() {
    let mut cursors = cursors();
    cursors.apply(Reply::Chat { session: "e".into(), through_seq: 45 }, 9);
    cursors.apply(Reply::Chat { session: "e".into(), through_seq: 41 }, 9);
    assert_eq!(cursors.chats["e"].last_seq, 45);

    cursors.apply(Reply::ChatList { through_seq: 8, list_epoch: "x".into() }, 9);
    cursors.apply(Reply::ChatList { through_seq: 5, list_epoch: "x".into() }, 9);
    assert_eq!(cursors.list.list_seq, Some(8));
    cursors.apply(Reply::ChatList { through_seq: 2, list_epoch: "y".into() }, 9);
    assert_eq!(cursors.list.list_seq, Some(2));

    let stamp = |offset, generation: &str, replay| Reply::Terminal {
        surface: "7".into(),
        offset,
        generation: generation.into(),
        replay_bytes: replay,
    };
    cursors.apply(stamp(400, "ab.1", None), 9);
    assert_eq!(cursors.terminals["7"].offset, 500);
    cursors.apply(stamp(900, "ab.1", None), 9);
    assert_eq!(cursors.terminals["7"].offset, 900);
    cursors.apply(stamp(10, "cd.1", Some(2500)), 9);
    let terminal = &cursors.terminals["7"];
    assert_eq!(
        (terminal.offset, terminal.generation.as_str(), terminal.replay_bytes),
        (10, "cd.1", 2500)
    );
}

#[test]
fn a_cut_wake_is_resumed_by_the_next() {
    let mut cursors = cursors();
    // The first wake's answer for "e" held only up to 42 before iOS ended the wake.
    cursors.apply(Reply::Chat { session: "e".into(), through_seq: 42 }, 9);
    let requests = plan(&cursors, &Wake::Refresh, WAKE_BUDGET_BYTES);
    assert!(requests.contains(&Request::Chat {
        session: "e".into(),
        after_seq: 42,
        max_bytes: (WAKE_BUDGET_BYTES - 2 * LIST_ESTIMATE_BYTES) / 2
    }));
}

#[test]
fn cursors_survive_a_relaunch_and_garbage_reads_as_none() {
    let mut cursors = cursors();
    cursors.list = ListCursor {
        tree_revision: Some("rev\t1%".into()),
        list_seq: Some(12),
        list_epoch: Some("-".into()),
        tree_epoch: Some("ep\t-".into()),
        tree_seq: Some(9),
    };
    cursors.chats.insert("we\nird".into(), ChatCursor { last_seq: 3, opened_at: 4 });
    assert_eq!(Cursors::decode(&cursors.encode()), cursors);
    assert_eq!(Cursors::decode(&Cursors::default().encode()), Cursors::default());
    assert_eq!(Cursors::decode(b"cmux-cursors/1\nchat\tx\tnot-a-number\t1\n"), Cursors::default());
    assert_eq!(Cursors::decode(b"something else"), Cursors::default());
}

#[test]
fn the_set_stays_bounded() {
    let mut cursors = Cursors::default();
    for index in 0..(MAX_CHATS as u64 + 50) {
        cursors.opened_chat(&format!("chat-{index}"), index);
    }
    assert_eq!(cursors.chats.len(), MAX_CHATS);
    assert!(!cursors.chats.contains_key("chat-0"));
    assert!(cursors.chats.contains_key(&format!("chat-{}", MAX_CHATS + 49)));
    assert!(cursors.encode().len() < 64 * 1024);
}

fn workspaces(requests: &[Request]) -> (Option<String>, Option<(String, u64)>) {
    let Request::Workspaces { known, since } = &requests[0] else { panic!("{requests:?}") };
    (known.clone(), since.clone())
}

#[test]
fn since_goes_only_to_a_mac_that_lists_the_workspace_delta_capability() {
    // An old Mac's phone lane refuses `since`, an unreviewed field: it is asked by `known`.
    let mut cursors = cursors();
    cursors.list.tree_revision = Some("r1".into());
    cursors.list.tree_epoch = Some("e1".into());
    cursors.list.tree_seq = Some(7);
    cursors.set_capabilities(["terminal-resume-bounded-v1"]);
    assert_eq!(
        workspaces(&plan(&cursors, &Wake::Refresh, WAKE_BUDGET_BYTES)),
        (Some("r1".into()), None)
    );

    // A new Mac gets the cursor it gave last.
    cursors.set_capabilities(["terminal-resume-bounded-v1", WORKSPACE_LIST_DELTA_CAPABILITY]);
    assert_eq!(
        workspaces(&plan(&cursors, &Wake::Refresh, WAKE_BUDGET_BYTES)),
        (Some("r1".into()), Some(("e1".into(), 7)))
    );

    // A relaunch forgets the capability until the Mac lists it again.
    let relaunched = Cursors::decode(&cursors.encode());
    assert!(!relaunched.workspace_delta);
    assert_eq!(workspaces(&plan(&relaunched, &Wake::Refresh, WAKE_BUDGET_BYTES)).1, None);
}

#[test]
fn a_new_mac_with_no_delta_cursor_is_asked_from_the_empty_cursor_for_the_whole_tree() {
    let mut cursors = Cursors::default();
    cursors.set_capabilities([WORKSPACE_LIST_DELTA_CAPABILITY]);
    assert_eq!(
        workspaces(&plan(&cursors, &Wake::Refresh, WAKE_BUDGET_BYTES)),
        (None, Some((String::new(), 0)))
    );
}

#[test]
fn the_delta_cursor_never_moves_back_and_a_new_epoch_resets_it() {
    let mut cursors = Cursors::default();
    let reply = |seq, epoch: &str| Reply::Workspaces {
        revision: format!("r{seq}"),
        delta: Some((epoch.to_string(), seq)),
    };
    cursors.apply(reply(5, "a"), 0);
    cursors.apply(reply(3, "a"), 0);
    assert_eq!((cursors.list.tree_epoch.as_deref(), cursors.list.tree_seq), (Some("a"), Some(5)));
    cursors.apply(reply(1, "b"), 0);
    assert_eq!((cursors.list.tree_epoch.as_deref(), cursors.list.tree_seq), (Some("b"), Some(1)));
    // An old Mac's answer has no delta cursor and leaves it as it was.
    cursors.apply(Reply::Workspaces { revision: "r9".into(), delta: None }, 0);
    assert_eq!(cursors.list.tree_revision.as_deref(), Some("r9"));
    assert_eq!(cursors.list.tree_seq, Some(1));
}
