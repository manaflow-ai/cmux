use super::*;
use std::sync::mpsc;
use std::time::Duration;

fn sleeper() -> std::process::Child {
    std::process::Command::new("sleep").arg("600").spawn().expect("sleep")
}

fn signal(child: &std::process::Child, sig: libc::c_int) {
    // SAFETY: a signal to this test's own child.
    assert_eq!(unsafe { libc::kill(child.id() as libc::pid_t, sig) }, 0);
}

#[test]
fn a_killed_process_fires_its_watch_within_seconds() {
    let mut child = sleeper();
    let pid = child.id();
    let start = crate::owner_exit::process_start(pid);
    assert!(start.is_some());
    let (tx, rx) = mpsc::channel();
    watch(pid, start, move || tx.send(()).unwrap()).unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "fired while it ran");
    let killed = std::time::Instant::now();
    child.kill().unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("the exit was heard");
    assert!(killed.elapsed() < Duration::from_secs(5));
    child.wait().unwrap();
    assert!(!armed(pid));
}

#[test]
fn a_stopped_process_does_not_fire() {
    let mut child = sleeper();
    let pid = child.id();
    let (tx, rx) = mpsc::channel();
    watch(pid, crate::owner_exit::process_start(pid), move || tx.send(()).unwrap()).unwrap();
    signal(&child, libc::SIGSTOP);
    assert!(rx.recv_timeout(Duration::from_secs(1)).is_err(), "a stop read as an exit");
    signal(&child, libc::SIGCONT);
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "a continue read as an exit");
    child.kill().unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("the exit was heard");
    child.wait().unwrap();
}

#[test]
fn another_process_under_the_pid_fires_only_its_stale_watch() {
    let mut child = sleeper();
    let pid = child.id();
    let start = crate::owner_exit::process_start(pid).unwrap();
    // A caller that saw an earlier process under this pid: that one is gone.
    let (stale_tx, stale_rx) = mpsc::channel();
    watch(pid, Some(start.wrapping_sub(1)), move || stale_tx.send(()).unwrap()).unwrap();
    stale_rx.recv_timeout(Duration::from_secs(1)).expect("the stale watch fired at once");
    // The running process's own watch is untouched, armed before or after.
    let (tx, rx) = mpsc::channel();
    watch(pid, Some(start), move || tx.send(()).unwrap()).unwrap();
    let (late_tx, late_rx) = mpsc::channel();
    watch(pid, Some(start.wrapping_add(1)), move || late_tx.send(()).unwrap()).unwrap();
    late_rx.recv_timeout(Duration::from_secs(1)).expect("the other start fired at once");
    assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "the live process fired");
    child.kill().unwrap();
    rx.recv_timeout(Duration::from_secs(5)).expect("the exit was heard");
    child.wait().unwrap();
}

#[test]
fn a_gone_process_fires_at_once() {
    let mut child = sleeper();
    let pid = child.id();
    let start = crate::owner_exit::process_start(pid);
    child.kill().unwrap();
    child.wait().unwrap();
    let (tx, rx) = mpsc::channel();
    watch(pid, start, move || tx.send(()).unwrap()).unwrap();
    rx.recv_timeout(Duration::from_secs(1)).expect("fired at once");
}

#[test]
fn many_watches_share_one_thread() {
    let mut children: Vec<_> = (0..16).map(|_| sleeper()).collect();
    let (tx, rx) = mpsc::channel();
    for child in &children {
        let (tx, pid) = (tx.clone(), child.id());
        watch(pid, crate::owner_exit::process_start(pid), move || tx.send(pid).unwrap()).unwrap();
    }
    let threads = || {
        std::fs::read_dir("/proc/self/task")
            .map(|d| {
                d.flatten()
                    .filter(|t| {
                        std::fs::read_to_string(t.path().join("comm"))
                            .is_ok_and(|c| c.trim() == "acpmux-proc-exi")
                    })
                    .count()
            })
            .ok()
    };
    if let Some(n) = threads() {
        assert_eq!(n, 1, "one watcher thread for every watch");
    }
    for child in &mut children {
        child.kill().unwrap();
    }
    let mut heard: Vec<u32> =
        (0..16).map(|_| rx.recv_timeout(Duration::from_secs(5)).expect("each exit")).collect();
    heard.sort_unstable();
    let mut pids: Vec<u32> = children.iter().map(std::process::Child::id).collect();
    pids.sort_unstable();
    assert_eq!(heard, pids);
    for child in &mut children {
        child.wait().unwrap();
    }
}
