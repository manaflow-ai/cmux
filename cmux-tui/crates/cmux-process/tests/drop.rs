//! A dropped `cmux_process::Child` that still runs ends, with what it
//! started, and is reaped; a detached one outlives its handle; the drop
//! never blocks.

#![cfg(unix)]

use cmux_process::{Command, Stdio};
use std::io::{BufRead, BufReader};
use std::time::{Duration, Instant};

/// How long a dropped child and its group may take to be gone: the SIGTERM
/// grace and a margin for a loaded machine.
const GONE_WITHIN: Duration = Duration::from_secs(2);

/// The drop's own cap: it sends one signal and starts a thread.
const DROP_CAP: Duration = Duration::from_millis(100);

/// `pid` names a process that runs (not one that is gone or a zombie).
fn alive(pid: libc::pid_t) -> bool {
    // SAFETY: signal 0 only checks that the pid exists.
    if unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    if let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        // `pid (comm) S ...`: the state follows the last `)`.
        let state = stat.rsplit_once(')').map(|(_, rest)| rest.trim_start());
        if state.is_some_and(|rest| rest.starts_with('Z') || rest.starts_with('X')) {
            return false;
        }
    }
    true
}

/// Wait (by short sleeps: these are other processes' ends, with no event to
/// wait on) until every pid is gone, or `limit` passes. The pids still alive.
fn gone_within(pids: &[libc::pid_t], limit: Duration) -> Vec<libc::pid_t> {
    let deadline = Instant::now() + limit;
    loop {
        let left: Vec<_> = pids.iter().copied().filter(|&pid| alive(pid)).collect();
        if left.is_empty() || Instant::now() >= deadline {
            return left;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// This process has a controlling terminal (the tests ran from a shell).
fn has_a_terminal() -> bool {
    std::fs::File::open("/dev/tty").is_ok()
}

/// A `sh -c SCRIPT` child leading its own group (as a daemon's children do by
/// default) whose first stdout line is read: the pid the script printed.
fn shell_printing_a_pid(script: &str) -> (cmux_process::Child, libc::pid_t) {
    let mut child = Command::new("/bin/sh")
        .args(["-c", script])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
    (child, line.trim().parse().unwrap())
}

#[test]
fn a_child_leads_its_own_group_unless_this_process_has_a_terminal() {
    let mut child = Command::new("/bin/sleep")
        .arg("300")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let pid = child.id() as libc::pid_t;
    // SAFETY: getpgid reads a child of this process.
    let leads = unsafe { libc::getpgid(pid) } == pid;
    assert_eq!(leads, !has_a_terminal());
    assert_eq!(child.leads_group(), leads);
    child.kill().unwrap();
    child.wait().unwrap();
}

#[test]
fn a_dropped_child_and_the_process_it_started_are_gone() {
    let (child, grandchild) = shell_printing_a_pid("sleep 300 & echo $!; sleep 300");
    let pid = child.id() as libc::pid_t;
    assert!(child.leads_group());
    // SAFETY: getpgid reads a child of this process.
    assert_eq!(unsafe { libc::getpgid(pid) }, pid);
    assert!(alive(pid) && alive(grandchild));

    let started = Instant::now();
    drop(child);
    assert!(started.elapsed() < DROP_CAP, "the drop blocked for {:?}", started.elapsed());
    assert_eq!(gone_within(&[pid, grandchild], GONE_WITHIN), Vec::<libc::pid_t>::new());
}

#[test]
fn a_dropped_child_that_ignores_sigterm_is_killed_after_the_grace_without_blocking_the_drop() {
    // The trap is inherited by the background sleep: the whole group ignores SIGTERM.
    let (child, grandchild) = shell_printing_a_pid("trap '' TERM; sleep 300 & echo $!; sleep 300");
    let pid = child.id() as libc::pid_t;

    let started = Instant::now();
    drop(child);
    assert!(started.elapsed() < DROP_CAP, "the drop blocked for {:?}", started.elapsed());
    // Still there inside the grace (SIGTERM is ignored), gone after it.
    assert!(alive(grandchild), "SIGKILL came before the grace");
    assert_eq!(gone_within(&[pid, grandchild], GONE_WITHIN), Vec::<libc::pid_t>::new());
    assert!(started.elapsed() >= cmux_process::DROP_GRACE, "gone before the grace ended");
}

#[test]
fn a_detached_child_outlives_its_handle() {
    let mut child = Command::new("/bin/sleep")
        .arg("300")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let pid = child.id() as libc::pid_t;
    child.detach("test: a child that outlives its handle");
    assert_eq!(child.detached(), Some("test: a child that outlives its handle"));
    drop(child);
    std::thread::sleep(cmux_process::DROP_GRACE + Duration::from_millis(300));
    assert!(alive(pid), "a detached child was ended at drop");

    // SAFETY: the test's own child, still unreaped: kill it and reap it.
    unsafe {
        assert_eq!(libc::kill(pid, libc::SIGKILL), 0);
        let mut status = 0;
        assert_eq!(libc::waitpid(pid, &mut status, 0), pid);
    }
}

#[test]
fn a_waited_child_is_not_signalled_at_drop() {
    let mut child = Command::new("/bin/sh")
        .args(["-c", "exit 7"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert_eq!(child.wait().unwrap().code(), Some(7));
    let started = Instant::now();
    drop(child);
    assert!(started.elapsed() < DROP_CAP);
}

#[test]
fn a_child_put_in_another_group_does_not_lead_one() {
    // SAFETY: getpgrp reads this process's group.
    let ours = unsafe { libc::getpgrp() };
    let child = Command::new("/bin/sleep")
        .arg("300")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(ours)
        .spawn()
        .unwrap();
    let pid = child.id() as libc::pid_t;
    assert!(!child.leads_group());
    // SAFETY: getpgid reads a child of this process.
    assert_eq!(unsafe { libc::getpgid(pid) }, ours);
    // Its drop signals the child alone (this test process is in that group too).
    drop(child);
    assert_eq!(gone_within(&[pid], GONE_WITHIN), Vec::<libc::pid_t>::new());
}
