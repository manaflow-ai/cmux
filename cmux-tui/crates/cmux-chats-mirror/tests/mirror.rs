//! The chat mirror's behavior: what the Swift ChatsFeed and AcpmuxChatsStore did, plus the
//! seq bookkeeping that had no test in Swift.

use cmux_chats_mirror::ffi::*;
use cmux_chats_mirror::{Change, Feed, Line};
use serde_json::{Value, json};

fn chat(key: &str, updated: i64) -> Value {
    let (harness, session) = key.split_once(':').unwrap_or(("claude-code", key));
    json!({"key": key, "sessionId": session, "harness": harness, "updatedMs": updated})
}

fn page(id: i64, chats: Vec<Value>, seq: Option<u64>) -> Line {
    let line = json!({"jsonrpc": "2.0", "id": id, "result": {"chats": chats, "ready": true, "enabled": true, "seq": seq}});
    Line::parse(line.to_string().as_bytes()).expect("a page line")
}

fn changed(params: Value) -> Line {
    let line = json!({"jsonrpc": "2.0", "method": "_acpmux/chat_changed", "params": params});
    Line::parse(line.to_string().as_bytes()).expect("a change line")
}

fn listed(feed: &Feed) -> Vec<String> {
    feed.index().listed().map(|chat| chat.key.to_string()).collect()
}

#[test]
fn a_page_lists_newest_first_without_child_chats() {
    let mut feed = Feed::new();
    let mut child = chat("claude-code:3", 1_000);
    child["parent"] = json!("claude-code:1");
    let mut titled = chat("claude-code:1", 3_000);
    titled["title"] = json!("Fix the build");
    let mut untitled = chat("codex:2", 2_000);
    untitled["title"] = json!("");
    let outcome =
        feed.apply([page(2, vec![chat("claude-code:4", 500), titled, child, untitled], Some(7))]);
    assert!(outcome.changed && outcome.page && outcome.index_changed && !outcome.lagged);
    assert_eq!(listed(&feed), ["claude-code:1", "codex:2", "claude-code:4"]);
    assert_eq!(feed.index().len(), 4);
    assert_eq!(
        feed.index().get("claude-code:1").and_then(|c| c.title.as_deref()),
        Some("Fix the build")
    );
    assert_eq!(feed.index().get("codex:2").and_then(|c| c.title.as_deref()), None);
    assert!(feed.is_ready() && feed.is_enabled());
}

#[test]
fn equal_times_order_by_key_and_a_repeated_key_keeps_its_first_chat() {
    let mut feed = Feed::new();
    let mut again = chat("codex:b", 9_000);
    again["title"] = json!("second");
    feed.apply([page(2, vec![chat("codex:b", 1_000), chat("codex:a", 1_000), again], None)]);
    assert_eq!(listed(&feed), ["codex:a", "codex:b"]);
    assert_eq!(feed.index().get("codex:b").map(|c| c.updated_ms), Some(1_000.0));
}

#[test]
fn a_wrongly_typed_field_reads_as_absent_and_a_chat_without_its_ids_is_dropped() {
    let mut odd = chat("codex:1", 1_000);
    odd["title"] = json!(42);
    odd["accounts"] = json!(["me", 3]);
    odd["roots"] = json!(["r1", "r2"]);
    odd["messageCount"] = json!("many");
    odd["unknown"] = json!({"nested": [1, 2]});
    let nameless = json!({"key": "codex:2", "sessionId": "2", "updatedMs": 5});
    let mut feed = Feed::new();
    feed.apply([page(2, vec![odd, nameless], None)]);
    let kept = feed.index().get("codex:1").expect("kept");
    assert_eq!(kept.title, None);
    assert!(kept.accounts.is_empty());
    assert_eq!(kept.roots.len(), 2);
    assert_eq!(kept.message_count, None);
    assert!(feed.index().get("codex:2").is_none());
}

#[test]
fn updated_at_stands_in_for_updated_ms() {
    let mut feed = Feed::new();
    feed.apply([page(
        2,
        vec![json!({"key": "codex:1", "sessionId": "1", "harness": "codex", "updatedAt": 77})],
        None,
    )]);
    assert_eq!(feed.index().get("codex:1").map(|c| c.updated_ms), Some(77.0));
}

#[test]
fn other_lines_are_not_watch_lines() {
    assert!(Line::parse(br#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#).is_none());
    assert!(
        Line::parse(br#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{}}"#)
            .is_none()
    );
    assert!(
        Line::parse(
            br#"{"jsonrpc":"2.0","method":"_acpmux/chat_changed","params":{"kind":"upsert"}}"#
        )
        .is_none()
    );
    assert!(Line::parse(b"not json").is_none());
    assert!(matches!(Line::parse(br#"{"method":"_acpmux/chats_lagged"}"#), Some(Line::Lagged)));
}

#[test]
fn an_upsert_moves_its_chat_and_a_removal_drops_it() {
    let mut feed = Feed::new();
    feed.apply([page(
        2,
        vec![chat("codex:1", 3_000), chat("codex:2", 2_000), chat("codex:3", 1_000)],
        Some(10),
    )]);
    let generation = feed.generation();
    let outcome = feed.apply([
        changed(
            json!({"kind": "upsert", "seq": 11, "key": "codex:3", "chat": chat("codex:3", 4_000)}),
        ),
        changed(json!({"kind": "removed", "seq": 12, "key": "codex:2"})),
    ]);
    assert!(outcome.changed && outcome.index_changed && !outcome.lagged);
    assert_eq!(listed(&feed), ["codex:3", "codex:1"]);
    assert!(feed.generation() > generation);
}

#[test]
fn activity_keeps_the_place_and_the_generation() {
    let mut feed = Feed::new();
    feed.apply([page(2, vec![chat("codex:1", 3_000), chat("codex:2", 2_000)], Some(1))]);
    let generation = feed.generation();
    let outcome = feed.apply([changed(
        json!({"kind": "activity", "key": "codex:2", "attention": "unread", "preview": ""}),
    )]);
    assert!(outcome.changed && !outcome.index_changed);
    assert_eq!(feed.generation(), generation);
    assert_eq!(listed(&feed), ["codex:1", "codex:2"]);
    let two = feed.index().get("codex:2").expect("chat");
    assert_eq!(two.attention.as_deref(), Some("unread"));
    assert_eq!(two.preview.as_deref(), Some(""), "an empty preview is kept, not absent");

    // Activity that folds a chat under a parent changes the listed set.
    let outcome =
        feed.apply([changed(json!({"kind": "activity", "key": "codex:2", "parent": "codex:1"}))]);
    assert!(outcome.index_changed);
    assert_eq!(listed(&feed), ["codex:1"]);
}

#[test]
fn a_change_the_mirror_holds_is_skipped_and_a_jump_asks_for_a_list() {
    let mut feed = Feed::new();
    feed.apply([page(2, vec![chat("codex:1", 1_000)], Some(5))]);
    let outcome = feed.apply([changed(json!({"kind": "removed", "seq": 5, "key": "codex:1"}))]);
    assert!(!outcome.lagged);
    assert!(feed.index().get("codex:1").is_some(), "seq 5 is already in the page");
    let outcome = feed.apply([changed(
        json!({"kind": "upsert", "seq": 7, "key": "codex:2", "chat": chat("codex:2", 2_000)}),
    )]);
    assert!(outcome.lagged, "seq 6 was lost");
    assert!(feed.index().get("codex:2").is_some(), "the change still applies");
}

#[test]
fn changes_during_a_page_replay_on_top_of_it() {
    let mut feed = Feed::new();
    feed.connection_started();
    let outcome = feed.apply([
        changed(json!({"kind": "upsert", "seq": 4, "key": "codex:old", "chat": chat("codex:old", 9_000)})),
        changed(json!({"kind": "upsert", "seq": 6, "key": "codex:new", "chat": chat("codex:new", 8_000)})),
    ]);
    assert!(!outcome.changed, "held until the page lands");
    let outcome = feed.apply([page(2, vec![chat("codex:1", 1_000)], Some(5))]);
    assert!(outcome.changed && !outcome.lagged);
    assert_eq!(listed(&feed), ["codex:new", "codex:1"], "seq 4 is in the page; seq 6 replays");
}

#[test]
fn too_many_changes_during_a_page_list_again_after_it() {
    let mut feed = Feed::new();
    feed.connection_started();
    let flood: Vec<Line> = (0..=cmux_chats_mirror::feed::EARLY_LIMIT as u64)
        .map(|seq| changed(json!({"kind": "removed", "seq": seq + 10, "key": "codex:x"})))
        .collect();
    feed.apply(flood);
    let outcome = feed.apply([page(2, vec![], Some(9))]);
    assert!(outcome.lagged);
}

#[test]
fn one_list_at_a_time() {
    let mut feed = Feed::new();
    feed.apply([page(2, vec![], Some(0))]);
    assert!(feed.want_list(), "nothing in flight: send");
    assert!(!feed.want_list(), "one in flight: queued");
    let outcome = feed.apply([page(3, vec![], Some(0))]);
    assert!(outcome.lagged, "the queued list is due now");
    assert!(feed.want_list());
}

#[test]
fn a_new_connection_numbers_from_the_start_again() {
    let mut feed = Feed::new();
    feed.apply([page(2, vec![], Some(100))]);
    feed.connection_started();
    feed.apply([page(2, vec![], Some(0))]);
    let outcome = feed.apply([changed(
        json!({"kind": "upsert", "seq": 1, "key": "codex:1", "chat": chat("codex:1", 1)}),
    )]);
    assert!(!outcome.lagged);
    assert!(feed.index().get("codex:1").is_some());
}

#[test]
fn projects_keep_each_folder_newest_chat_per_harness() {
    let mut feed = Feed::new();
    let with = |key: &str, cwd: &str, updated: i64| {
        let mut value = chat(key, updated);
        value["cwd"] = json!(cwd);
        value
    };
    let mut child = with("codex:4", "/child", 9_000);
    child["parent"] = json!("codex:1");
    feed.apply([page(
        2,
        vec![
            with("codex:1", "/a", 1_000),
            with("codex:2", "/a", 3_000),
            with("codex:3", "relative", 4_000),
            child,
            with("claude-code:5", "/b", 2_000),
        ],
        None,
    )]);
    let projects = serde_json::to_value(feed.index().projects()).expect("json");
    assert_eq!(projects, json!({"claude-code": {"/b": 2_000}, "codex": {"/a": 3_000}}));
}

#[test]
fn a_session_finds_its_newest_chat() {
    let mut feed = Feed::new();
    feed.apply([page(2, vec![chat("codex:s", 1_000), chat("claude-code:s", 2_000)], None)]);
    assert_eq!(feed.index().by_session("s").map(|c| c.key.as_ref()), Some("claude-code:s"));
    let removed = feed.index().clone();
    let mut index = removed;
    index.apply(Change::Removed { key: "claude-code:s".into() });
    assert_eq!(index.by_session("s").map(|c| c.key.as_ref()), Some("codex:s"));
}

fn text(text: CmuxChatsText) -> Option<String> {
    if text.ptr.is_null() {
        return None;
    }
    // SAFETY: a row's text points into its live snapshot.
    let bytes = unsafe { std::slice::from_raw_parts(text.ptr, text.len) };
    Some(String::from_utf8_lossy(bytes).into_owned())
}

#[test]
fn the_c_abi_parses_applies_and_reads_rows() {
    unsafe {
        let feed = cmux_chats_feed_new();
        cmux_chats_feed_connection_started(feed);
        let mut first = chat("codex:1", 2_000);
        first["accounts"] = json!(["me", "work"]);
        first["preview"] = json!("");
        let page = json!({"id": 2, "result": {"chats": [first, chat("codex:2", 1_000)], "ready": true, "seq": 1}}).to_string();
        let lines = [
            cmux_chats_line_parse(page.as_ptr(), page.len()),
            cmux_chats_line_parse(b"garbage".as_ptr(), 7),
        ];
        assert!(lines[1].is_null());
        let flags = cmux_chats_feed_apply(feed, lines.as_ptr(), lines.len());
        assert_eq!(flags & (CHANGED | PAGE | INDEX_CHANGED), CHANGED | PAGE | INDEX_CHANGED);
        assert_eq!(cmux_chats_feed_status(feed), READY | ENABLED);
        assert_eq!(cmux_chats_feed_count(feed), 2);

        let rows = cmux_chats_feed_listed(feed, 1, 10);
        let mut count = 0;
        let items = cmux_chats_rows_items(rows, &mut count);
        assert_eq!(count, 1);
        assert_eq!(text((*items).key).as_deref(), Some("codex:2"));
        cmux_chats_rows_free(rows);

        let key = "codex:1";
        let rows = cmux_chats_feed_chat(feed, key.as_ptr(), key.len());
        let items = cmux_chats_rows_items(rows, &mut count);
        assert_eq!(count, 1);
        let row = *items;
        assert_eq!(text(row.preview).as_deref(), Some(""));
        assert_eq!(text(row.title), None);
        let accounts: Vec<_> =
            (0..row.accounts_len).filter_map(|i| text(*row.accounts.add(i))).collect();
        assert_eq!(accounts, ["me", "work"]);
        assert_eq!(row.updated_ms, 2_000.0);
        assert_eq!(row.has_created, 0);
        cmux_chats_rows_free(rows);

        assert_eq!(cmux_chats_feed_want_list(feed), 1);
        assert_eq!(cmux_chats_feed_want_list(feed), 0);

        let result = json!({"chats": [chat("codex:9", 5)]}).to_string();
        assert_eq!(cmux_chats_feed_load(feed, result.as_ptr(), result.len()), 0);
        assert_eq!(cmux_chats_feed_count(feed), 1);

        let projects = cmux_chats_feed_projects(feed);
        let mut len = 0;
        let data = cmux_chats_bytes_data(projects, &mut len);
        assert_eq!(std::slice::from_raw_parts(data, len), b"{}");
        cmux_chats_bytes_free(projects);
        cmux_chats_feed_free(feed);
    }
}
