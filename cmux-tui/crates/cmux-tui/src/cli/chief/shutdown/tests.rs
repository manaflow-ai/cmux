//! `cmux chief shutdown` (E20): the parse, and the brain stop against a
//! process that holds the home's host lock the way the brain does.

use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

use super::stop_brain;

/// A stand-in brain: holds an exclusive flock on `lock`, writes its pid
/// first like optchat-chief's HostLock, and exits on SIGTERM.
fn fake_brain(lock: &Path) -> Child {
    let child = Command::new("python3")
        .arg("-c")
        .arg(
            "import fcntl, os, sys, time\n\
             f = open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX)\n\
             f.write(f'{os.getpid()}\\n1\\nflock\\n'); f.flush()\n\
             time.sleep(600)\n",
        )
        .arg(lock)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !super::brain_running(lock) {
        assert!(Instant::now() < deadline, "the fake brain never took the lock");
        std::thread::sleep(Duration::from_millis(20));
    }
    child
}

#[test]
fn shutdown_parses_as_its_own_command() {
    let args = super::super::parse_args(&["shutdown".to_owned()]).unwrap();
    assert!(args.shutdown);
    assert!(args.control.is_none() && args.prompt.is_none());
}

#[test]
fn the_brain_gets_sigterm_and_the_stop_waits_for_its_lock() {
    let dir = tempfile::tempdir().unwrap();
    let lock = dir.path().join("host.lock");
    let mut brain = fake_brain(&lock);
    assert_eq!(stop_brain(&lock, Duration::from_secs(10)), Ok(true));
    assert!(!super::brain_running(&lock), "the lock is free when the stop returns");
    let status = brain.wait().unwrap();
    assert!(!status.success(), "it ended by the signal: {status:?}");
}

#[test]
fn no_brain_is_nothing_to_stop() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(stop_brain(&dir.path().join("host.lock"), Duration::from_secs(1)), Ok(false));
}
