use super::*;
use std::sync::{Arc, Mutex};

#[tokio::test(start_paused = true)]
async fn a_slow_read_says_so_once_and_keeps_waiting() {
    let said = Arc::new(Mutex::new(Vec::new()));
    let keep = said.clone();
    let out = noted_to(
        "the session list",
        AFTER,
        async {
            tokio::time::sleep(AFTER * 3).await;
            7
        },
        move |line| keep.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(line),
    )
    .await;
    assert_eq!(out, 7, "the read's own result");
    let said = said.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    assert_eq!(said.len(), 1, "{said:?}");
    assert!(said[0].starts_with("acpmux: the daemon has not answered the session list in 10s;"));
    assert!(said[0].ends_with("daemon.log"), "{}", said[0]);
}

#[tokio::test(start_paused = true)]
async fn a_quick_read_says_nothing() {
    let mut said = 0;
    let out = noted_to("the status", AFTER, async { "ok" }, |_| said += 1).await;
    assert_eq!((out, said), ("ok", 0));
}
