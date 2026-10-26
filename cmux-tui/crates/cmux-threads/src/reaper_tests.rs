//! The reaper: many children end with their own statuses on one thread, a
//! child that ended before its watch is still reaped, `watch_exited` hands
//! over an unreaped zombie, an idle reaper never wakes, and a dropped
//! reaper's thread ends.

use std::os::unix::process::ExitStatusExt;
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use super::*;
use crate::work::WorkConfig;

const WAIT: Duration = Duration::from_secs(20);

fn reaper(label: &str) -> Reaper {
    let work = Work::new(WorkConfig { label: format!("{label}w"), ..WorkConfig::default() })
        .expect("work lanes");
    Reaper::new(label, Arc::new(work)).expect("the reaper starts")
}

/// A child of this process that runs `script` in `sh`. The std handle is
/// dropped: the reaper waits by pid.
fn child(script: &str) -> u32 {
    Command::new("/bin/sh")
        .args(["-c", script])
        .stdin(Stdio::null())
        .spawn()
        .expect("sh starts")
        .id()
}

/// Live threads of this process with this exact name.
fn threads_named(name: &str) -> usize {
    crate::registry::snapshot().iter().filter(|thread| thread.name == name).count()
}

/// Waits until `count` live threads are named `name` (a thread registers
/// itself once it runs).
fn until_threads(name: &str, count: usize) {
    let deadline = Instant::now() + WAIT;
    let (_never, tick) = channel::<()>();
    while threads_named(name) != count {
        assert!(
            Instant::now() < deadline,
            "{} threads named {name}, not {count}",
            threads_named(name)
        );
        let _ = tick.recv_timeout(Duration::from_millis(10));
    }
}

/// Waits until `pid` is a zombie, without reaping it.
fn until_zombie(pid: u32) {
    assert!(wait_zombie(pid as libc::pid_t), "child {pid} is not waitable");
}

fn exited(received: &Receiver<(u32, io::Result<ExitStatus>)>) -> (u32, ExitStatus) {
    let (pid, status) = received.recv_timeout(WAIT).expect("an exit within the wait");
    (pid, status.expect("a reaped status"))
}

/// Nothing arrives on `received` for `within`.
fn quiet<T>(received: &Receiver<T>, within: Duration) -> bool {
    matches!(received.recv_timeout(within), Err(RecvTimeoutError::Timeout))
}

#[test]
fn fifty_children_end_with_their_statuses_on_one_thread() {
    let reaper = reaper("rp50");
    let (sender, received) = channel();
    let mut expected = HashMap::new();
    for code in 0..50 {
        // Every child runs a moment, so most watches are in place before
        // their exits.
        let pid = child(&format!("sleep 0.2; exit {code}"));
        expected.insert(pid, code);
        let sender = sender.clone();
        reaper.watch(pid, Box::new(move |status| drop(sender.send((pid, status)))));
    }
    until_threads("rp50-reaper", 1);
    assert_eq!(threads_named("rp50-reap-wait"), 0, "no thread per child");
    let mut seen = HashMap::new();
    for _ in 0..50 {
        let (pid, status) = exited(&received);
        seen.insert(pid, status.code().expect("an exit code"));
    }
    assert_eq!(seen, expected);
    let stats = reaper.stats();
    assert_eq!((stats.watching, stats.exits, stats.fallback_threads), (0, 50, 0));
    assert!(stats.wakeups <= 50, "{} wakeups for 50 exits", stats.wakeups);
}

#[test]
fn a_killed_child_reports_its_signal() {
    let reaper = reaper("rpsig");
    let (sender, received) = channel();
    let pid = child("exec sleep 30");
    reaper.watch(pid, Box::new(move |status| drop(sender.send((pid, status)))));
    // SAFETY: kill(2) takes no pointers; `pid` is an unreaped child.
    assert_eq!(unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) }, 0);
    let (reaped, status) = exited(&received);
    assert_eq!((reaped, status.signal()), (pid, Some(libc::SIGKILL)));
}

#[test]
fn a_child_that_ended_before_its_watch_is_reaped() {
    let reaper = reaper("rpzmb");
    let (sender, received) = channel();
    let pid = child("exit 7");
    until_zombie(pid);
    reaper.watch(pid, Box::new(move |status| drop(sender.send((pid, status)))));
    let (_, status) = exited(&received);
    assert_eq!(status.code(), Some(7));
    // The status was taken: the pid is no longer a child to wait for.
    assert!(waitpid(pid as libc::pid_t, libc::WNOHANG).is_err(), "reaped twice");
}

#[test]
fn watch_exited_hands_over_an_unreaped_zombie() {
    let reaper = reaper("rpexd");
    let (sender, received) = channel();
    let pid = child("exit 3");
    reaper.watch_exited(
        pid,
        Box::new(move |zombie| {
            // The pid is still taken: a WNOHANG wait finds its status now.
            let status = waitpid(pid as libc::pid_t, libc::WNOHANG);
            let code = status.ok().flatten().and_then(|status| status.code());
            let _ = sender.send((zombie, code));
        }),
    );
    let (zombie, code) = received.recv_timeout(WAIT).expect("the exit");
    assert_eq!((zombie, code), (true, Some(3)));
}

#[test]
fn a_pid_that_is_not_a_child_fails_its_completion() {
    let reaper = reaper("rpnot");
    let (sender, received) = channel();
    // Pid 1 is never a child of the test process.
    reaper.watch(1, Box::new(move |status| drop(sender.send((1, status)))));
    let (_, status) = received.recv_timeout(WAIT).expect("a completion");
    assert!(status.is_err(), "init reaped by a test: {status:?}");
}

#[test]
fn an_idle_reaper_never_wakes() {
    let reaper = reaper("rpidle");
    let (sender, received) = channel();
    let pid = child("exit 0");
    reaper.watch(pid, Box::new(move |status| drop(sender.send((pid, status)))));
    exited(&received);
    let woke = reaper.stats().wakeups;
    let (_never, idle) = channel::<()>();
    assert!(quiet(&idle, Duration::from_millis(500)));
    assert_eq!(reaper.stats().wakeups, woke, "the idle reaper woke");
    // A watched child that keeps running does not wake it either.
    let pid = child("exec sleep 30");
    let (sender, received) = channel();
    reaper.watch(pid, Box::new(move |status| drop(sender.send((pid, status)))));
    assert!(quiet(&received, Duration::from_millis(500)));
    assert_eq!(reaper.stats().wakeups, woke, "a running child woke the reaper");
    // SAFETY: kill(2) takes no pointers; `pid` is an unreaped child.
    unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    exited(&received);
}

#[test]
fn a_dropped_reaper_ends_its_thread() {
    let reaper = reaper("rpdrop");
    until_threads("rpdrop-reaper", 1);
    drop(reaper);
    until_threads("rpdrop-reaper", 0);
}
