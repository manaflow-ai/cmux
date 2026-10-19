use super::*;
use std::sync::Mutex;
use std::time::Duration;

struct LatePull {
    started: Sender<()>,
    release: Mutex<Receiver<()>>,
}

impl Transfer for LatePull {
    fn run(&self, job: &TransferJob, _cancel: &Cancel) -> Result<u64, TransferError> {
        self.started.send(()).unwrap();
        self.release.lock().unwrap().recv().unwrap();
        // A copy can finish its last write after the loop has signalled cancellation.
        std::fs::write(&job.local, b"late partial data").unwrap();
        Err(TransferError { message: "stopped".into(), retryable: false })
    }
}

#[test]
fn cloud_scope_a_late_cancelled_pull_cleans_its_landing_after_its_worker_returns() {
    let mut random = [0u8; 8];
    getrandom::fill(&mut random).unwrap();
    let root = std::env::temp_dir().join(format!(
        "cmux-scope-pull-{}-{}",
        std::process::id(),
        u64::from_ne_bytes(random)
    ));
    std::fs::create_dir(&root).unwrap();
    let landing = root.join(".landing");
    let target = root.join("target");
    let (started, ready) = channel();
    let (release, held) = channel();
    let worker = Arc::new(LatePull { started, release: Mutex::new(held) });
    let cancel = Cancel::default();
    let mut transfers = Transfers::new();
    let job = TransferJob {
        machine: "vm-alpha01".into(),
        direction: Direction::Pull,
        local: landing.clone(),
        guest: "/notes".into(),
        target: super::super::link_files::DialTarget {
            binary: "unused".into(),
            host: "unused".into(),
            socket: "unused".into(),
            env: vec![],
        },
    };
    transfers
        .start(
            worker,
            job,
            Running {
                machine: "vm-alpha01".into(),
                direction: Direction::Pull,
                guest: "/notes".into(),
                local: target.clone(),
                landing: landing.clone(),
                cancel: cancel.clone(),
                started_at: 0,
            },
        )
        .unwrap();
    ready.recv_timeout(Duration::from_secs(2)).unwrap();
    transfers.forget_scope();
    assert!(cancel.is_cancelled());
    release.send(()).unwrap();
    // The completion is sent after the worker's final cleanup, with no later op or polling.
    let _ = transfers.receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    assert!(!target.exists(), "old scope data is never published");
    assert!(!landing.exists(), "a late write must not leave a partial file behind");
    assert!(transfers.list().is_empty(), "old scope history is not restored");
    std::fs::remove_dir_all(root).unwrap();
}
