use super::*;
use cmux_link::elapsed::Elapsed;
use std::time::{Duration, Instant};

#[tokio::test]
async fn receiver_elapsed_deadline_wakes_without_an_active_clock_timer() {
    let budget = Elapsed::system().unwrap().deadline_at(Duration::from_millis(500)).unwrap();
    #[cfg(target_os = "linux")]
    assert!(budget.boottime().is_some());
    let retained = budget.clone();
    let (started, observed) = tokio::sync::oneshot::channel();
    let mut waiting = tokio::spawn(async move {
        let _ = started.send(());
        expired(Instant::now() + Duration::from_secs(3600), Some(budget)).await;
    });
    observed.await.unwrap();
    assert!(retained.remaining().is_some(), "fixture did not observe the live pending wait");
    let result = tokio::time::timeout(Duration::from_secs(5), &mut waiting).await;
    if result.is_err() {
        waiting.abort();
        let _ = waiting.await;
        panic!("elapsed deadline never woke its independent task");
    }
    result.unwrap().unwrap();
    assert!(retained.remaining().is_none(), "the wake returned before clock expiry");
}
