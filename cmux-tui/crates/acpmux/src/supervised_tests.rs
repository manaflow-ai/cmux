//! Panic injection for each policy acpmux uses: a [`Fatal`] task or thread
//! reaches the process's failure sink under its name; a scoped task ends only
//! its own scope.

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
    let thread =
        owned_thread(&supervisor, "acpmux-test-thread", Fatal, ShutdownBehavior::Continue, || {
            panic!("injected")
        })
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
