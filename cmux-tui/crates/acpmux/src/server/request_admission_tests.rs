use super::{
    NOTIFICATION_QUEUE_LIMIT, NOTIFICATION_WORK_LIMIT, REQUEST_WORK_LIMIT, notification_deadline,
    request_uses_work_budget, try_request_slot,
};
use crate::config::{Config, StoreMode};
use crate::hub::Hub;
use crate::rpc::{Message, method};
use std::path::Path;
use std::sync::Arc;
use tokio::sync::{Semaphore, mpsc};

#[test]
fn long_running_requests_do_not_consume_short_work_budget() {
    assert!(!request_uses_work_budget(crate::rpc::method::SESSION_PROMPT));
    assert!(!request_uses_work_budget(crate::rpc::method::MUX_WAIT));
    assert!(!request_uses_work_budget(crate::rpc::method::SESSION_NEW));
    assert!(!request_uses_work_budget(crate::rpc::method::SESSION_LOAD));
    assert!(!request_uses_work_budget(crate::rpc::method::SESSION_RESUME));
    assert!(!request_uses_work_budget(crate::rpc::method::SESSION_FORK));
    assert!(!request_uses_work_budget(crate::rpc::method::MUX_ATTACH));
    // A method no handler serves; built, not a literal, so the registry check
    // (protocol::tests) does not read it as a served method.
    let unknown = ["_acpmux", "unknown"].join("/");
    assert!(request_uses_work_budget(&unknown));

    let slots = Semaphore::new(REQUEST_WORK_LIMIT);
    let _holds: Vec<_> =
        (0..REQUEST_WORK_LIMIT).map(|_| slots.try_acquire().expect("short work slot")).collect();
    assert!(slots.try_acquire().is_err());

    // Open prompts and waits are admitted independently of the finite
    // handler budget, so a connection can keep more than 64 turns open.
    let slots = Arc::new(Semaphore::new(REQUEST_WORK_LIMIT));
    for _ in 0..(REQUEST_WORK_LIMIT + 1) {
        assert!(try_request_slot(&slots, crate::rpc::method::SESSION_PROMPT).unwrap().is_none());
    }
}

#[test]
fn cancellation_handlers_have_no_abort_deadline() {
    assert_eq!(notification_deadline(crate::rpc::method::SESSION_CANCEL), None);
    assert_eq!(notification_deadline("$/cancel_request"), Some(super::WORK_BACKPRESSURE_WAIT));
}

#[tokio::test]
async fn accepted_notification_is_drained_after_input_disconnects() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::mpsc;

    let (tx, rx) = mpsc::channel(1);
    let handled = Arc::new(AtomicUsize::new(0));
    let worker = super::spawn_notification_worker(rx, {
        let handled = handled.clone();
        move |_method, _params| {
            let handled = handled.clone();
            async move {
                handled.fetch_add(1, Ordering::SeqCst);
            }
        }
    });
    tx.send(("session/cancel".to_owned(), serde_json::json!({}))).await.unwrap();
    drop(tx);
    worker.await.unwrap();
    assert_eq!(handled.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn cancellation_lane_is_independent_of_slow_notifications() {
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::sync::{Notify, mpsc};

    let (notification_tx, notification_rx) = mpsc::channel(NOTIFICATION_QUEUE_LIMIT);
    let (cancel_tx, cancel_rx) = mpsc::channel(NOTIFICATION_QUEUE_LIMIT);
    let notification_started = Arc::new(Notify::new());
    let release_notifications = Arc::new(Notify::new());
    let cancel_handled = Arc::new(AtomicBool::new(false));

    let notification_worker = super::spawn_notification_worker(notification_rx, {
        let notification_started = notification_started.clone();
        let release_notifications = release_notifications.clone();
        move |_method, _params| {
            let notification_started = notification_started.clone();
            let release_notifications = release_notifications.clone();
            async move {
                notification_started.notify_one();
                release_notifications.notified().await;
            }
        }
    });
    let cancel_worker = super::spawn_notification_worker(cancel_rx, {
        let cancel_handled = cancel_handled.clone();
        move |_method, _params| {
            let cancel_handled = cancel_handled.clone();
            async move { cancel_handled.store(true, Ordering::SeqCst) }
        }
    });

    for _ in 0..NOTIFICATION_WORK_LIMIT {
        notification_tx.try_send(("session/update".to_owned(), serde_json::json!({}))).unwrap();
    }
    notification_started.notified().await;
    cancel_tx
        .send((crate::rpc::method::SESSION_CANCEL.to_owned(), serde_json::json!({})))
        .await
        .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        while !cancel_handled.load(Ordering::SeqCst) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("cancel lane should not wait for ordinary handlers");

    release_notifications.notify_waiters();
    drop(notification_tx);
    drop(cancel_tx);
    notification_worker.await.unwrap();
    cancel_worker.await.unwrap();
}

#[tokio::test]
async fn cancellation_worker_finishes_after_input_closes() {
    use tokio::sync::{Notify, mpsc};

    let (tx, rx) = mpsc::channel(1);
    let started = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let mut worker = super::spawn_notification_worker(rx, {
        let started = started.clone();
        let release = release.clone();
        move |_method, _params| {
            let started = started.clone();
            let release = release.clone();
            async move {
                started.notify_one();
                release.notified().await;
            }
        }
    });

    tx.send((crate::rpc::method::SESSION_CANCEL.to_owned(), serde_json::json!({}))).await.unwrap();
    started.notified().await;
    drop(tx);
    assert!(tokio::time::timeout(std::time::Duration::from_millis(50), &mut worker).await.is_err());
    release.notify_one();
    worker.await.unwrap();
}

fn stopped_hub() -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(serde_json::json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

async fn read_response(rx: &mut mpsc::Receiver<String>, id: i64) -> Message {
    loop {
        let line = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
            .await
            .expect("the stopped request was not refused")
            .expect("the reader closed before refusing the request");
        let message = Message::parse(&line).unwrap();
        if matches!(&message, Message::Response { id: got, .. } if *got == id) {
            return message;
        }
    }
}

#[tokio::test]
async fn a_request_read_after_stop_is_refused_before_anything_is_made() {
    let hub = stopped_hub();
    let (in_tx, in_rx) = mpsc::channel(4);
    let (out_tx, mut out_rx) = mpsc::channel(16);
    let server = tokio::spawn(super::super::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    hub.shutdown_all().await;
    in_tx
        .send(Message::request(1, method::SESSION_NEW, serde_json::json!({})).to_line())
        .await
        .unwrap();
    let response = read_response(&mut out_rx, 1).await;
    match response {
        Message::Response { error: Some(error), .. } => {
            assert_eq!(error.message, crate::hub::SHUTTING_DOWN);
            assert_eq!(
                error.data.as_ref().and_then(|d| d.get("created")),
                Some(&serde_json::json!(false))
            );
        }
        other => panic!("expected an ordered refusal, got {other:?}"),
    }
    drop(in_tx);
    server.await.unwrap();
}

#[tokio::test]
async fn a_create_read_after_stop_makes_no_session() {
    let hub = stopped_hub();
    let before = hub.session_counts();
    let (in_tx, in_rx) = mpsc::channel(4);
    let (out_tx, mut out_rx) = mpsc::channel(16);
    let server = tokio::spawn(super::super::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    hub.shutdown_all().await;
    for id in [1, 2] {
        in_tx
            .send(Message::request(id, method::SESSION_NEW, serde_json::json!({})).to_line())
            .await
            .unwrap();
        let response = read_response(&mut out_rx, id).await;
        assert!(matches!(response, Message::Response { error: Some(_), .. }));
    }
    assert_eq!(hub.session_counts(), before, "a refused create inserted a session");
    drop(in_tx);
    server.await.unwrap();
}
