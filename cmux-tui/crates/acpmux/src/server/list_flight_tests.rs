//! Concurrent reads of one session-list page share one build. On 2026-11-19 a host with about
//! 700 chats timed out the paged read `_acpmux/sessions {excludeStatus: [closed], limit: 500}` at
//! its caller's 8 s deadline, minutes after a daemon restart. One read of 700 live rows took
//! 0.25 s there and on a seeded home here, but each concurrent read built every row again on its
//! own: 8 callers took 1.4 s each, 16 took 2.8 s (the daemon's two malloc arenas serialize the
//! builds), and a caller that retries on its deadline only adds readers. Here 16 connections read
//! the same page at once: the rows are built for at most a few of them, not for each.

use crate::config::{Config, StoreMode};
use crate::hub::RequestStage;
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

use super::Origin;

/// This daemon's live chats: one page of the broker's read.
const CHATS: usize = 300;
/// Connections reading the page at once.
const CALLERS: usize = 16;

fn rows_built(hub: &crate::hub::Hub) -> usize {
    let built = hub.summaries_built.load(std::sync::atomic::Ordering::SeqCst);
    usize::try_from(built).unwrap_or(usize::MAX)
}

fn hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for i in 0..CHATS {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("own-{i}"), "name": format!("own-{i}"),
            "title": "t".repeat(200), "harness": "fake", "cwd": "/tmp", "status": "idle",
            "createdAt": 1, "updatedAt": i + 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    crate::hub::Hub::new(config, store)
}

/// A connection, initialized.
async fn connect(hub: &Arc<crate::hub::Hub>) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    reply(&mut outgoing, 1).await;
    (input, outgoing)
}

async fn reply(outgoing: &mut mpsc::Receiver<String>, id: u64) -> Value {
    tokio::time::timeout(Duration::from_secs(120), async {
        loop {
            let line = outgoing.recv().await.expect("the connection answers");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                assert!(reply.get("error").is_none(), "{}", &line[..line.len().min(400)]);
                return reply["result"].clone();
            }
        }
    })
    .await
    .expect("the reply comes")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_reads_of_one_page_share_its_build() {
    let hub = hub();
    // Every read waits at its dispatch until all of them are there, then they go at once.
    let gate = Arc::new(tokio::sync::Barrier::new(CALLERS));
    hub.hold_requests_for_tests(Arc::new(move |stage, m: &str, _id: &Value| {
        let gate = gate.clone();
        let ours = stage == RequestStage::Dispatch && m == method::MUX_SESSIONS;
        let held: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> =
            Box::pin(async move {
                if ours {
                    gate.wait().await;
                }
            });
        held
    }));
    let mut clients = Vec::new();
    for _ in 0..CALLERS {
        clients.push(connect(&hub).await);
    }
    let before = rows_built(&hub);
    let reads: Vec<_> = clients
        .into_iter()
        .map(|(input, mut outgoing)| {
            tokio::spawn(async move {
                let params = json!({"excludeStatus": ["closed"], "limit": 500});
                input
                    .send(Message::request(2, method::MUX_SESSIONS, params).to_line())
                    .await
                    .unwrap();
                let page = reply(&mut outgoing, 2).await;
                page["sessions"].as_array().map_or(0, Vec::len)
            })
        })
        .collect();
    for read in reads {
        assert_eq!(read.await.unwrap(), CHATS, "every read gets the whole page");
    }
    let built = rows_built(&hub) - before;
    // One build for the reads that came before it started, one more for any that came while it
    // ran: never one per read (16 x CHATS before).
    assert!(
        built <= 3 * CHATS,
        "{CALLERS} concurrent reads of one {CHATS}-row page built {built} rows: each read built \
         the page again"
    );
}
