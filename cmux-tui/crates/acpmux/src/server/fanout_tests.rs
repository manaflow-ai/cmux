/// A chat id with this prefix panics the fan-out task at its first delivery: no shared state,
/// so parallel tests never trip each other (the test-hooks check, cmux#41350).
pub(in crate::server) const PANIC_PREFIX: &str = "fanout-test-panic-";

pub(super) fn panic_if_marked(session: &str) {
    if session.starts_with(PANIC_PREFIX) {
        panic!("fan-out test panic for {session}");
    }
}

/// A connection named with this prefix (its `initialize` `clientInfo.name`) has the hub
/// events its fan-out task woke for counted under that name (`fanout_interest_tests.rs`). A
/// name is one test's own, so parallel tests never read each other's counts.
pub(in crate::server) const WAKE_PREFIX: &str = "fanout-wake-";

static WAKES: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, u64>>> =
    std::sync::LazyLock::new(Default::default);

pub(super) fn count_wake(conn: &super::Conn) {
    let name = conn.name.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if name.starts_with(WAKE_PREFIX) {
        *WAKES.lock().unwrap_or_else(|e| e.into_inner()).entry(name).or_default() += 1;
    }
}

/// A stalled fan-out holds two counts however many turns ask it to flush (RFD 0124 R4), and
/// its one drain answers every ask made before it, none waiting out `FLUSH_BOUND`.
#[tokio::test]
async fn flush_asks_coalesce_while_the_fan_out_is_stalled() {
    let (flush, mut flushes) = super::Flush::channel();
    let flush = std::sync::Arc::new(flush);
    let started = std::time::Instant::now();
    let waits: Vec<_> = (0..10_000)
        .map(|_| {
            let flush = flush.clone();
            tokio::spawn(async move { flush.sent().await })
        })
        .collect();
    while *flush.asked.borrow() < 10_000 {
        tokio::task::yield_now().await;
    }
    assert_eq!(flushes.asked().await, Some(10_000), "one wake for every ask");
    flushes.served(10_000);
    for wait in waits {
        wait.await.expect("ask");
    }
    assert!(started.elapsed() < super::FLUSH_BOUND, "an ask waited out its bound");
    // An ask after the drain waits for the next one.
    let next = tokio::spawn({
        let flush = flush.clone();
        async move { flush.sent().await }
    });
    assert_eq!(flushes.asked().await, Some(10_001));
    assert!(!next.is_finished());
    flushes.served(10_001);
    next.await.expect("next ask");
}

/// An ended fan-out answers an ask at once, as a closed channel did.
#[tokio::test]
async fn a_flush_after_the_fan_out_ended_returns_at_once() {
    let (flush, flushes) = super::Flush::channel();
    drop(flushes);
    let started = std::time::Instant::now();
    flush.sent().await;
    assert!(started.elapsed() < super::FLUSH_BOUND);
}

/// Hub events the fan-out of the connection named `name` woke for.
pub(in crate::server) fn wakes(name: &str) -> u64 {
    WAKES.lock().unwrap_or_else(|e| e.into_inner()).get(name).copied().unwrap_or(0)
}
