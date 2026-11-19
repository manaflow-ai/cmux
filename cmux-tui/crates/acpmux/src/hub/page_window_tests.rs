//! A page by `limit` read from a window (`Hub::window`: this daemon's kept order or its live rows,
//! the peers' rows from their ordered index) gives the rows a pick from every row sorted gives,
//! for a whole list and a live one, through every page; and it reads no more of the peers' rows
//! than the window holds.

use super::super::session_pages::{PageRow, pick_page};
use super::*;
use crate::session_identity::SessionReceipt;

fn meta(id: &str, updated: u64, status: &str) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": updated
    }))
    .unwrap()
}

fn remote(peer: &str, mux: &str, updated: u64, status: &str) -> (String, RemoteSession) {
    let receipt = SessionReceipt::new(peer, mux, None, 0);
    let summary = json!({"sessionId": mux, "peer": peer, "status": status, "updatedAt": updated});
    (receipt.qualified_id(), RemoteSession { peer: peer.into(), summary: summary.into(), receipt })
}

/// A hub with own rows and peers' rows, closed and live, with many `updatedAt` ties across them
/// (a peer's row and an own row of one id and time too).
fn mixed_hub() -> Arc<Hub> {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    for n in 0..40u64 {
        let status = if n % 3 == 0 { "idle" } else { "closed" };
        let meta = meta(&format!("s{n:02}"), 100 + n / 4, status);
        hub.store.save(&meta).unwrap();
        hub.insert_test_session(meta);
    }
    {
        let mut rows = hub.remote_sessions.write();
        for p in 0..5u64 {
            for n in 0..30u64 {
                let status = if (n + p) % 4 == 0 { "running" } else { "closed" };
                let (key, row) =
                    remote(&format!("peer{p}"), &format!("s{n:02}"), 95 + (n * 7 + p) % 20, status);
                rows.insert(key, row);
            }
        }
    }
    hub
}

/// `(peer, id)` of a row.
fn id_of(row: &impl PageRow) -> (Option<String>, String) {
    (row.peer().map(str::to_owned), row.session_id().to_owned())
}

/// Every page of `limit` rows of `filter`, read as a client does, following each `nextCursor`.
fn paged(hub: &Hub, limit: u64, filter: &Value) -> Vec<(Option<String>, String)> {
    let (mut ids, mut cursor) = (Vec::new(), Value::Null);
    for _ in 0..10_000 {
        let mut params = filter.clone();
        params["limit"] = json!(limit);
        params["cursor"] = cursor;
        let (rows, next) = hub.session_page_rows(&params, false).unwrap();
        ids.extend(rows.iter().map(id_of));
        cursor = next.unwrap_or(Value::Null);
        if cursor.is_null() {
            return ids;
        }
    }
    panic!("the pages never ended");
}

/// The same pages picked from every row sorted (the path a page with no window takes).
fn picked_from_all(hub: &Hub, limit: u64, filter: &Value) -> Vec<(Option<String>, String)> {
    let live = filter.get("excludeStatus").is_some();
    let list = hub.list_rows(live, false);
    let (mut ids, mut cursor) = (Vec::new(), Value::Null);
    loop {
        let mut params = filter.clone();
        params["limit"] = json!(limit);
        params["cursor"] = cursor;
        let picked = pick_page(list.rows(), &params).unwrap();
        ids.extend(picked.rows.iter().map(|&at| id_of(&list.rows()[at])));
        cursor = picked.next.unwrap_or(Value::Null);
        if cursor.is_null() {
            return ids;
        }
    }
}

#[tokio::test]
async fn window_pages_equal_a_pick_from_every_row() {
    let hub = mixed_hub();
    for filter in [json!({}), json!({"excludeStatus": ["closed"]}), json!({"status": "running"})] {
        let want = picked_from_all(&hub, 1_000, &filter);
        assert!(!want.is_empty());
        if filter.get("excludeStatus").is_some() {
            let live = want.iter().all(|(peer, id)| {
                let row = match peer {
                    Some(peer) => hub.rows_by_key(&[format!("{peer}/{id}")], false),
                    None => hub.rows_by_key(std::slice::from_ref(id), false),
                };
                row[0].as_deref().is_some_and(|text| !text.contains("\"status\":\"closed\""))
            });
            assert!(live, "a live list holds no closed row");
        }
        for limit in [1, 2, 3, 7, 50, 1_000] {
            assert_eq!(paged(&hub, limit, &filter), want, "pages of {limit} of {filter}");
        }
    }
}

/// The peers' ordered index follows every write: a row that changes its time or its status moves
/// in it, and a page after the change sees it where a sort of every row puts it.
#[tokio::test]
async fn the_peer_index_follows_a_row_that_moves_or_closes() {
    let hub = mixed_hub();
    let live = json!({"excludeStatus": ["closed"]});
    {
        let mut rows = hub.remote_sessions.write();
        let (key, row) = remote("peer1", "s03", 10_000, "running");
        rows.insert(key, row);
        let (key, row) = remote("peer0", "s00", 96, "closed");
        rows.insert(key, row);
        rows.take("peer4/s04");
    }
    for filter in [json!({}), live] {
        let want = picked_from_all(&hub, 1_000, &filter);
        assert_eq!(want.first(), Some(&(Some("peer1".to_owned()), "s03".to_owned())));
        for limit in [1, 4, 9] {
            assert_eq!(paged(&hub, limit, &filter), want, "pages of {limit} of {filter}");
        }
    }
    let closed = hub.remote_sessions.read().values().filter(|r| r.summary.closed()).count();
    assert_eq!(hub.remote_sessions.read().closed_count(), closed, "the closed count is kept");
}

/// A first page of a big list reads a window of the peers' index, not every row: the window's
/// rows are the page's and its room, whatever the list's size.
#[tokio::test]
async fn a_first_page_reads_a_window_of_the_peers_rows() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    {
        let mut rows = hub.remote_sessions.write();
        for n in 0..20_000u64 {
            let status = if n % 10 == 0 { "running" } else { "closed" };
            let (key, row) = remote(&format!("p{}", n % 200), &format!("r{n:05}"), n, status);
            rows.insert(key, row);
        }
    }
    let most = 20 + super::WINDOW_ROOM;
    for open_only in [false, true] {
        let window = hub.window(None, most, open_only);
        assert_eq!(window.list.rows().len(), most, "the window holds the page and its room");
        assert!(!window.all);
        let first = window.list.rows().first().map(|r| r.session_id().to_owned());
        let want = if open_only { "r19990" } else { "r19999" };
        assert_eq!(first.as_deref(), Some(want));
    }
    let (rows, next) =
        hub.session_page_rows(&json!({"limit": 20, "excludeStatus": ["closed"]}), false).unwrap();
    assert_eq!(rows.len(), 20);
    assert!(next.is_some_and(|next| next.is_string()));
    assert_eq!(hub.closed_listed(0).remote, 18_000);
}
