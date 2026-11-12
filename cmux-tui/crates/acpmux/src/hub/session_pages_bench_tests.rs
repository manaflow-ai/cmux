//! Same seeded daemon and wire handler for old full-list and narrow app reads.
use super::*;
use std::time::Instant;

async fn read(hub: &Arc<Hub>, method: &str, params: Value) -> (Value, usize, f64) {
    let (tx, input) = tokio::sync::mpsc::channel(8);
    let (output, mut rx) = tokio::sync::mpsc::channel(8);
    let task = tokio::spawn(crate::server::serve_connection(hub.clone(), input, output));
    let start = Instant::now();
    tx.send(crate::rpc::Message::request(1, "initialize", json!({"protocolVersion": 1})).to_line())
        .await
        .unwrap();
    tx.send(crate::rpc::Message::request(2, method, params).to_line()).await.unwrap();
    let result = loop {
        let line = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
            .await
            .unwrap()
            .unwrap();
        let frame: Value = serde_json::from_str(&line).unwrap();
        if frame["id"] == 2 {
            assert!(frame.get("error").is_none(), "{frame}");
            break (frame["result"].clone(), line.len(), start.elapsed().as_secs_f64() * 1000.0);
        }
    };
    task.abort();
    let _ = task.await;
    result
}

/// `method` read whole: every page from its `nextCursor` on, its rows in one `sessions`, with the
/// bytes and milliseconds of all its pages (a list past `REPLY_PAGE_BYTES` goes in pages).
async fn read_whole(hub: &Arc<Hub>, method: &str, params: Value) -> (Value, usize, f64) {
    let (mut rows, mut bytes, mut ms, mut params) = (Vec::new(), 0, 0.0, params);
    loop {
        let (page, size, time) = read(hub, method, params.clone()).await;
        rows.extend(page["sessions"].as_array().cloned().unwrap_or_default());
        (bytes, ms) = (bytes + size, ms + time);
        match page["nextCursor"].as_str() {
            Some(cursor) => params["cursor"] = json!(cursor),
            None => break (json!({"sessions": rows}), bytes, ms),
        }
    }
}

#[tokio::test]
async fn seeded_narrow_reads_exclude_peers_and_keep_closed_links() {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    for i in 0..200 {
        let meta = json!({"schema": "acpmux.session.v1", "id": format!("local-{i}"),
            "name": format!("local-{i}"), "harness": "claude", "cwd": "/work",
            "status": if i % 2 == 0 {"closed"} else {"idle"}, "createdAt": 1, "updatedAt": i + 1});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    }
    let hub = Hub::new(cfg, store);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("remote", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("remote".into(), peer.clone());
    let rows = (0..2800)
        .map(|i| {
            json!({"sessionId": format!("remote-{i}"),
        "name": format!("remote-{i}"), "harness": "claude", "cwd": "/remote/work",
        "status": if i % 2 == 0 {"closed"} else {"idle"}, "updatedAt": i + 201,
        "tools": [{"id": "tool", "description": "x".repeat(4096)}]})
        })
        .collect();
    hub.apply_peer_notice(
        "remote",
        peer.generation,
        crate::peer::PeerNotice::sessions_from_values(rows),
    );
    // Warm the shared snapshot equally for both paths. No agents or peers are started.
    let _ = read(&hub, "_acpmux/sessions", json!({"limit": 1})).await;
    let (full, before_bytes, before_ms) = read_whole(&hub, "_acpmux/sessions", json!({})).await;
    assert_eq!(full["sessions"].as_array().unwrap().len(), 3000);
    assert_eq!(
        full["sessions"].as_array().unwrap().iter().filter(|s| s["status"] == "closed").count(),
        1500
    );
    let mut params = json!({"localOnly": true, "excludeStatus": ["closed"], "orderBy": "sessionId", "limit": 64});
    let (mut count, mut bytes, mut ms, mut pages) = (0, 0, 0.0, 0);
    loop {
        let (page, size, time) = read(&hub, "_acpmux/sessions", params.clone()).await;
        pages += 1;
        bytes += size;
        ms += time;
        let rows = page["sessions"].as_array().unwrap();
        assert!(rows.iter().all(|r| r["peer"].is_null() && r["status"] != "closed"));
        count += rows.len();
        if page["nextCursor"].is_null() {
            break;
        }
        assert!(pages < 3, "quit reads must not page through the peer mirror");
        params["cursor"] = page["nextCursor"].clone();
    }
    assert_eq!(count, 100);
    assert_eq!(pages, 2);
    println!("PERF census bytes={before_bytes}->{bytes} ms={before_ms:.3}->{ms:.3} pages={pages}");
    let (_, watch_bytes, watch_ms) = read(&hub, "_acpmux/watch", json!({"enabled": true})).await;
    let (exact, exact_bytes, exact_ms) =
        read(&hub, "_acpmux/resolve", json!({"exactSessionId": true, "sessionId": "remote-0"}))
            .await;
    assert_eq!(exact["session"]["status"], "closed");
    assert_eq!(exact["session"]["cwd"], "/remote/work");
    assert_eq!(exact["session"]["peer"], "remote");
    println!("PERF link bytes={before_bytes}->{exact_bytes} ms={before_ms:.3}->{exact_ms:.3}");
    println!("PERF folder bytes={watch_bytes}->{exact_bytes} ms={watch_ms:.3}->{exact_ms:.3}");
    let (_, narrow_bytes, narrow_ms) =
        read(&hub, "_acpmux/watch", json!({"enabled": true, "limit": 1})).await;
    println!(
        "PERF harness-watch bytes={watch_bytes}->{narrow_bytes} ms={watch_ms:.3}->{narrow_ms:.3}"
    );
}

/// A hub on a memory store with `closed` closed chats, then `idle` idle ones, the closed ones
/// newest (each a millisecond apart): a page from the top is closed rows.
fn seeded(closed: usize, idle: usize) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    for i in 0..closed + idle {
        let status = if i < idle { "idle" } else { "closed" };
        let meta = json!({"schema": "acpmux.session.v1", "id": format!("s-{i:05}"),
            "name": format!("chat-{i}"), "harness": "claude", "cwd": "/work",
            "status": status, "createdAt": 1, "updatedAt": 1_000 + i});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    }
    Hub::new(cfg, store)
}

/// Leo 2026-11-11, 11,236 chats (10,874 closed): `acpmux ls --limit 5` took 5.4 s, as long as
/// `--limit 1000`, because a page was cut from a list of every chat's row. A page of five builds
/// at most its five rows, at 500 chats and at 5,000, and so does the next page and a watch's
/// first page.
#[tokio::test]
async fn a_page_of_five_builds_its_five_rows_not_every_chat() {
    use std::sync::atomic::Ordering::SeqCst;
    let mut times = Vec::new();
    for n in [500_usize, 5_000] {
        let hub = seeded(n - n / 20, n / 20);
        let built = || hub.closed_summary_builds.load(SeqCst);
        let before = built();
        let all_before = hub.summaries_built.load(SeqCst);
        let (first, _, ms) = read(&hub, "_acpmux/sessions", json!({"limit": 5})).await;
        // Every summary, live or closed, not only the closed rows built anew.
        let all = hub.summaries_built.load(SeqCst) - all_before;
        assert!(all <= 5, "{n} chats: a page of 5 built {all} summaries");
        let rows = first["sessions"].as_array().unwrap();
        assert_eq!(rows.len(), 5);
        assert_eq!(rows[0]["sessionId"], format!("s-{:05}", n - 1));
        assert!(rows.iter().all(|r| r["status"] == "closed"));
        let first_built = built() - before;
        assert!(first_built <= 5, "{n} chats: a page of 5 built {first_built} closed rows");
        let before = built();
        let (second, _, _) = read(
            &hub,
            "_acpmux/sessions",
            json!({"limit": 5, "cursor": first["nextCursor"].clone()}),
        )
        .await;
        assert_eq!(second["sessions"][0]["sessionId"], format!("s-{:05}", n - 6));
        let second_built = built() - before;
        assert!(second_built <= 5, "{n} chats: the next page built {second_built} closed rows");
        let before = built();
        let (watch, _, _) = read(&hub, "_acpmux/watch", json!({"enabled": true, "limit": 5})).await;
        assert_eq!(watch["sessions"].as_array().unwrap().len(), 5);
        let watch_built = built() - before;
        assert!(watch_built <= 5, "{n} chats: a watch's page of 5 built {watch_built} closed rows");
        times.push((n, ms));
    }
    println!("PERF page-of-5 {times:?} (chats, ms)");
}

/// A page built from its own rows is the page the whole list's snapshot cuts (`Snapshot::page`),
/// byte for byte: every filter, a cursor into this daemon's rows and one into a peer's, a census,
/// tools, and a chat here and its peer copy updated in the same millisecond.
#[tokio::test]
async fn a_page_of_its_own_rows_is_the_whole_lists_page() {
    let hub = seeded(40, 12);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("remote", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("remote".into(), peer.clone());
    let rows = (0..30)
        .map(|i| {
            // Every third row ties a local chat: the same id, the same millisecond.
            let (id, at) = if i % 3 == 0 {
                (format!("s-{:05}", i + 10), 1_010 + i)
            } else {
                (format!("r-{i:03}"), 1_000 + i * 2)
            };
            json!({"sessionId": id, "name": format!("remote-{i}"), "harness": "claude",
                "cwd": "/remote", "status": if i % 2 == 0 {"closed"} else {"idle"},
                "updatedAt": at, "tools": [{"id": "tool", "description": "x".repeat(64)}]})
        })
        .collect();
    hub.apply_peer_notice(
        "remote",
        peer.generation,
        crate::peer::PeerNotice::sessions_from_values(rows),
    );
    let list = hub.list_guard.snapshot(&hub).await;
    let full = list.full_rows(&hub);
    // The wire's budget (`server::list_reply::LIST_PAGE_BYTES`): these pages are far smaller.
    let most = 4 << 20;
    let expect = |params: &Value| -> Value {
        let tools = params.get("withTools") == Some(&Value::Bool(true));
        let text = list.page(tools.then_some(&*full), params, most).unwrap();
        serde_json::from_str(&text).unwrap()
    };
    let mut cases = vec![
        json!({"limit": 5}),
        json!({"limit": 1}),
        json!({"limit": 100_000}),
        json!({"limit": 3, "status": "idle"}),
        json!({"limit": 4, "peer": "remote"}),
        json!({"limit": 7, "localOnly": true}),
        json!({"limit": 6, "excludeStatus": ["closed"]}),
        json!({"limit": 2, "withTools": true}),
        json!({"localOnly": true, "excludeStatus": ["closed"], "orderBy": "sessionId", "limit": 4}),
        json!({"localOnly": true, "orderBy": "sessionId"}),
    ];
    // Each page's next page, through every row, for the plain list and a filtered one.
    for start in [json!({"limit": 4}), json!({"limit": 3, "status": "closed"})] {
        let mut params = start;
        loop {
            cases.push(params.clone());
            let next = expect(&params)["nextCursor"].clone();
            if next.is_null() {
                break;
            }
            params["cursor"] = next;
        }
    }
    // A cursor no row has now (its row moved): the page starts at the first row no newer.
    cases.push(json!({"limit": 5, "cursor": "k3f5.0000000000000001"}));
    assert!(cases.len() > 30, "{}", cases.len());
    for params in cases {
        let (page, _, _) = read(&hub, "_acpmux/sessions", params.clone()).await;
        assert_eq!(page, expect(&params), "{params}");
    }
}
