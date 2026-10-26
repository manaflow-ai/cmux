//! A child process that records into its metrics file and is SIGKILLed leaves its samples on disk, and a
//! reader folds each of them once (p09-observability task 131). The child is this test binary, run again with
//! `CMUX_METRICS_KILL_CHILD_DIR` set.
#![cfg(unix)]

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};

use cmux_trace::Role;
use cmux_trace::metrics::{
    Header, HistogramSpec, Layout, MetricsFile, MetricsStore, Profile, file_name,
};

const CHILD_DIR: &str = "CMUX_METRICS_KILL_CHILD_DIR";
const READY: &str = "metrics-child-ready";
const CATALOG: &[HistogramSpec] = &[
    HistogramSpec {
        name: "daemon.request.query",
        layout: Layout::LogLinear { maximum: 60_000_000 },
    },
    HistogramSpec {
        name: "daemon.dispatch.queue_us",
        layout: Layout::LogLinear { maximum: 60_000_000 },
    },
];

/// The child: adopts its file, records, says it is ready (after the harness's `test <name> ... ` on the same
/// line) and waits to be killed. A no-op in the parent run.
#[test]
fn metrics_kill_child_records_then_waits() {
    let Some(dir) = std::env::var_os(CHILD_DIR) else { return };
    let store = MetricsStore::new(CATALOG, Header::current(Role::Holder, Profile::current("test")));
    store.record(0, 10);
    store.adopt_file(std::path::Path::new(&dir)).expect("adopts the file");
    for sample in [20, 30, 40_000] {
        store.record(0, sample);
    }
    store.record(1, 5);
    println!("{READY}");
    loop {
        std::thread::park();
    }
}

#[test]
fn metrics_a_sigkilled_childs_file_folds_once() {
    if std::env::var_os(CHILD_DIR).is_some() {
        return;
    }
    let dir = std::env::temp_dir().join(format!("cmux-metrics-kill-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let mut child = Command::new(std::env::current_exe().expect("the test binary"))
        .args([
            "--exact",
            "metrics_kill_child_records_then_waits",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD_DIR, &dir)
        .stdout(Stdio::piped())
        .spawn()
        .expect("starts the child");
    let stdout = child.stdout.take().expect("piped");
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let ready = BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
            .any(|line| line.trim_end().ends_with(READY));
        let _ = ready_tx.send(ready);
    });
    let ready = ready_rx.recv_timeout(std::time::Duration::from_secs(30)).unwrap_or(false);
    let pid = child.id();
    if !ready {
        let _ = child.kill();
        let _ = child.wait();
        panic!("the child never became ready");
    }
    // SAFETY: a signal to our own child, which is still alive (not yet waited for).
    assert_eq!(unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) }, 0);
    let status = child.wait().expect("reaps the child");
    assert!(!status.success(), "the child was killed");

    let path = dir.join(file_name(Role::Holder, pid));
    let file = MetricsFile::open(&path).expect("the killed child's file maps");
    assert_eq!(file.header().pid, pid);
    assert_eq!(file.header().role, Role::Holder);
    let delta = file.fold();
    let query = delta.histogram("daemon.request.query").expect("the child's samples survived");
    assert_eq!((query.count, query.sum), (4, 10 + 20 + 30 + 40_000));
    let dispatch = delta.histogram("daemon.dispatch.queue_us").expect("recorded after adoption");
    assert_eq!((dispatch.count, dispatch.sum), (1, 5));
    assert!(file.fold().is_empty(), "the same mapping folds nothing twice");
    drop(file);
    let reopened = MetricsFile::open(&path).expect("maps again");
    assert!(reopened.fold().is_empty(), "a later reader folds nothing twice");
    let _ = std::fs::remove_dir_all(&dir);
}
