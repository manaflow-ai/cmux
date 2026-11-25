//! Detector: no reply on a client path is larger than
//! [`REPLY_PAGE_BYTES`](crate::rpc::REPLY_PAGE_BYTES) (1 MiB), with a realistic list: 2,000 chats
//! of this daemon's own and 4,000 mirrored from two peers, about 30 MB in all
//! (`ack_latency_bench.rs` `hub`). A connection sends its replies in order, so every small reply
//! queued behind a large one waits for it to be written and parsed. On 2026-11-11 a dogfood Mac sent
//! a 31 MB `_acpmux/watch` reply near the 32 MB frame cap again and again, the pane's prompt
//! acknowledgements waited behind it, and the pane said "Not sent yet" about prompts acpmux had
//! taken within milliseconds. Each read here is followed to its end, as its client follows it,
//! and still lists every row: the bound pages the list, it never cuts it short.
//!
//! A new list-shaped method, or a new way to ask for one, belongs in [`READS`]. Pattern page:
//! cmuxterm-hq docs/handbook/whole-list-reply-near-frame-cap.md.

use super::Origin;
use super::ack_latency_bench::{Client, every_id, hub};
use crate::rpc::{REPLY_PAGE_BYTES, method};
use serde_json::{Value, json};
use std::collections::HashSet;

/// Every whole or paged list read a client makes: the method, its params, and the connections
/// that make it (each read is about 30 MB parsed, so each on the connections that make it).
const READS: &[(&str, &str, &[Origin])] = &[
    // The app's turn-state feed (Local), the pane's whole read (LocalApp), the phone's push
    // watcher (Web), a peer's link.
    (method::MUX_WATCH, r#"{"enabled": true}"#, ALL),
    // The pane's first page and its later ones (`SessionPager.first`, `rest`).
    (method::MUX_WATCH, r#"{"enabled": true, "limit": 200}"#, APP),
    (method::MUX_WATCH, r#"{"enabled": true, "withTools": true}"#, LOCAL),
    // `acpmux ls`, the app's usage read, a census, a whole read of the list.
    (method::MUX_SESSIONS, r#"{}"#, LOCAL),
    (method::MUX_SESSIONS, r#"{"limit": 1000}"#, LOCAL),
    (method::MUX_SESSIONS, r#"{"limit": 1000, "withTools": true}"#, LOCAL),
    (method::MUX_SESSIONS, r#"{"usage": true}"#, LOCAL),
    (method::MUX_SESSIONS, r#"{"localOnly": true, "orderBy": "sessionId", "limit": 1000}"#, LOCAL),
    // ACP's own list.
    (method::SESSION_LIST, r#"{}"#, APP),
];

const ALL: &[Origin] = &[Origin::Local, Origin::LocalApp, Origin::Web, Origin::Peer];
const LOCAL: &[Origin] = &[Origin::Local];
const APP: &[Origin] = &[Origin::LocalApp];

/// The id of a list row: an `_acpmux` summary's, or an ACP row's.
fn row_id(row: &Value) -> Option<&str> {
    row.get("sessionId").and_then(Value::as_str)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_reply_on_a_client_path_is_larger_than_a_page() {
    super::list_web_page_tests::list_test_within(
        "no_reply_on_a_client_path_is_larger_than_a_page",
        no_reply_on_a_client_path_is_larger_than_a_page_body(),
    )
    .await
}

async fn no_reply_on_a_client_path_is_larger_than_a_page_body() {
    let hub = hub().await;
    let every = every_id();
    let own: HashSet<String> = every.iter().filter(|id| id.starts_with("own-")).cloned().collect();
    let mut failures = Vec::new();
    for (m, params, origins) in READS {
        let params: Value = serde_json::from_str(params).unwrap();
        for origin in *origins {
            let client = Client::on(&hub, *origin).await;
            // A census continues with its own params; every other list with only the cursor
            // (`Client::whole_list`, `SessionPager.whole`, `AgentTurnStateFeed.pageRequest`).
            let (mut replies, mut seen) =
                (vec![client.call(m, params.clone()).await], HashSet::new());
            loop {
                let (reply, _) = replies.last().unwrap();
                assert!(
                    reply.get("error").is_none(),
                    "{m} {params} {origin:?}: {}",
                    reply["error"]
                );
                let Some(cursor) = reply["result"]["nextCursor"].as_str().map(str::to_owned) else {
                    break;
                };
                assert!(seen.insert(cursor.clone()), "{m} {params} {origin:?}: {cursor} twice");
                let next = match *m {
                    method::SESSION_LIST => (method::SESSION_LIST, json!({"cursor": cursor})),
                    _ => {
                        let mut p = params.clone();
                        if let Some(p) = p.as_object_mut() {
                            p.remove("enabled");
                            p.insert("cursor".into(), Value::String(cursor));
                        }
                        (method::MUX_SESSIONS, p)
                    }
                };
                replies.push(client.call(next.0, next.1).await);
            }
            let largest = replies.iter().map(|(_, bytes)| *bytes).max().unwrap_or(0);
            if largest > REPLY_PAGE_BYTES {
                failures.push(format!(
                    "{m} {params} on {origin:?}: a reply of {largest} bytes (bound {REPLY_PAGE_BYTES})"
                ));
            }
            let ids: HashSet<String> = replies
                .iter()
                .flat_map(|(reply, _)| {
                    reply["result"]["sessions"].as_array().cloned().unwrap_or_default()
                })
                .filter_map(|row| row_id(&row).map(str::to_owned))
                .collect();
            // A peer link's whole watch, and a `localOnly` read, are this daemon's own rows.
            let own_only = (*origin == Origin::Peer && *m == method::MUX_WATCH)
                || params.get("localOnly").is_some();
            let want = if own_only { &own } else { &every };
            assert!(
                want.is_subset(&ids),
                "{m} {params} on {origin:?}: {} of {} rows",
                ids.len(),
                want.len()
            );
        }
    }
    assert!(failures.is_empty(), "replies past one page:\n{}", failures.join("\n"));
}
