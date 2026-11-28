use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

#[test]
fn cloud_prepare_deadline_is_defaulted_bounded_and_strictly_typed() {
    assert_eq!(preparation_budget(None, 1000).unwrap(), Duration::from_secs(120));
    assert_eq!(preparation_budget(Some(&json!(601000)), 1000).unwrap(), Duration::from_secs(600));
    for invalid in [json!(1000), json!(999), json!(601001), json!(null), json!("2000"), json!(-1)] {
        assert!(preparation_budget(Some(&invalid), 1000).is_err(), "{invalid}");
    }
}

struct Dropped(Arc<AtomicBool>);
impl Drop for Dropped {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

#[tokio::test(start_paused = true)]
async fn cloud_prepare_timeout_drops_waiter_without_a_background_task() {
    let (ended, receiver) = tokio::sync::watch::channel(false);
    let (cancel_sender, cancel) = tokio::sync::watch::channel(false);
    let dropped = Arc::new(AtomicBool::new(false));
    let guard = Dropped(dropped.clone());
    let wait = async move {
        let _guard = guard;
        std::future::pending::<Result<(), RpcError>>().await
    };
    assert!(
        bounded_preparation(
            wait,
            tokio::time::Instant::now() + Duration::from_secs(1),
            receiver,
            cancel.clone()
        )
        .await
        .is_err()
    );
    assert!(dropped.load(Ordering::SeqCst));
    drop((ended, cancel_sender));
}

#[tokio::test]
async fn cloud_prepare_disconnect_and_cancel_drop_inflight_verification_or_wait() {
    for disconnect in [false, true] {
        let (ended, receiver) = tokio::sync::watch::channel(false);
        let (cancel_sender, cancel) = tokio::sync::watch::channel(false);
        let dropped = Arc::new(AtomicBool::new(false));
        let guard = Dropped(dropped.clone());
        let wait = async move {
            let _guard = guard;
            std::future::pending::<Result<(), RpcError>>().await
        };
        let mut ready = Box::pin(bounded_preparation(
            wait,
            tokio::time::Instant::now() + Duration::from_secs(120),
            receiver,
            cancel.clone(),
        ));
        assert!(futures::poll!(&mut ready).is_pending());
        if disconnect {
            ended.send_replace(true);
        } else {
            cancel_sender.send_replace(true);
        }
        assert!(ready.await.is_err());
        assert!(dropped.load(Ordering::SeqCst));
    }
}

#[tokio::test(start_paused = true)]
async fn cloud_prepare_ready_response_has_no_remaining_deadline_timer() {
    let (ended, receiver) = tokio::sync::watch::channel(false);
    let (cancel_sender, cancel) = tokio::sync::watch::channel(false);
    let ready = bounded_preparation(
        async { Ok("reserved") },
        tokio::time::Instant::now() + Duration::from_secs(1),
        receiver,
        cancel.clone(),
    )
    .await
    .unwrap();
    tokio::time::advance(Duration::from_secs(600)).await;
    assert_eq!(ready, "reserved");
    assert!(!*cancel.borrow());
    drop((ended, cancel_sender));
}

#[tokio::test]
async fn cloud_prepare_rechecks_disconnect_after_ready_result() {
    let (ended, receiver) = tokio::sync::watch::channel(false);
    let (cancel_sender, cancel) = tokio::sync::watch::channel(false);
    let wait = async {
        ended.send_replace(true);
        Ok("ready but disconnected")
    };
    assert!(
        bounded_preparation(
            wait,
            tokio::time::Instant::now() + Duration::from_secs(1),
            receiver,
            cancel.clone()
        )
        .await
        .is_err()
    );
    drop(cancel_sender);
}
