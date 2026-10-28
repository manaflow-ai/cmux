use std::time::Duration;

use tokio::sync::Semaphore;

use super::*;

const SPEC: JobSpec =
    JobSpec { name: "test.job", period: Duration::from_secs(300), skippable_in_saver: true };

/// The adapter's job list, which also proves every message before it was handled.
async fn listed(adapter: &mpsc::UnboundedSender<Message>) -> Vec<&'static str> {
    let (reply, answer) = oneshot::channel();
    adapter.send(Message::Jobs(reply)).unwrap();
    answer.await.unwrap()
}

#[tokio::test]
async fn a_due_job_starts_and_never_overlaps_its_last_run() {
    let (adapter, inbox) = mpsc::unbounded_channel();
    tokio::spawn(adapt(inbox));
    let (started_tx, mut started) = mpsc::unbounded_channel();
    let (done_tx, mut done) = mpsc::unbounded_channel();
    let gate = Arc::new(Semaphore::new(0));
    let job_gate = gate.clone();
    let job: AsyncJob = Box::new(move || {
        let (started, done, gate) = (started_tx.clone(), done_tx.clone(), job_gate.clone());
        Box::pin(async move {
            let _ = started.send(());
            if let Ok(permit) = gate.acquire().await {
                permit.forget();
            }
            let _ = done.send(());
        })
    });
    adapter.send(Message::Add { slot: 0, spec: SPEC, job }).unwrap();

    adapter.send(Message::Due(0)).unwrap();
    started.recv().await.unwrap();
    // Due again while the first run waits: no second run.
    adapter.send(Message::Due(0)).unwrap();
    assert_eq!(listed(&adapter).await, vec![SPEC.name]);
    assert!(started.try_recv().is_err(), "a run overlapped the one before");

    gate.add_permits(1);
    done.recv().await.unwrap();
    adapter.send(Message::Due(0)).unwrap();
    started.recv().await.unwrap();
    gate.add_permits(1);
    done.recv().await.unwrap();
}

#[tokio::test]
async fn a_removed_or_unknown_slot_runs_nothing() {
    let (adapter, inbox) = mpsc::unbounded_channel();
    tokio::spawn(adapt(inbox));
    let (ran_tx, mut ran) = mpsc::unbounded_channel();
    let job: AsyncJob = Box::new(move || {
        let ran = ran_tx.clone();
        Box::pin(async move {
            let _ = ran.send(());
        })
    });
    adapter.send(Message::Add { slot: 3, spec: SPEC, job }).unwrap();
    adapter.send(Message::Remove(3)).unwrap();
    adapter.send(Message::Due(3)).unwrap();
    adapter.send(Message::Due(7)).unwrap();
    assert!(listed(&adapter).await.is_empty());
    assert!(ran.try_recv().is_err());
}

#[tokio::test]
async fn jobs_register_only_on_a_started_clock() {
    let maintenance = Maintenance::default();
    assert!(matches!(maintenance.register(SPEC, || async {}), Err(MaintenanceError::NotStarted)));
    assert!(maintenance.jobs().await.is_empty());

    maintenance.start(0, &crate::supervised::embedded()).unwrap();
    maintenance.start(0, &crate::supervised::embedded()).unwrap();
    let owner = Arc::new(());
    let other = JobSpec { name: "test.other", skippable_in_saver: false, ..SPEC };
    maintenance.register(SPEC, || async {}).unwrap();
    maintenance.register_for(other, &owner, Start::OnGrid, |_owner| async {}).unwrap();
    assert_eq!(maintenance.jobs().await, vec!["test.job", "test.other"]);
}

#[tokio::test]
async fn a_job_registered_to_start_now_runs_at_once_through_the_adapter() {
    let maintenance = Maintenance::default();
    maintenance.start(0, &crate::supervised::embedded()).unwrap();
    let (ran_tx, mut ran) = mpsc::unbounded_channel::<()>();
    let owner = Arc::new(ran_tx);
    maintenance
        .register_for(SPEC, &owner, Start::Now, |owner| async move {
            let _ = owner.send(());
        })
        .unwrap();
    ran.recv().await.unwrap();
    // The job holds its owner only during a run.
    assert_eq!(Arc::strong_count(&owner), 1);
}

#[test]
fn energy_saver_flips_once_per_edge() {
    let maintenance = Maintenance::default();
    assert!(!maintenance.energy().is_saver());
    assert!(maintenance.energy().set_saver(true));
    assert!(!maintenance.energy().set_saver(true));
    assert!(maintenance.energy().is_saver());
}

#[test]
fn the_install_phase_is_kept_across_starts() {
    let home = std::env::temp_dir().join(format!("acpmux-phase-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&home).unwrap();
    let path = home.join(PHASE_FILE);
    let first = install_phase(&path);
    assert_eq!(install_phase(&path), first, "the second start reads the same phase");
    assert_eq!(std::fs::read_to_string(&path).unwrap().trim(), first.to_string());

    std::fs::write(&path, "not a number").unwrap();
    let replaced = install_phase(&path);
    assert_eq!(install_phase(&path), replaced, "a bad file is replaced once");

    // No file can be written: still a phase, for this process only.
    let _ = install_phase(&home.join("missing").join(PHASE_FILE));
    let _ = std::fs::remove_dir_all(&home);
}
