//! The hub's tasks run under the supervisor it was built with: its long-lived
//! watchers are registered there, and a panic in a hub task reaches that
//! supervisor's sink as `Fatal` under the task's name.

use super::*;
use crate::supervised::tests::Recorded;

fn hub(supervisor: Supervisor) -> Arc<Hub> {
    Hub::in_memory(supervisor)
}

#[tokio::test]
async fn the_hubs_long_lived_tasks_run_under_its_supervisor() {
    let (supervisor, sink) = Recorded::supervisor();
    let hub = hub(supervisor);
    let live = hub.supervisor().live_workers();
    for worker in ["hub.peer-notices", "hub.title-watch", "hub.orphan-watch"] {
        assert!(live.iter().any(|w| w == worker), "{worker} not supervised: {live:?}");
    }
    assert!(sink.reports().is_empty());
}

#[tokio::test]
async fn a_hub_task_that_panics_is_fatal_under_its_name() {
    let (supervisor, sink) = Recorded::supervisor();
    let hub = hub(supervisor);
    hub.supervise("hub.test-panic", Fatal, ShutdownBehavior::Skip, async {
        panic!("injected");
    });
    let report = sink.first().await;
    assert_eq!(report.worker, "hub.test-panic");
}

#[tokio::test]
async fn shutdown_stops_the_hubs_skip_tasks() {
    let (supervisor, sink) = Recorded::supervisor();
    let hub = hub(supervisor);
    let report = hub.supervisor().shutdown();
    assert!(report.late.is_empty(), "{report:?}");
    // Aborted at their next await, they leave the registry.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while hub.supervisor().live_workers().iter().any(|w| w.starts_with("hub.")) {
        assert!(tokio::time::Instant::now() < deadline, "{:?}", hub.supervisor().live_workers());
        tokio::task::yield_now().await;
    }
    assert!(sink.reports().is_empty());
}
