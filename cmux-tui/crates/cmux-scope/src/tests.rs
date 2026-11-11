use super::*;
use std::sync::atomic::AtomicUsize;

/// A task that ends at the scope's cancellation, counting its ends.
fn polite(scope: &Scope, name: &'static str, ended: &Arc<AtomicUsize>) {
    let stop = scope.cancelled();
    let ended = ended.clone();
    scope.spawn_named(name, async move {
        stop.await;
        ended.fetch_add(1, Ordering::SeqCst);
    });
}

#[tokio::test(start_paused = true)]
async fn close_cancels_and_joins_every_task() {
    let scope = Scope::new("test");
    let ended = Arc::new(AtomicUsize::new(0));
    for _ in 0..5 {
        polite(&scope, "polite", &ended);
    }
    tokio::task::yield_now().await;
    assert_eq!(scope.len(), 5);
    let report = scope.close(Duration::from_secs(1)).await;
    assert!(report.joined(), "{report}");
    assert_eq!(ended.load(Ordering::SeqCst), 5);
    assert!(scope.is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_task_that_ignores_the_cancellation_is_named_and_aborted_at_the_deadline() {
    let scope = Scope::new("test");
    let ended = Arc::new(AtomicUsize::new(0));
    polite(&scope, "polite", &ended);
    let stubborn = scope.spawn_named("stubborn", async {
        tokio::time::sleep(Duration::from_secs(3600)).await;
    });
    let unnamed = scope.spawn(std::future::pending::<()>());
    let started = tokio::time::Instant::now();
    let report = scope.close(Duration::from_secs(2)).await;
    assert_eq!(started.elapsed(), Duration::from_secs(2), "the close waited out its deadline");
    assert_eq!(report.still_running.len(), 2, "{report}");
    assert!(report.still_running.contains(&"stubborn".to_owned()), "{report}");
    assert!(
        report.still_running.iter().any(|name| name.starts_with(file!())),
        "an unnamed task is named by where it was spawned: {report}"
    );
    assert!(stubborn.await.unwrap_err().is_cancelled(), "the stubborn task was aborted");
    assert!(unnamed.await.unwrap_err().is_cancelled());
    assert_eq!(ended.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn a_child_closes_alone_and_a_parent_close_takes_its_children() {
    let parent = Scope::new("parent");
    let child = parent.child("child");
    let grandchild = child.child("grandchild");
    let ended = Arc::new(AtomicUsize::new(0));
    polite(&parent, "p", &ended);
    polite(&child, "c", &ended);
    polite(&grandchild, "g", &ended);
    tokio::task::yield_now().await;

    // The grandchild's close ends its own task, no other.
    assert!(grandchild.close(Duration::from_secs(1)).await.joined());
    assert_eq!(ended.load(Ordering::SeqCst), 1);
    assert!(!child.is_cancelled());

    // A stubborn task in the child is the parent's to report too.
    child.spawn_named("child-stubborn", std::future::pending::<()>());
    let report = parent.close(Duration::from_secs(1)).await;
    assert_eq!(report.still_running, vec!["child-stubborn".to_owned()], "{report}");
    assert!(child.is_cancelled(), "a parent's close cancels its child");
    assert_eq!(ended.load(Ordering::SeqCst), 3);
    // The child was cancelled and its stubborn task aborted: its own close joins at once.
    assert!(child.close(Duration::from_millis(1)).await.joined());
}

#[tokio::test(start_paused = true)]
async fn a_task_spawned_after_close_starts_cancelled() {
    let scope = Scope::new("test");
    assert!(scope.close(Duration::from_secs(1)).await.joined());
    let stop = scope.cancelled();
    let late = scope.spawn(stop);
    tokio::time::timeout(Duration::from_secs(1), late).await.unwrap().unwrap();
}

#[tokio::test(start_paused = true)]
async fn a_scope_dropped_without_close_cancels_its_tasks_and_panics_in_tests() {
    let ended = Arc::new(AtomicUsize::new(0));
    let scope = Scope::new("forgetful-owner");
    polite(&scope, "polite", &ended);
    tokio::task::yield_now().await;
    let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(scope)))
        .expect_err("a drop without close must panic under cfg(test)");
    let message = panic.downcast_ref::<String>().cloned().unwrap_or_default();
    assert!(message.contains("forgetful-owner") && message.contains("polite"), "{message}");
    // It still cancelled them.
    tokio::task::yield_now().await;
    assert_eq!(ended.load(Ordering::SeqCst), 1);
}

#[tokio::test(start_paused = true)]
async fn a_scope_dropped_with_nothing_running_is_quiet() {
    let scope = Scope::new("test");
    scope.spawn(async {}).await.unwrap();
    drop(scope);
    drop(Scope::new("never used"));
}

#[test]
fn a_report_reads_as_a_sentence() {
    let joined = CloseReport { owner: "hub", still_running: Vec::new() };
    assert_eq!(joined.to_string(), "hub: every task joined");
    let late = CloseReport { owner: "hub", still_running: vec!["idle-reaper".into()] };
    assert_eq!(
        late.to_string(),
        "hub: 1 task(s) ignored the cancellation and were aborted at the deadline: idle-reaper"
    );
}
