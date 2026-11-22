use super::{
    NOTIFICATION_QUEUE_LIMIT, NOTIFICATION_WORK_LIMIT, REQUEST_WORK_LIMIT, notification_deadline,
    request_uses_work_budget, try_request_slot,
};
use std::sync::Arc;
use tokio::sync::Semaphore;

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
