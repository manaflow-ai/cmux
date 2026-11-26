use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn panicking(
    runs: &Arc<AtomicUsize>,
    until: usize,
) -> impl FnMut() -> std::future::Ready<()> + use<> {
    let runs = runs.clone();
    move || {
        let run = runs.fetch_add(1, Ordering::SeqCst) + 1;
        assert!(run > until, "test panic {run}");
        std::future::ready(())
    }
}

#[tokio::test(start_paused = true)]
async fn a_task_that_panics_runs_again_and_one_that_returns_does_not() {
    let (fatal, runs) = (Fatal::default(), Arc::new(AtomicUsize::new(0)));
    restarting("test", &fatal, panicking(&runs, 2)).await.unwrap();
    assert_eq!(runs.load(Ordering::SeqCst), 3, "two panics, then the run that returned");
    assert!(fatal.0.borrow().is_none(), "two panics are under the limit");
}

#[tokio::test(start_paused = true)]
async fn a_task_that_keeps_panicking_raises_fatal_and_stops() {
    let (fatal, runs) = (Fatal::default(), Arc::new(AtomicUsize::new(0)));
    restarting("test", &fatal, panicking(&runs, usize::MAX)).await.unwrap();
    assert_eq!(runs.load(Ordering::SeqCst), MAX_RESTARTS + 1);
    assert!(fatal.raised().await.contains("the test task panicked 6 times"));
}

#[tokio::test(start_paused = true)]
async fn panics_spread_over_time_never_raise_fatal() {
    let (fatal, runs) = (Fatal::default(), Arc::new(AtomicUsize::new(0)));
    let seen = runs.clone();
    let task = restarting("test", &fatal, move || {
        let run = seen.fetch_add(1, Ordering::SeqCst);
        async move {
            tokio::time::sleep(WINDOW).await;
            assert!(run >= 20, "test panic {run}");
        }
    });
    task.await.unwrap();
    assert_eq!(runs.load(Ordering::SeqCst), 21);
    assert!(fatal.0.borrow().is_none());
}

#[tokio::test]
async fn a_task_that_cannot_run_twice_raises_fatal_on_its_panic() {
    let fatal = Fatal::default();
    once("startup", &fatal, async { panic!("test panic") }).await.unwrap();
    assert_eq!(fatal.raised().await, "the startup task panicked and cannot start again");
    // The first reason stays.
    fatal.raise("another".into());
    assert_eq!(fatal.raised().await, "the startup task panicked and cannot start again");
}
