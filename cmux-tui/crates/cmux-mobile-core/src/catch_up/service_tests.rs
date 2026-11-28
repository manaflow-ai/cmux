use serde_json::json;

use super::*;
use crate::catch_up::{ChatCursor, plan};

fn cursors() -> Cursors {
    let mut cursors = Cursors::default();
    for (index, id) in ["a", "b", "c", "d", "e"].into_iter().enumerate() {
        cursors.chats.insert(
            id.to_string(),
            ChatCursor { last_seq: 10 * index as u64, opened_at: index as u64 },
        );
    }
    cursors.list.tree_revision = Some("r1".into());
    cursors.list.list_seq = Some(40);
    cursors.list.list_epoch = Some("E".into());
    cursors
}

fn foreground(chat: &str) -> Ask {
    Ask::new(Wake::Foreground { chat: Some(chat.into()), terminal: None })
}

#[test]
fn a_foreground_request_carries_every_cursor_the_phone_holds() {
    let mut ask = foreground("b");
    ask.known = Some(json!({"tree_revision": "r9", "generation": "g", "pane_revision": 4}));
    ask.capabilities = vec!["page-tabs-v1".into()];
    ask.chats = vec![("x".into(), Some(7)), ("b".into(), Some(12)), ("a".into(), None)];
    let args = request(&cursors(), &ask);
    assert_eq!(args["v"], json!(1));
    assert_eq!(args["wake"], json!("foreground"));
    assert_eq!(args["budgetBytes"], json!(WAKE_BUDGET_BYTES));
    // The held tree's `known` as the app has it, never a key the Mac refuses.
    assert_eq!(
        args["workspaces"],
        json!({"known": {"tree_revision": "r9", "generation": "g", "pane_revision": 4},
               "capabilities": ["page-tabs-v1"]})
    );
    assert_eq!(args["chatList"], json!({"afterSeq": 40, "listEpoch": "E"}));
    // The chat on screen first, then the ones the app names; the app's lastSeq beats the
    // cursor's, and a chat the app holds no seq for asks from the cursor's.
    assert_eq!(
        args["chats"],
        json!([
            {"sessionId": "b", "lastSeq": 12, "first": "screenful"},
            {"sessionId": "x", "lastSeq": 7, "first": "screenful"},
            {"sessionId": "a", "lastSeq": 0, "first": "screenful"},
        ])
    );
    assert!(args.get("chatKinds").is_none());
    assert!(args.get("terminals").is_none());
}

#[test]
fn a_first_request_asks_for_the_whole_tree_and_list() {
    let args = request(&Cursors::default(), &Ask::new(Wake::Refresh));
    assert_eq!(args["wake"], json!("background"));
    assert_eq!(args["workspaces"], json!({"known": {}}));
    assert_eq!(args["chatList"], json!({}));
    assert_eq!(args["chats"], json!([]));
}

#[test]
fn a_cursor_revision_stands_in_for_a_missing_known_and_half_a_list_cursor_is_not_sent() {
    let mut cursors = cursors();
    cursors.list.list_epoch = None;
    let args = request(&cursors, &Ask::new(Wake::Foreground { chat: None, terminal: None }));
    assert_eq!(args["workspaces"]["known"], json!({"tree_revision": "r1"}));
    assert_eq!(args["chatList"], json!({}));
}

#[test]
fn since_goes_only_to_a_delta_mac_from_a_phone_that_merges_deltas() {
    let mut cursors = cursors();
    cursors.list.tree_epoch = Some("T".into());
    cursors.list.tree_seq = Some(5);
    let mut ask = foreground("a");
    ask.workspace_delta = true;
    // The Mac did not list the capability.
    assert!(request(&cursors, &ask)["workspaces"].get("since").is_none());
    cursors.set_capabilities(["workspace-list-delta-v1"]);
    assert_eq!(request(&cursors, &ask)["workspaces"]["since"], json!({"epoch": "T", "seq": 5}));
    // The phone cannot merge one.
    ask.workspace_delta = false;
    assert!(request(&cursors, &ask)["workspaces"].get("since").is_none());
}

#[test]
fn a_background_wake_adds_the_recent_chats_and_the_request_stops_at_the_macs_limit() {
    let args = request(&cursors(), &Ask::new(Wake::Push { chat: Some("a".into()) }));
    let ids: Vec<&str> = args["chats"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["sessionId"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["a", "e", "d", "c"]);
    assert_eq!(args["chats"][1]["lastSeq"], json!(40));

    let mut ask = foreground("on-screen");
    ask.chats = (0..100).map(|i| (format!("c{i}"), Some(i))).collect();
    ask.budget = 1 << 30;
    ask.chat_kinds = vec!["transcript".into()];
    let args = request(&Cursors::default(), &ask);
    assert_eq!(args["chats"].as_array().unwrap().len(), MAX_CHATS);
    assert_eq!(args["chats"][0]["sessionId"], json!("on-screen"));
    assert_eq!(args["budgetBytes"], json!(MAX_BUDGET_BYTES));
    assert_eq!(args["chatKinds"], json!(["transcript"]));
}

fn reply() -> Value {
    json!({
        "v": 1,
        "workspaces": {"tree_revision": "r2", "workspaces": [{"id": "w"}]},
        "chatList": {"listEpoch": "E", "listSeq": 55, "follow": true, "more": false,
                     "gone": [], "sessions": [{"sessionId": "a"}]},
        "chats": [
            {"sessionId": "a", "events": [{"seq": 31}], "lastSeq": 31, "pageThrough": 31,
             "hasMore": false},
            {"sessionId": "b", "events": [{"seq": 90}, {"seq": 91}], "lastSeq": 92,
             "pageThrough": 91, "hasMore": true, "olderBefore": 90},
        ],
        "cut": [],
        "cutWhy": {},
    })
}

fn bytes(value: &Value) -> Vec<u8> {
    serde_json::to_vec(value).unwrap()
}

#[test]
fn a_reply_reads_into_typed_parts_and_moves_each_cursor() {
    let answer = read(&bytes(&reply())).unwrap();
    assert!(
        matches!(&answer.workspaces, Some(Workspaces::Tree(data)) if data["tree_revision"] == "r2")
    );
    assert_eq!(answer.chat_list.as_ref().unwrap()["sessions"][0]["sessionId"], json!("a"));
    assert_eq!(answer.chats.len(), 2);
    let b = &answer.chats[1];
    assert_eq!((b.through_seq, b.has_more, b.older_before), (Some(91), true, Some(90)));
    assert_eq!(b.page["events"].as_array().unwrap().len(), 2);

    let mut cursors = cursors();
    cursors.apply_catch_up(&answer, 99);
    assert_eq!(cursors.list.tree_revision.as_deref(), Some("r2"));
    assert_eq!((cursors.list.list_seq, cursors.list.list_epoch.as_deref()), (Some(55), Some("E")));
    assert_eq!(cursors.chats["a"].last_seq, 31);
    // `pageThrough`, not `lastSeq`: an event past the page was not applied.
    assert_eq!(cursors.chats["b"].last_seq, 91);
    // A repeated or older answer never moves a cursor back.
    let mut stale = reply();
    stale["chatList"]["listSeq"] = json!(3);
    stale["chats"][1]["pageThrough"] = json!(2);
    cursors.apply_catch_up(&read(&bytes(&stale)).unwrap(), 100);
    assert_eq!(cursors.list.list_seq, Some(55));
    assert_eq!(cursors.chats["b"].last_seq, 91);
}

#[test]
fn a_cut_surface_keeps_its_cursor() {
    let mut cut = reply();
    cut["workspaces"] = json!({"tree_revision": "r-should-not-apply"});
    cut["chats"][1]["pageThrough"] = json!(999);
    cut["cut"] = json!(["workspaces", "chatList", "chats:b", "chats:c"]);
    cut["cutWhy"] = json!({"workspaces": "daemon not reachable", "chatList": "acpmux closed",
                           "chats:b": "budget", "chats:c": "too many chats"});
    let answer = read(&bytes(&cut)).unwrap();
    assert!(answer.workspaces.is_none());
    assert!(answer.chat_list.is_none());
    assert_eq!(answer.chats.iter().map(|c| c.session_id.as_str()).collect::<Vec<_>>(), ["a"]);
    assert_eq!(answer.cut_why["chats:b"], "budget");

    let mut cursors = cursors();
    let before = cursors.clone();
    cursors.apply_catch_up(&answer, 99);
    assert_eq!(cursors.list, before.list);
    assert_eq!(cursors.chats["b"], before.chats["b"]);
    assert_eq!(cursors.chats["c"], before.chats["c"]);
    assert_eq!(cursors.chats["a"].last_seq, 31);
}

#[test]
fn a_chat_the_reply_leaves_out_keeps_its_cursor() {
    let mut partial = reply();
    partial["chats"] = json!([]);
    let mut cursors = cursors();
    cursors.apply_catch_up(&read(&bytes(&partial)).unwrap(), 99);
    assert_eq!(cursors.chats["a"].last_seq, 0);
    assert_eq!(cursors.chats["b"].last_seq, 10);
}

#[test]
fn unchanged_delta_and_reset_answers() {
    let mut cursors = cursors();
    let mut unchanged = reply();
    unchanged["workspaces"] = json!({"unchanged": true});
    let answer = read(&bytes(&unchanged)).unwrap();
    assert!(matches!(answer.workspaces, Some(Workspaces::Unchanged(_))));
    cursors.apply_catch_up(&answer, 1);
    assert_eq!(cursors.list.tree_revision.as_deref(), Some("r1"));

    let mut delta = reply();
    delta["workspaces"] = json!({"delta": true, "epoch": "T", "seq": 8, "changed": [],
                                 "removed": [], "workspaces": []});
    let answer = read(&bytes(&delta)).unwrap();
    assert!(matches!(answer.workspaces, Some(Workspaces::Delta(_))));
    cursors.apply_catch_up(&answer, 1);
    assert_eq!(cursors.list.tree_revision.as_deref(), Some("r1"));
    assert_eq!((cursors.list.tree_epoch.as_deref(), cursors.list.tree_seq), (Some("T"), Some(8)));

    // A stale list cursor is answered with the first page and `reset`: its position stands
    // even when lower than the one held.
    let mut reset = reply();
    reset["chatList"] = json!({"listEpoch": "E", "listSeq": 2, "reset": true, "sessions": []});
    cursors.apply_catch_up(&read(&bytes(&reset)).unwrap(), 1);
    assert_eq!(cursors.list.list_seq, Some(2));
}

#[test]
fn a_bad_frame_is_an_error_not_a_cursor_move() {
    assert!(matches!(read(b"not json"), Err(ReadError::NotJson(_))));
    assert_eq!(read(b"[1]"), Err(ReadError::NotAnObject));
    assert_eq!(read(br#"{"v":2}"#), Err(ReadError::Version(Some(2))));
    assert_eq!(read(br#"{}"#), Err(ReadError::Version(None)));
}

#[test]
fn only_a_mac_without_the_service_falls_back_to_todays_calls() {
    assert!(falls_back(UNKNOWN_SERVICE));
    for code in ["bad_request", "timeout", "eof", "closed", ""] {
        assert!(!falls_back(code), "{code}");
    }
    // Today's calls ask by the same cursors.
    let requests =
        plan(&cursors(), &Wake::Foreground { chat: Some("b".into()), terminal: None }, 0);
    assert!(
        matches!(&requests[0], crate::catch_up::Request::Workspaces { known: Some(r), .. } if r == "r1")
    );
}
