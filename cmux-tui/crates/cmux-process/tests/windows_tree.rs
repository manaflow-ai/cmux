//! Windows: a child that leads its own group runs in a job with what it
//! starts, so a drop or a kill ends its whole tree, as a group signal does
//! on Unix; a detached one's tree outlives the handle. An owned child
//! (`spawn_owned`) and its tree end with the process that owns it, however
//! that process ends.
//!
//! The tree is this test binary: the child re-runs it as `tree_helper` in
//! the parent role, which starts a grandchild (plain std, so it joins the
//! job) in the sleeper role and prints its pid.

#![cfg(windows)]

use std::io::{BufRead, BufReader, Write};
use std::time::Duration;

use cmux_process::{Command, Stdio};
use windows_sys::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
use windows_sys::Win32::System::Threading::{
    OpenProcess, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE, TerminateProcess, WaitForSingleObject,
};

const ROLE: &str = "CMUX_PROCESS_TREE_ROLE";
/// How long a helper sleeps: far past any assertion here.
const HELPER_LIFE: Duration = Duration::from_secs(120);
/// How long an ended tree may take to be gone on a loaded runner.
const GONE_WITHIN: Duration = Duration::from_secs(10);

fn helper_args() -> [&'static str; 5] {
    ["--exact", "tree_helper", "--ignored", "--nocapture", "--test-threads=1"]
}

#[test]
#[ignore = "a helper the tree tests start"]
fn tree_helper() {
    match std::env::var(ROLE).as_deref() {
        Ok("parent") => {
            // The grandchild is never waited on: the job (or the test) ends it.
            #[allow(clippy::zombie_processes)]
            let grandchild = std::process::Command::new(std::env::current_exe().unwrap())
                .args(helper_args())
                .env(ROLE, "sleeper")
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap();
            let mut out = std::io::stdout();
            writeln!(out, "grandchild {}", grandchild.id()).unwrap();
            out.flush().unwrap();
            std::thread::sleep(HELPER_LIFE);
        }
        Ok("sleeper") => std::thread::sleep(HELPER_LIFE),
        Ok("owner") => {
            // Owns a parent-role tree, passes on its grandchild's pid, then
            // ends without running a destructor: only the kernel closing
            // this process's handles can end the tree.
            let (owned, grandchild) = owned_tree();
            let mut out = std::io::stdout();
            writeln!(out, "grandchild {grandchild}").unwrap();
            writeln!(out, "owned {}", owned.id()).unwrap();
            out.flush().unwrap();
            std::mem::forget(owned);
            std::process::exit(0);
        }
        _ => {}
    }
}

/// A helper in the parent role, leading its own group, and the pid of the
/// grandchild it started.
fn tree(detached: bool) -> (cmux_process::Child, u32) {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(helper_args())
        .env(ROLE, "parent")
        .new_session()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    if detached {
        child.detach("the test checks that a detached tree outlives its handle");
    }
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let pid = loop {
        let line = lines.next().expect("the helper printed its grandchild").unwrap();
        if let Some(pid) = line.strip_prefix("grandchild ") {
            break pid.trim().parse().unwrap();
        }
    };
    (child, pid)
}

/// A helper in the parent role started with `spawn_owned`, and its grandchild.
fn owned_tree() -> (cmux_process::OwnedChild, u32) {
    let mut owned = Command::new(std::env::current_exe().unwrap())
        .args(helper_args())
        .env(ROLE, "parent")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn_owned()
        .unwrap();
    let pid = read_pid(owned.stdout.take().unwrap(), "grandchild ");
    (owned, pid)
}

fn read_pid(out: impl std::io::Read, prefix: &str) -> u32 {
    let mut lines = BufReader::new(out).lines();
    loop {
        let line = lines.next().expect("the helper printed a pid").unwrap();
        if let Some(pid) = line.strip_prefix(prefix) {
            return pid.trim().parse().unwrap();
        }
    }
}

/// Whether `pid` ends within `limit` (a pid that no longer opens has ended).
fn ends_within(pid: u32, limit: Duration) -> bool {
    // SAFETY: a plain open; the handle is closed below.
    let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
    if process.is_null() {
        return true;
    }
    let millis = u32::try_from(limit.as_millis()).unwrap_or(u32::MAX);
    // SAFETY: the handle just opened.
    let ended = unsafe { WaitForSingleObject(process, millis) } == WAIT_OBJECT_0;
    // SAFETY: as above, closed once.
    unsafe { CloseHandle(process) };
    ended
}

fn terminate(pid: u32) {
    // SAFETY: a plain open; the handle is closed below.
    let process = unsafe { OpenProcess(PROCESS_TERMINATE, 0, pid) };
    if !process.is_null() {
        // SAFETY: the handle just opened.
        unsafe {
            TerminateProcess(process, 1);
            CloseHandle(process);
        }
    }
}

#[test]
fn a_dropped_group_leader_ends_what_it_started() {
    let (child, grandchild) = tree(false);
    drop(child);
    let ended = ends_within(grandchild, GONE_WITHIN);
    terminate(grandchild);
    assert!(ended, "the grandchild {grandchild} outlived its dropped group leader");
}

#[test]
fn killing_a_group_leader_ends_what_it_started() {
    let (mut child, grandchild) = tree(false);
    child.kill().unwrap();
    child.wait().unwrap();
    let ended = ends_within(grandchild, GONE_WITHIN);
    terminate(grandchild);
    assert!(ended, "the grandchild {grandchild} outlived its killed group leader");
}

#[test]
fn a_detached_group_leaders_tree_outlives_its_handle() {
    let (child, grandchild) = tree(true);
    let leader = child.id();
    drop(child);
    let ended = ends_within(grandchild, Duration::from_secs(2));
    terminate(grandchild);
    terminate(leader);
    assert!(!ended, "the detached tree's grandchild {grandchild} ended with the handle");
}

#[test]
fn a_dropped_owned_child_ends_what_it_started() {
    let (owned, grandchild) = owned_tree();
    drop(owned);
    let ended = ends_within(grandchild, GONE_WITHIN);
    terminate(grandchild);
    assert!(ended, "the grandchild {grandchild} outlived its dropped owned child");
}

#[test]
fn an_owned_tree_ends_with_the_process_that_owns_it() {
    let mut owner = std::process::Command::new(std::env::current_exe().unwrap())
        .args(helper_args())
        .env(ROLE, "owner")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let mut lines = BufReader::new(owner.stdout.take().unwrap()).lines();
    // Its test harness prints lines of its own: skip to each one asked for.
    let mut pid = |prefix: &str| -> u32 {
        loop {
            let line = lines.next().expect("the owner printed its tree").unwrap();
            if let Some(pid) = line.strip_prefix(prefix) {
                return pid.trim().parse().unwrap();
            }
        }
    };
    let grandchild = pid("grandchild ");
    let child = pid("owned ");
    owner.wait().unwrap();
    let child_ended = ends_within(child, GONE_WITHIN);
    let grandchild_ended = ends_within(grandchild, GONE_WITHIN);
    terminate(grandchild);
    terminate(child);
    assert!(child_ended, "the owned child {child} outlived the process that owned it");
    assert!(grandchild_ended, "the grandchild {grandchild} outlived the process that owned it");
}
