//! Panic injection for a client request: a handler that panics with a hub lock held
//! reaches the hub's supervisor as `Fatal`, and no answer goes out from a daemon whose
//! lock is poisoned.

use std::time::Duration;

use serde_json::json;
use tokio::sync::mpsc;

use super::*;
use crate::server::{ConnAuth, Origin};
use crate::supervised::tests::Recorded;

fn conn() -> (Arc<Conn>, mpsc::Receiver<String>) {
    let (out, answers) = mpsc::channel(8);
    (Arc::new(Conn::new(Origin::Local, ConnAuth::LocalSocket, None, None, out)), answers)
}

#[tokio::test]
async fn a_request_that_panics_holding_the_hubs_sessions_is_fatal() {
    let (supervisor, sink) = Recorded::supervisor();
    let hub = Hub::in_memory(supervisor);
    let (conn, mut answers) = conn();
    let handler = hub.clone();
    start(
        hub.supervisor(),
        &conn,
        json!(1),
        "test/panic",
        None,
        Box::pin(async move {
            handler.panic_holding_sessions();
            Ok::<_, RpcError>(Value::Null)
        }),
    );
    let report = sink.first().await;
    assert_eq!(report.worker, REQUEST_WORKER);
    assert!(report.to_string().contains("injected"), "{report}");
    assert!(hub.sessions_poisoned());
    // No "the request failed" from a daemon serving on with the lock poisoned.
    assert!(answers.try_recv().is_err());
}

#[tokio::test]
async fn a_request_answers_on_its_connection() {
    let (supervisor, sink) = Recorded::supervisor();
    let hub = Hub::in_memory(supervisor);
    let (conn, mut answers) = conn();
    start(
        hub.supervisor(),
        &conn,
        json!(7),
        "test/ok",
        None,
        Box::pin(async { Ok::<_, RpcError>(json!({"done": true})) }),
    );
    let line = tokio::time::timeout(Duration::from_secs(5), answers.recv())
        .await
        .expect("answered within 5 s")
        .expect("an answer");
    let answer: Value = serde_json::from_str(&line).expect("json");
    assert_eq!(answer["id"], 7);
    assert_eq!(answer["result"]["done"], true);
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn a_request_after_shutdown_is_refused_at_once() {
    let (supervisor, sink) = Recorded::supervisor();
    let hub = Hub::in_memory(supervisor);
    let report = hub.supervisor().shutdown();
    assert!(report.late.is_empty(), "{report:?}");
    let (conn, mut answers) = conn();
    start(
        hub.supervisor(),
        &conn,
        json!(3),
        "test/late",
        None,
        Box::pin(async { Ok::<_, RpcError>(Value::Null) }),
    );
    let line = answers.try_recv().expect("refused at once");
    let answer: Value = serde_json::from_str(&line).expect("json");
    assert_eq!(answer["id"], 3);
    assert!(answer["error"]["message"].as_str().is_some_and(|m| m.contains("not started")));
    assert!(sink.reports().is_empty());
}
