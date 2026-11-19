use serde_json::json;

use super::*;
use crate::store::{EventRecord, MemoryStore, Store};

#[test]
fn params_read_the_wire_and_bound_the_limit_and_context() {
    let p = Params::from_value(&json!({
        "query": "four agent pages", "sessionId": "coord", "role": "assistant",
        "sinceMs": 5, "limit": 5000, "context": 99_999, "host": "all",
        "order": "transcript", "window": {"fromMs": 10, "toMs": 20}, "offset": 40,
    }))
    .unwrap();
    assert_eq!(p.query, "four agent pages");
    assert_eq!(p.session.as_deref(), Some("coord"));
    assert_eq!(p.limit, MAX_LIMIT);
    assert_eq!(p.context, MAX_CONTEXT);
    assert_eq!(p.host.as_deref(), Some("all"));
    assert_eq!((p.order, p.window, p.offset), (ts::Order::Transcript, Some((10, 20)), 40));
    assert_eq!(Params::from_value(&p.to_value()).unwrap(), p);

    let bare = Params::from_value(&json!({"query": "x", "role": null, "host": ""})).unwrap();
    assert_eq!(
        (bare.limit, bare.context, bare.host.clone()),
        (DEFAULT_LIMIT, DEFAULT_CONTEXT, None)
    );
    assert_eq!((bare.order, bare.window, bare.offset), (ts::Order::Newest, None, 0));
    assert_eq!(Params::from_value(&bare.to_value()).unwrap(), bare);
    assert!(Params::from_value(&json!({"query": "  "})).is_err());
    assert!(Params::from_value(&json!({"query": "x", "role": "system"})).is_err());
    assert!(Params::from_value(&json!({"query": "x", "order": "oldest"})).is_err());
    assert!(
        Params::from_value(&json!({"query": "x", "window": {"fromMs": 9, "toMs": 1}})).is_err()
    );
    assert!(Params::from_value(&json!({"query": "x", "window": {"fromMs": 9}})).is_err());
    let far = Params::from_value(&json!({"query": "x", "offset": u64::MAX})).unwrap();
    assert_eq!(far.offset, MAX_OFFSET);
}

/// Several machines each answer from their first hit, deep enough for the page; the merge skips.
#[test]
fn a_search_of_several_machines_asks_each_from_its_first_hit() {
    let p = Params { query: "x".into(), limit: 20, offset: 30, ..Params::default() };
    let each = p.for_merge();
    assert_eq!((each.offset, each.limit), (0, 50));
    let deep = Params { offset: 500, ..p }.for_merge();
    assert_eq!(deep.limit, MAX_LIMIT);
}

#[test]
fn merge_puts_every_hosts_hits_newest_first_up_to_the_limit() {
    let here = json!({"hits": [{"host": "a", "at": 30}, {"host": "a", "at": 10}],
        "files": 2, "caughtUpBytes": 100, "catchUpMs": 4, "queryMs": 2, "unreached": [], "total": 2});
    let peer = json!({"hits": [{"host": "b", "at": 20}, {"host": "b", "at": null}],
        "files": 3, "caughtUpBytes": 0, "catchUpMs": 9, "queryMs": 1, "unreached": [], "total": 7});
    let p = Params { limit: 3, ..Params::default() };
    let merged = merge(
        vec![here.clone(), peer.clone()],
        vec![json!({"host": "c", "error": "down"})],
        &p,
        0,
        12,
    );
    let order: Vec<_> =
        merged["hits"].as_array().unwrap().iter().map(|h| h["at"].clone()).collect();
    assert_eq!(order, [json!(30), json!(20), json!(10)]);
    assert_eq!(merged["files"], 5);
    assert_eq!(merged["caughtUpBytes"], 100);
    assert_eq!(merged["catchUpMs"], 9);
    assert_eq!(merged["tookMs"], 12);
    assert_eq!(merged["unreached"][0]["host"], "c");
    assert_eq!(merged["total"], 9);

    let skipped = merge(vec![here.clone(), peer], vec![], &p, 1, 0);
    let order: Vec<_> =
        skipped["hits"].as_array().unwrap().iter().map(|h| h["at"].clone()).collect();
    assert_eq!(order, [json!(20), json!(10), json!(null)], "the page past the first hit");
    let uncounted = json!({"hits": [], "unreached": []});
    assert!(merge(vec![here, uncounted], vec![], &p, 0, 0).get("total").is_none());
    let unreached = merge(vec![], vec![json!({"host": "c", "error": "down"})], &p, 0, 0);
    assert!(unreached.get("total").is_none(), "no machine answered: nothing was counted");
}

#[test]
fn merge_keeps_transcript_order_and_the_window_first() {
    let hit = |path: &str, line: u64, inside: bool| {
        let mut h = json!({"path": path, "line": line, "matchStart": 0, "at": line});
        if inside {
            h["inWindow"] = json!(true);
        }
        h
    };
    let here = json!({"hits": [hit("/b", 1, false), hit("/a", 9, true)]});
    let peer = json!({"hits": [hit("/a", 2, false), hit("/a", 5, true)]});
    let p = Params { limit: 10, order: ts::Order::Transcript, ..Params::default() };
    let merged = merge(vec![here, peer], vec![], &p, 0, 0);
    let got: Vec<_> = merged["hits"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| (h["path"].as_str().unwrap().to_owned(), h["line"].as_u64().unwrap()))
        .collect();
    let want: Vec<(String, u64)> =
        [("/a", 5), ("/a", 9), ("/a", 2), ("/b", 1)].map(|(p, l)| (p.to_owned(), l)).to_vec();
    assert_eq!(got, want);
}

fn rec(seq: u64, at: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

fn logged(records: &[EventRecord]) -> MemoryStore {
    let store = MemoryStore::default();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    for r in records {
        store.append("c", r).unwrap();
    }
    store
}

/// A hit of the chat's own transcript takes the seq of the logged message holding it nearest its
/// time; one the log never held, or another machine's, takes none.
#[test]
fn hits_are_placed_at_the_logged_message_that_holds_them() {
    let min = 60_000;
    let chunk = |seq: u64, at: u64, id: &str, text: &str| {
        rec(
            seq,
            at,
            "in",
            "agent_message_chunk",
            json!({"params": {"update": {
            "sessionUpdate": "agent_message_chunk", "messageId": id,
            "content": {"type": "text", "text": text}}}}),
        )
    };
    let store = logged(&[
        rec(1, 10 * min, "mux", "user_message", json!({"text": "fix the Parser bug"})),
        chunk(2, 10 * min + 500, "m1", "The parser "),
        chunk(3, 10 * min + 600, "m1", "bug is fixed."),
        rec(4, 50 * min, "mux", "user_message", json!({"text": "again: the parser bug"})),
        rec(5, 200 * min, "mux", "user_message", json!({"text": "something else entirely"})),
    ]);
    let hit =
        |role: &str, at: Option<u64>, host: &str| json!({"host": host, "role": role, "at": at});
    let mut hits = vec![
        hit("user", Some(10 * min + 2_000), "here"),
        hit("assistant", Some(12 * min), "here"),
        hit("user", Some(50 * min + 900), "here"),
        hit("user", Some(300 * min), "here"),
        hit("user", None, "here"),
        hit("user", Some(10 * min), "peer"),
        // Its text is past what the log keeps of a message: the nearest prompt in two minutes.
        hit("user", Some(200 * min + 30_000), "here"),
    ];
    let ours = |h: &Value| h["host"] == "here";
    place(&store, "c", "parser BUG", &mut hits, &ours).unwrap();
    let seqs: Vec<Option<u64>> =
        hits.iter().map(|h| h.get("seq").and_then(Value::as_u64)).collect();
    assert_eq!(seqs, [Some(1), Some(2), Some(4), None, None, None, Some(5)]);
}
