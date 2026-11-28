use super::*;
use std::cell::Cell;

#[test]
fn a_transient_failure_is_retried_until_it_passes() {
    let tries = Cell::new(0);
    let out: Result<u32, &str> = Patience::new("a test", Duration::from_secs(5))
        .quiet()
        .spaced(Duration::from_millis(1), Duration::from_millis(2))
        .run(|| {
            tries.set(tries.get() + 1);
            if tries.get() < 4 { Err(Attempt::Retry("busy")) } else { Ok(7) }
        });
    assert_eq!(out, Ok(7));
    assert_eq!(tries.get(), 4);
}

#[test]
fn a_lasting_failure_stops_at_once() {
    let tries = Cell::new(0);
    let out: Result<(), &str> = Patience::new("a test", Duration::from_secs(5)).quiet().run(|| {
        tries.set(tries.get() + 1);
        Err(Attempt::Fail("refused"))
    });
    assert_eq!(out, Err("refused"));
    assert_eq!(tries.get(), 1);
}

#[test]
fn the_deadline_ends_the_tries_with_the_last_transient_error() {
    let started = Instant::now();
    let tries = Cell::new(0);
    let out: Result<(), String> = Patience::new("a test", Duration::from_millis(150))
        .quiet()
        .spaced(Duration::from_millis(5), Duration::from_millis(20))
        .run(|| {
            tries.set(tries.get() + 1);
            Err(Attempt::Retry(format!("busy {}", tries.get())))
        });
    assert_eq!(out, Err(format!("busy {}", tries.get())));
    assert!(tries.get() > 2, "only {} tries", tries.get());
    assert!(started.elapsed() < Duration::from_millis(400));
}

#[test]
fn a_retry_after_longer_than_the_deadline_is_not_slept() {
    let started = Instant::now();
    let out: Result<(), &str> = Patience::new("a test", Duration::from_millis(100))
        .quiet()
        .run(|| Err(Attempt::RetryAfter("rate limited", Duration::from_secs(60))));
    assert_eq!(out, Err("rate limited"));
    assert!(started.elapsed() < Duration::from_millis(50));
}

#[test]
fn the_notice_is_printed_at_most_once() {
    let mut patience = Patience::new("a test", Duration::from_secs(60))
        .spaced(Duration::from_millis(1), Duration::from_millis(1));
    patience.notice = Notice::Pending;
    patience.notice_after = Duration::ZERO;
    assert!(patience.next_wait(None).is_some());
    assert_eq!(patience.notice, Notice::Done);
    assert!(patience.next_wait(None).is_some());
    assert_eq!(patience.notice, Notice::Done);
}

#[cfg(feature = "tokio")]
#[tokio::test]
async fn async_tries_retry_the_same_way() {
    let tries = std::sync::atomic::AtomicU32::new(0);
    let out: Result<u32, &str> = Patience::new("a test", Duration::from_secs(5))
        .quiet()
        .spaced(Duration::from_millis(1), Duration::from_millis(2))
        .run_async(
            || "timed out",
            || {
                let n = tries.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                async move { if n < 3 { Err(Attempt::Retry("busy")) } else { Ok(n) } }
            },
        )
        .await;
    assert_eq!(out, Ok(3));
}

#[cfg(feature = "tokio")]
#[tokio::test(start_paused = true)]
async fn async_deadline_ends_a_pending_attempt_without_replaying_it() {
    for answered in [false, true] {
        let tries = Cell::new(0);
        let operation = Patience::new("the reply", Duration::from_secs(10))
            .quiet()
            .spaced(Duration::ZERO, Duration::ZERO)
            .run_async(
                || "no reply",
                || {
                    let first = tries.get() == 0;
                    tries.set(tries.get() + 1);
                    async move {
                        if first && answered {
                            Err(Attempt::Retry("partial reply"))
                        } else {
                            std::future::pending::<Result<(), _>>().await
                        }
                    }
                },
            );
        let out = tokio::time::timeout(Duration::from_secs(11), operation)
            .await
            .expect("even a pending attempt must finish within the budget");
        assert_eq!(out, Err(if answered { "partial reply" } else { "no reply" }));
        assert_eq!(tries.get(), if answered { 2 } else { 1 });
    }
}
