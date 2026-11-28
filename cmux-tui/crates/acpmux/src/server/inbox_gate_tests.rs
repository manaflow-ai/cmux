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

#[tokio::test]
async fn gathered_fyi_request_keeps_its_batch_flag_in_the_inbox_journal() {
    use crate::rpc::Message;
    use serde_json::Value;
    use std::time::Duration;
    use tokio::sync::mpsc;

    let hub = hub();
    let session = hub.resolve("busy").unwrap();
    // An established chat: first-work admission intentionally bypasses the inbox.
    hub.edit_test_meta(&session, |meta| meta.turn_count = 1);
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel::<String>(32);
    let server =
        tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    input
        .send(
            Message::request(
                1,
                method::INITIALIZE,
                json!({"protocolVersion": 1, "clientInfo": {
                    "name": crate::peer::CLIENT_NAME, "version": "0"
                }}),
            )
            .to_line(),
        )
        .await
        .unwrap();

    for (request_id, prompt_id, gather) in [(2, "gathered-fyi", true), (3, "ordinary-fyi", false)] {
        // Exercise the wire metadata, not a preconstructed provenance object: requests.rs
        // must validate this flag and carry it across the provenance conversion.
        input
            .send(
                Message::request(
                    request_id,
                    method::SESSION_PROMPT,
                    json!({
                        "sessionId": "busy",
                        "prompt": [{"type": "text", "text": prompt_id}],
                        "_meta": {"acpmux": {
                            "promptId": prompt_id, "fromAgent": "bridge",
                            "class": "fyi", "steer": true, "gather": gather
                        }}
                    }),
                )
                .to_line(),
            )
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let line = outgoing.recv().await.expect("connection remains open");
                let message: Value = serde_json::from_str(&line).unwrap();
                assert!(message.get("error").is_none(), "request refused: {message}");
                if message["method"] == method::MUX_PROMPT_ACCEPTED
                    && message["params"]["promptId"] == prompt_id
                {
                    assert_eq!(message["params"]["inbox"], true, "{message}");
                    break;
                }
            }
        })
        .await
        .expect("FYI admission acknowledges without waiting for delivery");

        let events = hub.events("busy", 0, 100).unwrap();
        let admitted = events
            .iter()
            .find(|event| event.kind == "inbox" && event.msg["promptId"] == prompt_id)
            .expect("accepted FYI is journaled");
        assert_eq!(admitted.msg["class"], "fyi");
        assert_eq!(
            admitted.msg.pointer("/_meta/provenance/gather") == Some(&json!(true)),
            gather,
            "wire gather flag survives admission: {:?}",
            admitted.msg
        );
    }
    // These are held FYIs: no real harness is needed or launched by this transport test.
    assert!(!hub.events("busy", 0, 100).unwrap().iter().any(|event| event.kind == "user_message"));
    server.abort();
}
