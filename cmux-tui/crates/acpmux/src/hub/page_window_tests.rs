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

/// `fields` cuts each row of a page to the members named and those a cursor and a row key read,
/// own rows and peers' alike, and the pages still give every row once.
#[tokio::test]
async fn a_page_with_fields_sends_only_those_members() {
    let hub = mixed_hub();
    let filter = json!({"excludeStatus": ["closed"], "fields": ["name", "lane.state"]});
    let want = picked_from_all(&hub, 1_000, &json!({"excludeStatus": ["closed"]}));
    assert_eq!(paged(&hub, 3, &filter), want, "pages with fields give every row once");
    let mut params = filter.clone();
    params["limit"] = json!(1_000);
    let (rows, _) = hub.session_page_rows(&params, false).unwrap();
    let allowed = [
        "sessionId",
        "qualifiedSessionId",
        "peer",
        "updatedAt",
        "status",
        "harness",
        "lastSeq",
        "name",
        "lane",
    ];
    let mut peers = 0;
    for row in &rows {
        let BuiltRow::Tree(row) = row else { panic!("a row with fields is built as a tree") };
        let members = row.as_object().unwrap();
        assert!(members.keys().all(|k| allowed.contains(&k.as_str())), "{row}");
        assert!(members.contains_key("sessionId"));
        peers += usize::from(members.contains_key("peer"));
    }
    assert!(peers > 0, "the peers' rows are cut too");
    let bad = json!({"limit": 5, "fields": "name"});
    assert!(hub.session_page_rows(&bad, false).is_err());
}

/// A page cut by `fields` still reaches a peer masked: each own row keeps the keys the peer
/// masking pass knows a summary by, so a secret in a field named (`lastPrompt`) is masked.
#[tokio::test]
async fn a_page_with_fields_is_still_masked_for_a_peer() {
    let hub = mixed_hub();
    let token = format!("gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234");
    let params = json!({"limit": 1_000, "localOnly": true, "fields": ["lastPrompt"]});
    let (rows, _) = hub.session_page_rows(&params, false).unwrap();
    assert!(!rows.is_empty());
    for row in rows {
        let BuiltRow::Tree(mut row) = row else { panic!("a row with fields is built as a tree") };
        row["lastPrompt"] = json!(format!("push with {token}"));
        let reply = crate::rpc::Message::ok(json!(1), json!({"sessions": [row]}));
        let Some(crate::rpc::Message::Response { result: Some(result), .. }) =
            crate::server::peer_text::masked(&reply)
        else {
            panic!("a cut row was not masked for a peer: {row}")
        };
        let text = result.to_string();
        assert!(!text.contains("ghp_"), "a raw token reached a peer: {text}");
    }
}

/// Every byte page of a whole read with no `limit`, following each `nextCursor`, as the reply
/// texts: from the indexes (`indexed`), or from every row sorted as `list_guard::bounded` cuts
/// them (the path any other whole read takes).
fn whole_pages(hub: &Hub, budget: usize, own_only: bool, indexed: bool) -> Vec<String> {
    let (mut pages, mut cursor) = (Vec::new(), Value::Null);
    for _ in 0..10_000 {
        let params = if cursor.is_null() { json!({}) } else { json!({"cursor": cursor}) };
        let text = if indexed {
            hub.session_list_text(&params, false, own_only, budget).unwrap()
        } else {
            let list = hub.list_rows(false, own_only);
            let text = |row: &super::Unbuilt| list.text(hub, row, false);
            super::super::list_guard::bounded(list.rows(), text, &params, budget).unwrap()
        };
        let reply: Value = serde_json::from_str(&text).unwrap();
        cursor = reply.get("nextCursor").cloned().unwrap_or(Value::Null);
        pages.push(text);
        if cursor.is_null() {
            return pages;
        }
    }
    panic!("the pages never ended");
}

/// A whole read's byte pages from the indexes are the pages `bounded` cuts from every row
/// sorted, byte for byte, at budgets from a row or two a page to the whole list in one, for the
/// whole list and a peer link's own rows; and after rows move, close and go.
#[tokio::test]
async fn indexed_byte_pages_equal_the_pages_of_every_row_sorted() {
    let hub = mixed_hub();
    let check = |when: &str| {
        for own_only in [false, true] {
            for budget in [400, 1_500, 6_000, 1 << 30] {
                let want = whole_pages(&hub, budget, own_only, false);
                let got = whole_pages(&hub, budget, own_only, true);
                assert_eq!(got, want, "{when}: budget {budget}, own_only {own_only}");
            }
        }
        let whole = whole_pages(&hub, 1 << 30, false, true);
        assert_eq!(whole.len(), 1, "a list that fits goes whole");
    };
    check("at first");
    {
        let mut rows = hub.remote_sessions.write();
        let (key, row) = remote("peer2", "s05", 50_000, "running");
        rows.insert(key, row);
        rows.take("peer3/s07");
    }
    hub.edit_test_meta(&hub.session_by_id("s04").unwrap(), |m| m.updated_at = 70_000);
    check("after rows moved and went");
}

/// A whole read of a big list reads a window of the page-key indexes: its first byte page holds
/// the budget's rows, and its cursor goes on from there.
#[tokio::test]
async fn a_byte_page_of_a_big_list_reads_a_window() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    {
        let mut rows = hub.remote_sessions.write();
        for n in 0..20_000u64 {
            let (key, row) = remote(&format!("p{}", n % 200), &format!("r{n:05}"), n, "idle");
            rows.insert(key, row);
        }
    }
    let (rows, complete) = hub.keyed_window(None, super::BYTE_WINDOW, false);
    assert!(!complete);
    assert!(rows.len() <= super::BYTE_WINDOW, "the window, not every row");
    let pages = whole_pages(&hub, 64 << 10, false, true);
    let listed: usize = pages
        .iter()
        .map(|p| serde_json::from_str::<Value>(p).unwrap()["sessions"].as_array().unwrap().len())
        .sum();
    assert_eq!(listed, 20_000, "every row once over the pages");
}
