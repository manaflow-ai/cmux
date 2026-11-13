//! The list text's tests (`list_guard.rs`): a page and a read with no `limit` are the bytes the
//! summaries write, a read builds only the rows it sends, and the closed rows' cached bytes are
//! the rows an uncached build gives after every change.

use super::*;
use crate::config::Config;

fn sorted(mut rows: Vec<Value>) -> Vec<Value> {
    super::super::session_pages::sort_session_summaries(&mut rows);
    rows
}

/// [`bounded`] of rows already built, each sent as it serializes.
fn bounded_text(rows: &[Value], params: &Value, budget: usize) -> String {
    bounded(rows, Value::to_string, params, budget).unwrap()
}

/// A page cut from its rows' text, and a read with no `limit`, are the bytes the summaries write,
/// as `session_list_reply` picks them: every filter, a cursor, and no row twice.
#[test]
fn a_page_and_a_whole_read_are_the_bytes_the_summaries_write() {
    let rows = sorted(
        (0..5)
            .map(|i| json!({"sessionId": format!("s{i}"), "updatedAt": 10 - i, "x": "q\"\n",
                "status": if i % 2 == 0 { "idle" } else { "closed" }, "peer": (i == 3).then_some("cmux16")}))
            .collect(),
    );
    let built = serialize_in_order(&rows);
    assert_eq!(built.0, json!({"sessions": rows}).to_string());
    assert_eq!(serialize_in_order(&[]).0, r#"{"sessions":[]}"#);
    let reply = |p: &Value| super::super::session_pages::session_list_reply(rows.clone(), p);
    let next = reply(&json!({"limit": 2})).unwrap()["nextCursor"].clone();
    for params in [
        json!({"limit": 2}),
        json!({"limit": 2, "cursor": next}),
        json!({"limit": 9}),
        json!({"peer": "cmux16", "limit": 1}),
    ] {
        let picked = super::super::session_pages::pick_page(&rows, &params).unwrap();
        let keys: Vec<Value> =
            picked.rows.iter().map(|&at| built.2.get(at).cloned().unwrap()).collect();
        let text = (built.0.as_str(), built.1.as_slice());
        let page = cut_page(text, &keys, picked.next, &params, usize::MAX);
        assert_eq!(page, reply(&params).unwrap().to_string(), "{params}");
    }
    for params in [json!({}), json!({"status": "idle"}), json!({"peer": "cmux16"})] {
        let text = bounded_text(&rows, &params, usize::MAX);
        assert_eq!(text, reply(&params).unwrap().to_string(), "{params}");
    }
    assert!(bounded(&rows, Value::to_string, &json!({"cursor": 3}), usize::MAX).is_err());
}

/// A read with no `limit` of 3,000 rows builds the rows that fit in its page, and the ones its
/// next page starts with, never the list: on 2026-11-12 the list was built whole first (6.77 s at
/// p95 with 11,000 chats), shared, and paced, so a reconnect storm waited behind it.
#[test]
fn a_whole_read_builds_only_the_rows_it_sends() {
    let rows = sorted(
        (0..3_000)
            .map(|i| {
                json!({"sessionId": format!("s{i:04}"), "updatedAt": 3_000 - i,
                "pad": "x".repeat(100)})
            })
            .collect(),
    );
    let made = std::cell::Cell::new(0_usize);
    let text = |row: &Value| {
        made.set(made.get() + 1);
        row.to_string()
    };
    let first: Value =
        serde_json::from_str(&bounded(&rows, text, &json!({}), 16 << 10).unwrap()).unwrap();
    let listed = first["sessions"].as_array().unwrap().len();
    assert!(listed > 50 && first["nextCursor"].is_string(), "{listed} rows");
    // The rows that fit in a list-order try, then the byte page's own: about two pages.
    assert!(made.get() <= 3 * listed, "{} rows built for a page of {listed}", made.get());
    // Every row once, page by page.
    let (mut seen, mut params) = (std::collections::BTreeSet::new(), json!({}));
    loop {
        let page: Value = serde_json::from_str(&bounded_text(&rows, &params, 16 << 10)).unwrap();
        for row in page["sessions"].as_array().unwrap() {
            assert!(seen.insert(row["sessionId"].as_str().unwrap().to_owned()), "{row}");
        }
        match page.get("nextCursor") {
            Some(next) => params = json!({"cursor": next}),
            None => break,
        }
    }
    assert_eq!(seen.len(), 3_000);
}

/// A list read from a session list cursor (`k...`) with no `limit`, too large for one page,
/// keeps that cursor's cutoff on every page: the rows after the session it names, each once.
#[test]
fn byte_pages_of_a_list_after_a_session_cursor_keep_its_cutoff() {
    let rows = sorted(
        ["a", "b", "c", "d", "e", "f"]
            .iter()
            .enumerate()
            .map(|(i, id)| json!({"sessionId": id, "updatedAt": 10 - i, "pad": "x".repeat(40)}))
            .collect(),
    );
    let after_b =
        super::super::session_pages::session_list_reply(rows.clone(), &json!({"limit": 2}))
            .unwrap()["nextCursor"]
            .clone();
    let (mut read, mut params) = (Vec::new(), json!({"cursor": after_b}));
    for _ in 0..10 {
        let page: Value = serde_json::from_str(&bounded_text(&rows, &params, 150)).unwrap();
        let listed = page["sessions"].as_array().unwrap();
        read.extend(listed.iter().map(|r| r["sessionId"].as_str().unwrap().to_owned()));
        match page.get("nextCursor") {
            Some(next) => params["cursor"] = next.clone(),
            None => break,
        }
    }
    read.sort();
    assert_eq!(read, ["c", "d", "e", "f"]);
}

#[test]
fn a_row_larger_than_its_page_goes_as_a_stub_with_its_keys() {
    let rows = sorted(vec![
        json!({"sessionId": "big", "updatedAt": 9, "peer": "box", "status": "idle",
            "preview": "x".repeat(5000)}),
        json!({"sessionId": "small", "updatedAt": 5, "status": "idle"}),
    ]);
    let first: Value = serde_json::from_str(&bounded_text(&rows, &json!({}), 1000)).unwrap();
    // Pages go in an order updates do not change (`byte_page`), not newest first.
    let listed = first["sessions"].as_array().unwrap();
    let by_id = |id: &str| listed.iter().find(|r| r["sessionId"] == id).unwrap();
    let stub = by_id("big");
    assert_eq!((&stub["peer"], &stub["updatedAt"]), (&json!("box"), &json!(9)));
    assert_eq!(stub["omitted"]["reason"], "too_large");
    assert!(stub["omitted"]["bytes"].as_u64().unwrap() > 5000, "{stub}");
    assert!(stub.get("preview").is_none(), "{stub}");
    // The stub is small, so the next row goes on its page.
    assert_eq!(listed.len(), 2, "{first}");
    assert_eq!(by_id("small"), &rows[1], "{first}");
    assert!(first.get("nextCursor").is_none(), "{first}");
}

fn list_of(hub: &Hub, with_tools: bool, own_only: bool) -> Vec<Value> {
    let text = hub.session_list_text(&json!({}), with_tools, own_only, usize::MAX).unwrap();
    let list: Value = serde_json::from_str(&text).unwrap();
    list["sessions"].as_array().cloned().unwrap_or_default()
}

fn cached_rows_equal_uncached(hub: &Hub) {
    let mut uncached: Vec<Value> =
        hub.sessions().iter().map(|session| hub.session_summary(session)).collect();
    super::super::session_pages::sort_session_summaries(&mut uncached);
    assert_eq!(hub.all_session_summaries(), uncached);

    let mut uncached_list: Vec<Value> =
        hub.sessions().iter().map(|session| hub.session_list_summary(session)).collect();
    super::super::session_pages::sort_session_summaries(&mut uncached_list);
    let mut cached_list = Vec::new();
    hub.visit_session_summaries(false, |row| cached_list.push(row));
    assert_eq!(cached_list, uncached_list);

    // The list a client is sent, its full form and a peer's copy: the closed rows' cached bytes
    // are the rows an uncached build gives.
    assert_eq!(list_of(hub, false, false), uncached_list);
    assert_eq!(list_of(hub, true, false), uncached);
    assert_eq!(list_of(hub, false, true), uncached_list);
}

/// Closed rows are serialized once, but every metadata and list-visible runtime change must
/// still produce the exact same row as the uncached walk. This exercises the fields that have
/// historically changed after close: names, tags/archive, seen state, usage, child counts,
/// reopen, and a closed parent's folded child preview.
#[tokio::test]
async fn closed_summary_cache_matches_uncached_after_every_mutation() {
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let hub = Hub::new(
        cfg.clone(),
        crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap(),
    );
    let parent_meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "parent", "name": "parent",
        "harness": "claude", "family": "claude", "cwd": "/w", "status": "idle",
        "createdAt": 1, "updatedAt": 1, "preview": "parent preview", "unread": true,
    }))
    .unwrap();
    let child_meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "child", "name": "child",
        "harness": "claude", "family": "claude", "cwd": "/w", "status": "ready",
        "createdAt": 2, "updatedAt": 2, "subsession": {
            "startedBy": "parent", "shortName": "child", "depth": 1
        }
    }))
    .unwrap();
    let parent = hub.make_session(parent_meta);
    let child = hub.make_session(child_meta);
    hub.sessions
        .lock()
        .unwrap()
        .extend([(parent.id.clone(), parent.clone()), (child.id.clone(), child.clone())]);
    hub.update_live_session_index(&parent);
    hub.update_live_session_index(&child);
    hub.subsessions.note_status(&parent.id, &child.id, SessionStatus::Ready);

    hub.set_status(&parent, SessionStatus::Closed);
    cached_rows_equal_uncached(&hub); // close and the parent's folded child preview

    // A list build followed by the full form keeps both serialized rows coherent.
    hub.visit_session_summaries(false, |_| {});
    cached_rows_equal_uncached(&hub);

    // Appending after close changes the event-visible preview without a metadata write.
    hub.append(&parent, "mux", "message", json!({"text": "after close"}));
    hub.visit_session_summaries(false, |_| {});
    cached_rows_equal_uncached(&hub);

    // Opening a closed chat changes attached/shown fields in its full row.
    hub.attach_count(&parent, 1, true);
    cached_rows_equal_uncached(&hub);
    hub.attach_count(&parent, -1, true);
    cached_rows_equal_uncached(&hub);

    parent.meta.lock().unwrap().name = "renamed".into();
    hub.save_meta_answered(&parent).unwrap(); // rename
    cached_rows_equal_uncached(&hub);

    hub.set_tags_answered(
        &parent,
        Some(&serde_json::Map::from_iter([(String::from("team"), json!("red"))])),
        &[],
        None,
    )
    .unwrap(); // tag
    cached_rows_equal_uncached(&hub);
    hub.set_tags_answered(
        &parent,
        Some(&serde_json::Map::from_iter([(String::from("archived"), json!(true))])),
        &[],
        None,
    )
    .unwrap(); // archive tag
    cached_rows_equal_uncached(&hub);

    // The tag expires when this thread's test clock is moved past it, between the two
    // checks: a 20 ms life on the wall clock could run out in the middle of the first one,
    // between its uncached walk and the cached rows it compares with.
    const LIFE_MS: u64 = 60 * 60 * 1_000;
    parent.meta.lock().unwrap().tags.insert(
        "expires".into(),
        crate::store::Tag {
            value: "soon".into(),
            expires_at: Some(crate::store::now_ms() + LIFE_MS),
        },
    );
    hub.save_meta_answered(&parent).unwrap();
    cached_rows_equal_uncached(&hub);
    crate::store::test_clock::advance(LIFE_MS);
    cached_rows_equal_uncached(&hub); // time-expiring tags invalidate without an event

    hub.set_visible(&parent, true); // mark-seen
    cached_rows_equal_uncached(&hub);

    parent.meta.lock().unwrap().usage = Some(json!({"inputTokens": 12, "size": 4096}));
    hub.save_meta_answered(&parent).unwrap(); // usage metadata
    cached_rows_equal_uncached(&hub);

    std::thread::scope(|scope| {
        for title in ["writer-a", "writer-b"] {
            scope.spawn(|| {
                parent.meta.lock().unwrap().title = Some(title.into());
                hub.save_meta(&parent);
            });
        }
    });
    cached_rows_equal_uncached(&hub); // concurrent metadata writers

    hub.set_status(&child, SessionStatus::Closed); // child count/fold changes
    cached_rows_equal_uncached(&hub);

    assert!(hub.reopen(&parent, parent.stops.load(Ordering::SeqCst))); // reopen
    cached_rows_equal_uncached(&hub);
    hub.set_status(&parent, SessionStatus::Closed);
    cached_rows_equal_uncached(&hub);

    // A purge removes the serialized row even when a late metadata writer runs afterward.
    parent.purged.store(true, Ordering::SeqCst);
    hub.remove_cached_closed_summary(&parent.id);
    assert!(!hub.closed_summary_cache.lock().unwrap().contains_key(&parent.id));
    crate::store::test_clock::reset();
}

/// While one live chat streams, a list build reuses every closed row's bytes: a streamed
/// chunk changes only its own (live, never cached) row. Before, each chunk marked all closed
/// rows stale, so with ~40 chats streaming every list rebuilt all ~3,000 closed rows. A chunk
/// that reaches a closed chat still rebuilds its row.
#[tokio::test]
async fn a_live_chats_stream_keeps_closed_rows_cached() {
    const CLOSED: u64 = 200;
    const CHUNKS: u64 = 20;
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let hub = Hub::new(
        cfg.clone(),
        crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap(),
    );
    let meta = |id: String, status: &str| -> crate::store::SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "claude", "family": "claude", "cwd": "/w", "status": status,
            "createdAt": 1, "updatedAt": 1, "preview": "earlier reply",
        }))
        .unwrap()
    };
    for n in 0..CLOSED {
        hub.insert_test_session(meta(format!("closed-{n}"), "closed"));
    }
    let live = hub.insert_test_session(meta("live".into(), "running"));
    let chunk = |text: &str| {
        json!({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "agent", "update": {"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": text}}}})
    };

    hub.visit_session_summaries(false, |_| {}); // warm the closed rows
    let builds = || hub.closed_summary_builds.load(Ordering::SeqCst);
    let warm = builds();
    assert_eq!(warm, CLOSED);
    for n in 0..CHUNKS {
        hub.append(&live, "in", "agent_message_chunk", chunk(&format!("token {n} ")));
        hub.visit_session_summaries(false, |_| {});
    }
    let rebuilt = builds() - warm;
    assert_eq!(
        rebuilt, 0,
        "closed rows rebuilt while one live chat streamed: {rebuilt} for {CHUNKS} lists of \
         {CLOSED} closed rows"
    );
    // The live row is told before the next list read: it was stamped, not built anew.
    assert!(hub.events.untold.lock().unwrap().contains("live"));
    cached_rows_equal_uncached(&hub);

    // Another record of the live chat changes its own row only: no closed row is rebuilt.
    let before = builds();
    hub.append(&live, "mux", "status", json!({"status": "running"}));
    hub.visit_session_summaries(false, |_| {});
    assert_eq!(builds() - before, 0);

    // A chunk that reaches a closed chat rebuilds that chat's row, and only it.
    let closed = hub.sessions().into_iter().find(|s| s.id == "closed-0").unwrap();
    let before = builds();
    hub.append(&closed, "in", "agent_message_chunk", chunk("late"));
    hub.visit_session_summaries(false, |_| {});
    assert_eq!(builds() - before, 1);
    cached_rows_equal_uncached(&hub);

    // A record that may reach other rows (a parent's tags) still marks them all stale.
    let before = builds();
    hub.append(&closed, "mux", "tags", json!({}));
    hub.visit_session_summaries(false, |_| {});
    assert_eq!(builds() - before, CLOSED);
}

/// A read after one chat's record parses no closed row and builds only that chat's (Leo
/// 2026-11-04: "never ... acceptable ... linear time growth degradation"): a closed row goes as
/// its cached bytes. The same at 10 and 400 closed rows.
#[tokio::test]
async fn a_read_after_one_chats_record_parses_no_closed_row() {
    for closed in [10_u64, 400] {
        let cfg: crate::config::Config =
            serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
        let hub = Hub::new(
            cfg.clone(),
            crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap(),
        );
        let meta = |id: String, status: &str, at: u64| -> crate::store::SessionMeta {
            serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": id, "name": id,
                "harness": "claude", "family": "claude", "cwd": "/w", "status": status,
                "createdAt": 1, "updatedAt": at, "preview": "a reply",
            }))
            .unwrap()
        };
        for n in 0..closed {
            hub.insert_test_session(meta(format!("closed-{n:04}"), "closed", n + 1));
        }
        let live = hub.insert_test_session(meta("live".into(), "idle", closed / 2));
        let uncached = |hub: &Hub| {
            let mut rows: Vec<Value> =
                hub.sessions().iter().map(|s| hub.session_list_summary(s)).collect();
            super::super::session_pages::sort_session_summaries(&mut rows);
            rows
        };
        assert_eq!(list_of(&hub, false, false), uncached(&hub));
        let counts = || {
            (
                hub.closed_summary_builds.load(Ordering::SeqCst),
                hub.closed_summary_parses.load(Ordering::SeqCst),
            )
        };

        // A live chat's record: no closed row is built or parsed.
        let before = counts();
        hub.append(&live, "mux", "status", json!({"status": "running"}));
        let rows = list_of(&hub, false, false);
        let after = counts();
        assert_eq!(after.0 - before.0, 0, "closed rows built at {closed}");
        assert_eq!(after.1 - before.1, 0, "closed rows parsed at {closed}");
        assert_eq!(rows, uncached(&hub));

        // A closed chat's record: its own row only is built again.
        let one = hub.sessions().into_iter().find(|s| s.id == "closed-0001").unwrap();
        let before = counts();
        hub.append(&one, "in", "agent_message_chunk", json!({}));
        let rows = list_of(&hub, false, false);
        let after = counts();
        assert_eq!(after.0 - before.0, 1, "closed rows built at {closed}");
        assert_eq!(after.1 - before.1, 0, "closed rows parsed at {closed}");
        assert_eq!(rows, uncached(&hub));
    }
}

/// A one-chat change rebuilds that chat's closed row, never every closed row: each status,
/// turn or metadata commit of one chat rebuilt all ~3,000 closed rows on the next list. What
/// other rows read of a chat still reaches them: a closed parent's open-children count when
/// its child closes, a child's fold when its parent is archived.
#[tokio::test]
async fn a_one_chat_change_rebuilds_only_its_own_closed_row() {
    const CLOSED: u64 = 100;
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let hub = Hub::new(
        cfg.clone(),
        crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap(),
    );
    let meta = |id: String, status: &str| -> crate::store::SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "claude", "family": "claude", "cwd": "/w", "status": status,
            "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap()
    };
    for n in 0..CLOSED {
        hub.insert_test_session(meta(format!("closed-{n}"), "closed"));
    }
    let one = hub.sessions().into_iter().find(|s| s.id == "closed-7").unwrap();
    hub.visit_session_summaries(false, |_| {});
    let builds = || hub.closed_summary_builds.load(Ordering::SeqCst);

    let before = builds();
    one.meta.lock().unwrap().title = Some("renamed".into());
    hub.save_meta_answered(&one).unwrap();
    hub.append(&one, "mux", "turn_end", json!({}));
    hub.attach_count(&one, 1, true);
    hub.attach_count(&one, -1, true);
    hub.visit_session_summaries(false, |_| {});
    assert_eq!(builds() - before, 1, "one chat's changes rebuilt other closed rows");
    cached_rows_equal_uncached(&hub);

    // A closed parent's `children` follows its child's status.
    let parent = hub.sessions().into_iter().find(|s| s.id == "closed-3").unwrap();
    let mut child = meta("child".into(), "ready");
    child.subsession = Some(
        serde_json::from_value(json!({"startedBy": "closed-3", "shortName": "child", "depth": 1}))
            .unwrap(),
    );
    let child = hub.insert_test_session(child);
    hub.subsessions.note_status(&parent.id, &child.id, SessionStatus::Ready);
    cached_rows_equal_uncached(&hub);
    hub.set_status(&child, SessionStatus::Closed);
    cached_rows_equal_uncached(&hub);

    // Archiving a parent folds its children no more: their rows change with its tags.
    let mut folded = meta("folded".into(), "closed");
    folded.tags.insert(
        "spawnedBy".into(),
        crate::store::Tag { value: "closed-5".into(), expires_at: None },
    );
    hub.insert_test_session(folded);
    cached_rows_equal_uncached(&hub);
    let five = hub.sessions().into_iter().find(|s| s.id == "closed-5").unwrap();
    five.meta
        .lock()
        .unwrap()
        .tags
        .insert("archived".into(), crate::store::Tag { value: "true".into(), expires_at: None });
    hub.save_meta_answered(&five).unwrap();
    cached_rows_equal_uncached(&hub);
}

#[test]
fn rows_keep_every_field_and_ties_keep_their_order() {
    let mut rows = vec![
        json!({"sessionId": "z", "updatedAt": 1, "status": "closed", "tools": [{"id": "tool", "description": "雪\n\""}]}),
        json!({"sessionId": "same", "updatedAt": 9, "origin": "local"}),
        json!({"sessionId": "same", "updatedAt": 9, "peer": "remote", "origin": "remote"}),
        json!({"sessionId": "same", "updatedAt": 9, "peer": "other", "origin": "other"}),
        json!({"sessionId": "a", "updatedAt": 9, "unknown": {"array": [null, false, 42]}}),
        json!({"sessionId": null, "updatedAt": "invalid", "status": "closed"}),
        json!({"updatedAt": -1, "opaque": "preserved"}),
    ];
    super::super::session_pages::sort_session_summaries(&mut rows);
    assert_eq!(serialize_in_order(&rows).0, json!({"sessions": rows}).to_string());
    for params in [json!({}), json!({"status": "closed"}), json!({"peer": "remote"})] {
        assert_eq!(
            bounded_text(&rows, &params, usize::MAX),
            super::super::session_pages::session_list_reply(rows.clone(), &params)
                .unwrap()
                .to_string()
        );
    }
    assert_eq!(rows[1]["origin"], "local");
    assert_eq!(rows[2]["origin"], "other");
    assert_eq!(rows[3]["origin"], "remote");
}

/// A row change no `session_changed` carries (a respawn's mark, a record watchers do not hear,
/// and its end; an agent start's lease and its end) is stamped and told before the next list
/// position is read: a follow from a cursor taken
/// before it sends the row, and a watcher hears it as `session_changed` of kind `row`
/// (#42091 F1). Before, it took a position no notice carried, and a client whose cursor came from
/// a later notice followed past it.
#[tokio::test]
async fn a_change_no_record_carries_is_told_before_the_next_list_read() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane", "harness": "claude",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.insert_test_session(meta);
    let mut heard = hub.events.subscribe();
    // After each change: a follow from the cursor before it sends the row, and the watchers heard
    // it told at a later position.
    let mut check = |hub: &Hub, head: u64, change: &str| {
        let follow = hub.list_follow(head, false, false, usize::MAX).expect("the log follows it");
        let follow: Value = serde_json::from_str(&follow.text).unwrap();
        let rows = follow["sessions"].as_array().cloned().unwrap_or_default();
        let ids: Vec<&str> = rows.iter().filter_map(|r| r["sessionId"].as_str()).collect();
        assert_eq!(ids, ["s1"], "{change}");
        let told = std::iter::from_fn(|| heard.try_recv().ok())
            .any(|e| e.session_id == "s1" && e.list_seq > head);
        assert!(told, "{change}: no watcher heard the row after {head}");
    };
    let head = hub.list_cursor().0;
    hub.mark_profile_respawn(&session);
    check(&hub, head, "a respawn's mark");
    let head = hub.list_cursor().0;
    hub.settle_profile_respawn(&session);
    check(&hub, head, "its end");
    let head = hub.list_cursor().0;
    let lease = hub.spawn_lease(&session).await;
    check(&hub, head, "a start's lease");
    let head = hub.list_cursor().0;
    drop(lease);
    check(&hub, head, "its end");
}
