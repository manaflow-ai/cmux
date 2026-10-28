//! Panic injection for each policy acpmux uses: a [`Fatal`] task, thread or
//! [`call`] reaches the process's failure sink under its name; a scoped task or
//! thread ends only its own scope, closing its channels for the other side.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_panic_log::{FailureSink, FatalReason, FatalReport};

use super::*;

/// Records fatal reports instead of ending the test process.
#[derive(Default)]
pub(crate) struct Recorded {
    reports: Mutex<Vec<FatalReport>>,
    seen: tokio::sync::Notify,
}

impl FailureSink for Recorded {
    fn fatal(&self, report: &FatalReport) {
        self.reports.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(report.clone());
        self.seen.notify_one();
    }
}

impl Recorded {
    pub(crate) fn supervisor() -> (Supervisor, Arc<Self>) {
        let sink = Arc::new(Self::default());
        (Supervisor::new(sink.clone()), sink)
    }

    pub(crate) fn reports(&self) -> Vec<FatalReport> {
        self.reports.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// The first fatal report, waited for at most 5 s.
    pub(crate) async fn first(&self) -> FatalReport {
        let wait = async {
            loop {
                let seen = self.seen.notified();
                if let Some(report) = self.reports().into_iter().next() {
                    return report;
                }
                seen.await;
            }
        };
        match tokio::time::timeout(Duration::from_secs(5), wait).await {
            Ok(report) => report,
            Err(_) => panic!("no fatal report within 5 s"),
        }
    }
}

#[tokio::test]
async fn a_fatal_task_that_panics_reaches_the_sink_under_its_name() {
    let (supervisor, sink) = Recorded::supervisor();
    task(&supervisor, "test.fatal", Fatal, ShutdownBehavior::Skip, async {
        panic!("injected");
    });
    let report = sink.first().await;
    assert_eq!(report.worker, "test.fatal");
    assert!(
        matches!(&report.reason, FatalReason::Failed(failure) if failure.to_string().contains("injected")),
        "{report}"
    );
}

#[tokio::test]
async fn a_fatal_task_that_ends_normally_reports_nothing() {
    let (supervisor, sink) = Recorded::supervisor();
    let (done_tx, done) = tokio::sync::oneshot::channel();
    task(&supervisor, "test.quiet", Fatal, ShutdownBehavior::Skip, async move {
        let _ = done_tx.send(());
    });
    done.await.expect("the task ran");
    tokio::task::yield_now().await;
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn a_task_started_after_shutdown_does_not_run() {
    let (supervisor, sink) = Recorded::supervisor();
    let report = supervisor.shutdown();
    assert!(report.late.is_empty());
    let (ran_tx, ran) = tokio::sync::oneshot::channel::<()>();
    task(&supervisor, "test.late", Fatal, ShutdownBehavior::Skip, async move {
        let _ = ran_tx.send(());
    });
    // The refused work was dropped unrun, and with it the sender.
    assert!(ran.await.is_err());
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn an_owned_fatal_thread_that_panics_reaches_the_sink_and_joins() {
    let (supervisor, sink) = Recorded::supervisor();
    let thread = owned_thread(
        &supervisor,
        "acpmux-test-thread",
        ThreadQos::Utility,
        Fatal,
        ShutdownBehavior::Continue,
        || panic!("injected"),
    )
    .expect("the thread starts");
    let report = sink.first().await;
    assert_eq!(report.worker, "acpmux-test-thread");
    // The body unwound: its owner's join returns.
    tokio::task::spawn_blocking(move || thread.join()).await.expect("joined");
}

#[tokio::test]
async fn an_owned_thread_joins_once_its_body_returns() {
    let (supervisor, sink) = Recorded::supervisor();
    let (go_tx, go) = std::sync::mpsc::sync_channel::<()>(1);
    let thread = owned_thread(
        &supervisor,
        "acpmux-test-owned",
        ThreadQos::Utility,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            let _ = go.recv();
        },
    )
    .expect("the thread starts");
    go_tx.send(()).expect("the thread waits");
    tokio::task::spawn_blocking(move || thread.join()).await.expect("joined");
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn a_blocking_task_that_panics_is_fatal_under_its_name() {
    let (supervisor, sink) = Recorded::supervisor();
    blocking(&supervisor, "test.blocking", Fatal, ShutdownBehavior::Continue, || {
        panic!("injected");
    });
    let report = sink.first().await;
    assert_eq!(report.worker, "test.blocking");
    assert!(report.to_string().contains("injected"), "{report}");
}

#[tokio::test]
async fn a_request_task_that_panics_answers_with_its_end() {
    let (ended_tx, ended) = tokio::sync::oneshot::channel();
    spawn_request(
        async {
            panic!("injected");
        },
        async move {
            let _ = ended_tx.send("internal error");
        },
    );
    let answer = tokio::time::timeout(Duration::from_secs(5), ended).await;
    assert_eq!(answer.ok().and_then(Result::ok), Some("internal error"));
}

#[tokio::test]
async fn a_request_task_that_ends_normally_skips_its_end() {
    let (done_tx, done) = tokio::sync::oneshot::channel();
    let (ended_tx, ended) = tokio::sync::oneshot::channel::<()>();
    spawn_request(
        async move {
            let _ = done_tx.send(());
        },
        async move {
            let _ = ended_tx.send(());
        },
    );
    done.await.expect("the work ran");
    // The end was dropped unrun.
    assert!(ended.await.is_err());
}

#[tokio::test]
async fn a_call_that_panics_is_fatal_and_its_caller_returns() {
    let (supervisor, sink) = Recorded::supervisor();
    let called = call(
        &supervisor,
        "test.call",
        Fatal,
        ShutdownBehavior::Skip,
        Box::pin(async {
            panic!("injected");
        }),
    );
    let returned = tokio::time::timeout(Duration::from_secs(5), called).await;
    assert!(matches!(returned, Ok(Ok(()))), "the caller's wait ends");
    let report = sink.first().await;
    assert_eq!(report.worker, "test.call");
    assert!(report.to_string().contains("injected"), "{report}");
}

#[tokio::test]
async fn a_call_returns_once_its_work_ends() {
    let (supervisor, sink) = Recorded::supervisor();
    let (done_tx, mut done) = tokio::sync::oneshot::channel();
    let called = call(
        &supervisor,
        "test.call-ok",
        Fatal,
        ShutdownBehavior::Skip,
        Box::pin(async move {
            let _ = done_tx.send(());
        }),
    );
    assert!(matches!(tokio::time::timeout(Duration::from_secs(5), called).await, Ok(Ok(()))));
    assert!(done.try_recv().is_ok(), "the work ran before the call returned");
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn a_dropped_call_stops_its_work() {
    let (supervisor, sink) = Recorded::supervisor();
    let (held_tx, mut held) = tokio::sync::mpsc::channel::<()>(1);
    let (started_tx, started) = tokio::sync::oneshot::channel();
    let called = call(
        &supervisor,
        "test.call-dropped",
        Fatal,
        ShutdownBehavior::Skip,
        Box::pin(async move {
            let _held = held_tx;
            let _ = started_tx.send(());
            std::future::pending::<()>().await;
        }),
    );
    // The caller gives up once the work runs (a deadline would do the same).
    let raced = tokio::select! {
        _ = called => false,
        _ = started => true,
    };
    assert!(raced, "the work started while the call waited");
    // The stopped work dropped its captures.
    let closed = tokio::time::timeout(Duration::from_secs(5), held.recv()).await;
    assert!(matches!(closed, Ok(None)), "the work was stopped");
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn a_call_after_shutdown_is_refused() {
    let (supervisor, sink) = Recorded::supervisor();
    assert!(supervisor.shutdown().late.is_empty());
    let called =
        call(&supervisor, "test.call-late", Fatal, ShutdownBehavior::Skip, Box::pin(async {}))
            .await;
    assert!(matches!(called, Err(SuperviseError::ShuttingDown)), "{called:?}");
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn a_scoped_task_that_panics_closes_its_channels() {
    let (supervisor, sink) = Recorded::supervisor();
    let (tx, mut rx) = tokio::sync::mpsc::channel::<u32>(1);
    spawn_scoped(async move {
        let _ = tx.send(1).await;
        panic!("injected");
    });
    assert_eq!(rx.recv().await, Some(1));
    // The panic dropped the sender: the other side sees the scope end.
    let ended = tokio::time::timeout(Duration::from_secs(5), rx.recv()).await;
    assert!(matches!(ended, Ok(None)));
    // A scoped panic is not the process's: nothing reaches a supervisor.
    assert!(sink.reports().is_empty());
    assert!(supervisor.live_workers().is_empty());
}

#[tokio::test]
async fn a_supervised_thread_runs_registered_at_its_qos_and_leaves_no_row() {
    let (supervisor, sink) = Recorded::supervisor();
    let (row_tx, row) = std::sync::mpsc::sync_channel(1);
    let name = "acpmux-test-registered";
    let thread = owned_thread(
        &supervisor,
        name,
        ThreadQos::Utility,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            let seen = cmux_threads::snapshot()
                .into_iter()
                .find(|info| info.name == name)
                .map(|info| info.declared);
            let _ = row_tx.send(seen);
        },
    )
    .expect("the thread starts");
    let seen = tokio::task::spawn_blocking(move || row.recv()).await.expect("received");
    assert_eq!(seen, Ok(Some(ThreadQos::Utility)));
    tokio::task::spawn_blocking(move || thread.join()).await.expect("joined");
    assert!(cmux_threads::snapshot().iter().all(|info| info.name != name));
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn a_scoped_thread_that_panics_joins_with_its_error_and_drops_its_pipe() {
    let (tx, rx) = std::sync::mpsc::channel::<u32>();
    let thread = scoped_thread("acpmux-test-scoped", ThreadQos::Utility, move || {
        let _ = tx.send(1);
        panic!("injected");
    })
    .expect("the thread starts");
    let joined = tokio::task::spawn_blocking(move || thread.join()).await.expect("joined");
    assert!(joined.is_err(), "join carries the panic");
    assert_eq!(rx.recv().ok(), Some(1));
    assert!(rx.recv().is_err(), "the pipe end was dropped");
}
