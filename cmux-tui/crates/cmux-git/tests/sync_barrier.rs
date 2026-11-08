#![cfg(unix)]
use cmux_git::sync_barrier::{Probe, Sync, probe, wait_ready};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "cmux-sync-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path.canonicalize().unwrap())
    }
    fn repo(&self) -> PathBuf {
        self.0.join("repo")
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn writes_wait_until_sync_is_durable_and_hold_off_the_next_sync() {
    let scratch = Scratch::new();
    let repo = scratch.repo();
    let sync = Sync::begin(&repo).unwrap();
    assert!(matches!(probe(&repo.join("src/new.rs")).unwrap(), Probe::Syncing));
    std::fs::create_dir(&repo).unwrap();
    std::fs::write(repo.join("source"), "synced").unwrap();
    sync.complete().unwrap();
    let Probe::Ready(guard) = probe(&repo.join("src/new.rs")).unwrap() else { panic!("not ready") };
    assert!(Sync::begin(&repo).is_err(), "a write holds its lease through mutation");
    std::fs::write(repo.join("source"), "edited").unwrap();
    drop(guard);
    assert_eq!(std::fs::read_to_string(repo.join("source")).unwrap(), "edited");
    Sync::begin(&repo).unwrap().complete().unwrap();
}

#[test]
fn failed_sync_never_opens_the_barrier_and_retry_repairs_it() {
    let scratch = Scratch::new();
    let repo = scratch.repo();
    drop(Sync::begin(&repo).unwrap());
    assert!(matches!(probe(&repo).unwrap(), Probe::Incomplete));
    Sync::begin(&repo).unwrap().complete().unwrap();
    assert!(matches!(probe(&repo).unwrap(), Probe::Ready(_)));
}

#[test]
fn aliases_and_missing_descendants_share_the_same_barrier() {
    let scratch = Scratch::new();
    let repo = scratch.repo();
    std::fs::create_dir(&repo).unwrap();
    let alias = scratch.0.join("alias");
    std::os::unix::fs::symlink(&repo, &alias).unwrap();
    let sync = Sync::begin(&repo).unwrap();
    assert!(matches!(probe(&alias.join("new/file")).unwrap(), Probe::Syncing));
    sync.complete().unwrap();
    assert!(matches!(probe(&alias).unwrap(), Probe::Ready(_)));
}

#[test]
fn ordinary_local_repositories_are_ready_without_a_marker() {
    let scratch = Scratch::new();
    assert!(matches!(probe(&scratch.repo()).unwrap(), Probe::Ready(_)));
    assert_eq!(std::fs::read_dir(&scratch.0).unwrap().count(), 0);
}

#[test]
fn the_first_sync_cannot_overtake_a_reader_that_saw_no_marker() {
    let scratch = Scratch::new();
    let repo = scratch.repo();
    let Probe::Ready(ready) = probe(&repo).unwrap() else { panic!("not ready") };
    let (started, receiver) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        let sync = Sync::begin(&repo).unwrap();
        started.send(()).unwrap();
        sync.complete().unwrap();
    });
    assert!(receiver.recv_timeout(std::time::Duration::from_millis(50)).is_err());
    drop(ready);
    receiver.recv_timeout(std::time::Duration::from_secs(2)).unwrap();
    worker.join().unwrap();
}

#[test]
fn a_reader_never_blocks_a_sibling_repository_sync() {
    let scratch = Scratch::new();
    let Probe::Ready(_ready) = probe(&scratch.repo()).unwrap() else { panic!("not ready") };
    let sibling = scratch.0.join("independent-repo");
    Sync::begin(&sibling).unwrap().complete().unwrap();
    assert!(matches!(probe(&sibling).unwrap(), Probe::Ready(_)));
}

#[test]
fn pre_tool_wait_releases_only_after_sync_completes() {
    let scratch = Scratch::new();
    let repo = scratch.repo();
    let sync = Sync::begin(&repo).unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    let waiter = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        wait_ready(&repo, std::time::Duration::from_secs(2)).unwrap();
        finished_tx.send(()).unwrap();
    });
    started_rx.recv_timeout(std::time::Duration::from_secs(1)).unwrap();
    assert!(finished_rx.recv_timeout(std::time::Duration::from_millis(50)).is_err());
    sync.complete().unwrap();
    finished_rx.recv_timeout(std::time::Duration::from_secs(1)).unwrap();
    waiter.join().unwrap();
}

/// Same deterministic overlap schedule, with and without waiting. This measures
/// edit retention, not end-to-end Cloud latency (which belongs to the probes).
#[test]
fn sync_race_retention_measurement() {
    let scratch = Scratch::new();
    let repo = scratch.repo();
    std::fs::create_dir(&repo).unwrap();
    let file = repo.join("source");
    let mut retained = [0, 0];
    for gated in [false, true] {
        for _ in 0..100 {
            let sync = Sync::begin(&repo).unwrap();
            if !gated {
                std::fs::write(&file, "agent edit").unwrap();
            } else {
                assert!(matches!(probe(&file).unwrap(), Probe::Syncing));
            }
            std::fs::write(&file, "repo sync").unwrap();
            sync.complete().unwrap();
            if gated {
                let Probe::Ready(_guard) = probe(&file).unwrap() else { panic!("not ready") };
                std::fs::write(&file, "agent edit").unwrap();
            }
            retained[usize::from(gated)] +=
                usize::from(std::fs::read_to_string(&file).unwrap() == "agent edit");
        }
    }
    println!("sync_race_retention: before={}/100 after={}/100", retained[0], retained[1]);
    assert_eq!(retained, [0, 100]);
}
