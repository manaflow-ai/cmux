//! A reply never overtakes a hub event published before it (`hub/event_bus.rs`): a turn's
//! `session/update`s reach the client before the `session/prompt` result that ends it.
//! Before, the fan-out task sent the updates and the request task sent the reply, each on
//! its own, so the reply could come first (chats_open.rs
//! a_chat_in_a_store_no_profile_uses_adopts_with_that_store read no text).

use std::sync::Arc;

use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::hub::Hub;
use crate::rpc::Message;
use crate::server::{Conn, ConnAuth, Origin};
use crate::supervised::tests::Recorded;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reply_follows_every_update_published_before_it() {
    let (supervisor, _sink) = Recorded::supervisor();
    let hub: Arc<Hub> = Hub::in_memory(supervisor);
    let (out, mut lines) = mpsc::channel::<String>(4096);
    let conn = Arc::new(Conn::new(Origin::Local, ConnAuth::LocalSocket, None, None, out));
    assert!(conn.subscribe("s-order"));
    let fan = super::start(hub.clone(), conn.clone());
    const UPDATES: u64 = 500;
    for seq in 1..=UPDATES {
        hub.publish_test_update("s-order", seq, &format!("chunk {seq}"));
    }
    // What a request task does before its reply.
    conn.events_handed_on(&hub).await;
    conn.send(&Message::ok(json!(1), json!({})));
    let mut updates = 0;
    loop {
        let line = lines.recv().await.expect("the connection is open");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            break;
        }
        if v.get("method") == Some(&json!("session/update")) {
            updates += 1;
        }
    }
    assert_eq!(updates, UPDATES, "the reply came before an update published before it");
    fan.abort();
}
