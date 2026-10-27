//! Closing a provider command waits on its child's exit event, then on the
//! rest of its group within the grace (p14-energy-077b).

use std::fs;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_process::{Command, Stdio};

use super::{COMMAND_TERMINATION_GRACE, ProcessCleanup};
use crate::process_diagnostics::BoundedDiagnosticBuffer;

fn cleanup_for(script: &str) -> ProcessCleanup {
    let child = Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn the provider stand-in");
    let process_group = libc::pid_t::try_from(child.id()).expect("a valid pid");
    let (stderr_cancel, _) = UnixStream::pair().expect("a socket pair");
    ProcessCleanup {
        process_group,
        child: Mutex::new(Some(child)),
        diagnostics: Arc::new(BoundedDiagnosticBuffer::new(1024)),
        stderr_cancel,
        stderr_worker: Mutex::new(None),
        closed: AtomicBool::new(false),
    }
}

fn wait_for_file(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !path.exists() {
        assert!(Instant::now() < deadline, "timed out waiting for {}", path.display());
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_child_that_exits_on_sigterm_ends_the_close_at_its_exit() {
    let cleanup = cleanup_for("exec sleep 30");
    let closing = Instant::now();
    cleanup.terminate_and_reap();
    let took = closing.elapsed();
    assert!(
        took < COMMAND_TERMINATION_GRACE / 2,
        "the close ended at the child's exit, not at the grace: {took:?}"
    );
    assert!(!cleanup.group_is_alive());
    assert!(cleanup.child.lock().unwrap().is_none(), "the child was taken and reaped");
}

#[test]
fn a_group_member_that_ignores_sigterm_is_killed_when_the_grace_ends() {
    let directory = std::env::temp_dir().join(format!(
        "cmux-pt-cleanup-{}-{:?}",
        std::process::id(),
        Instant::now()
    ));
    fs::create_dir_all(&directory).expect("create the test directory");
    let ready = directory.join("ready");
    let cleanup =
        cleanup_for(&format!("(trap '' TERM; : > '{}'; exec sleep 30) & wait", ready.display()));
    wait_for_file(&ready);
    let closing = Instant::now();
    cleanup.terminate_and_reap();
    let took = closing.elapsed();
    assert!(took >= COMMAND_TERMINATION_GRACE, "the member got the whole grace: {took:?}");
    assert!(took < Duration::from_secs(5), "SIGKILL ended the member: {took:?}");
    // The killed member is reaped by its new parent, not by this process.
    let reaped_by = Instant::now() + Duration::from_secs(5);
    while cleanup.group_is_alive() {
        assert!(Instant::now() < reaped_by, "the group is gone after SIGKILL");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_dir_all(&directory);
}
