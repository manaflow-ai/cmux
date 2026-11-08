//! The WireGuard key lock across real processes: a child process (this test
//! binary again, running only `holder_child`) takes the lock, and this
//! process is refused with the child's pid until the child is killed.

use std::io::{BufRead as _, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

use cmux_link::key_holder::{KeyHolder, KeyHolderError, PID_FILE, holder};

const CHILD_DIR: &str = "CMUX_KEY_HOLDER_CHILD_DIR";
const HELD: &str = "KEY_HOLDER_CHILD_HELD";

/// The child side: hold the lock in `$CMUX_KEY_HOLDER_CHILD_DIR`, say so,
/// then wait until the parent closes stdin or kills this process. Without
/// the variable (an ordinary test run) it does nothing.
#[test]
fn holder_child() {
    let Some(dir) = std::env::var_os(CHILD_DIR) else { return };
    let _held = KeyHolder::acquire(Path::new(&dir)).expect("child takes the lock");
    println!("{HELD}");
    let mut line = String::new();
    while std::io::stdin().read_line(&mut line).is_ok_and(|read| read > 0) {
        line.clear();
    }
}

fn spawn_holder(dir: &Path) -> Child {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "holder_child", "--nocapture", "--test-threads", "1"])
        .env(CHILD_DIR, dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    for line in stdout.lines() {
        if line.unwrap().trim() == HELD {
            return child;
        }
    }
    let _ = child.kill();
    panic!("the child exited without taking the lock: {:?}", child.wait());
}

fn fresh_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-key-holder-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn a_second_process_is_refused_with_the_holders_pid_until_the_holder_dies() {
    let dir = fresh_dir("processes");
    let mut child = spawn_holder(&dir);
    let pid = child.id();
    match KeyHolder::acquire(&dir) {
        Err(KeyHolderError::KeyHeld { pid: Some(held) }) => assert_eq!(held, pid),
        other => panic!("expected KeyHeld with pid {pid}, got {other:?}"),
    }
    assert_eq!(holder(&dir).unwrap(), Some(Some(pid)));
    // Killed, not asked: the OS releases the lock with the process.
    child.kill().unwrap();
    child.wait().unwrap();
    let taken = KeyHolder::acquire(&dir).expect("the lock is free once its holder died");
    assert_eq!(holder(&dir).unwrap(), Some(Some(std::process::id())));
    drop(taken);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_stale_pid_record_without_the_lock_is_not_held() {
    let dir = fresh_dir("stale");
    std::fs::create_dir_all(&dir).unwrap();
    // A record naming a live process (pid 1 always runs) that holds no lock.
    std::fs::write(dir.join(PID_FILE), "1\n").unwrap();
    assert_eq!(holder(&dir).unwrap(), None);
    let taken = KeyHolder::acquire(&dir).expect("a stale record never blocks");
    let record = std::fs::read_to_string(dir.join(PID_FILE)).unwrap();
    assert_eq!(record.trim(), std::process::id().to_string());
    drop(taken);
    let _ = std::fs::remove_dir_all(&dir);
}
