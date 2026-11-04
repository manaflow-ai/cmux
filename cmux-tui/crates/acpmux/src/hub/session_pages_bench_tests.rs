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
    hub.apply_peer_notice("remote", peer.generation, crate::peer::PeerNotice::Sessions(rows));
    // Warm the shared snapshot equally for both paths. No agents or peers are started.
    let _ = read(&hub, "_acpmux/sessions", json!({"limit": 1})).await;
    let (full, before_bytes, before_ms) = read(&hub, "_acpmux/sessions", json!({})).await;
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
