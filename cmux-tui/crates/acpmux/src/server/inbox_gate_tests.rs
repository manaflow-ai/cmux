//! Who reads a chat's held messages (`_acpmux/inbox_threads`, `_acpmux/inbox_thread`): the
//! person, on the app's own pane too. The pane (`Origin::LocalApp`) never sends
//! `_acpmux/person_prove`, so a gate on `is_person` alone refused its held messages panel, and it
//! said only "Couldn't read the held messages. Try again" (Leo, 2026-11-22: "the thing here on
//! expansion also doesn't work, and it gives a (im assuming) useless "try again.""). A remote
//! page that proved no person still reads nothing.

use super::Origin;
use super::ack_latency_bench::Client;
use crate::config::{Config, StoreMode};
use crate::rpc::method;
use serde_json::json;
use std::sync::Arc;

fn hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "busy", "name": "busy", "title": "busy",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
    }))
    .unwrap();
    store.save(&meta).unwrap();
    crate::hub::Hub::new(config, store)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_apps_pane_reads_the_held_messages_and_an_unproven_page_does_not() {
    let hub = hub();
    let params = json!({"sessionId": "busy"});
    let thread = json!({"sessionId": "busy", "threadId": "runners"});
    let pane = Client::on(&hub, Origin::LocalApp).await;
    let (reply, _) = pane.call(method::MUX_INBOX_THREADS, params.clone()).await;
    assert_eq!(reply["result"]["sessionId"], "busy", "{reply}");
    assert!(reply["result"]["surge"].is_object(), "{reply}");
    let (reply, _) = pane.call(method::MUX_INBOX_THREAD, thread.clone()).await;
    assert!(reply.get("error").is_none(), "the pane opens a thread: {reply}");

    let page = Client::on(&hub, Origin::Web).await;
    let (reply, _) = page.call(method::MUX_INBOX_THREADS, params).await;
    assert!(reply.get("result").is_none(), "an unproven page reads nothing: {reply}");
}
