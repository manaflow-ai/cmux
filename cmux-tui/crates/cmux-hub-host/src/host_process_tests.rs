use super::*;
use std::os::fd::AsFd;
use std::time::Instant;

fn scratch(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("hub-host-process-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A host of `dir` that never stops by itself: a process in a group of its own that holds
/// the lock on [`PID_FILE`] (its copy of the description) and wrote its pid there.
fn stuck_host(dir: &Path) -> cmux_process::Child {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .read(true)
        .write(true)
        .open(dir.join(PID_FILE))
        .unwrap();
    file.lock().unwrap();
    let mut child = cmux_process::Command::new("sh");
    child.args(["-c", "trap '' TERM; sleep 30; :"]).process_group(0);
    child.inherit_fd(file.as_fd(), 9).unwrap();
    let child = child.spawn().unwrap();
    (&file).write_all(child.id().to_string().as_bytes()).unwrap();
    // Closed without unlocking: the child's copy keeps the lock.
    drop(file);
    child
}

#[test]
fn a_host_that_does_not_stop_is_killed_and_then_gone() {
    let dir = scratch("stuck");
    let mut child = stuck_host(&dir);
    let other = hold(&dir).unwrap_err().to_string();
    assert!(other.contains(&format!("pid {}", child.id())), "{other}");
    let started = Instant::now();
    assert_eq!(ensure_gone(&dir, Duration::from_millis(100)), Ok(()));
    assert!(started.elapsed() < Duration::from_secs(2));
    let status = child.wait_timeout(Duration::from_secs(2)).unwrap().expect("still running");
    assert!(!status.success());
    // Gone: the next host starts and names itself.
    let _running = hold(&dir).unwrap();
    let text = std::fs::read_to_string(dir.join(PID_FILE)).unwrap();
    assert_eq!(text, std::process::id().to_string());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review of #45369: with a sign-in but no pid file, a host from an older build may run
/// unseen, so gone is not verified; with neither, nothing can serve.
#[test]
fn a_sign_in_without_a_pid_file_is_not_verified_gone() {
    let dir = scratch("old-build");
    for file in SIGN_IN_FILES {
        std::fs::write(dir.join(file), b"{}").unwrap();
        assert_eq!(ensure_gone(&dir, Duration::from_millis(50)), Err(None), "{file}");
        std::fs::remove_file(dir.join(file)).unwrap();
    }
    assert_eq!(ensure_gone(&dir, Duration::from_millis(50)), Ok(()));
    // A host of this build that ran and stopped left its file: gone is proven by its lock.
    std::fs::write(dir.join("device.json"), b"{}").unwrap();
    drop(hold(&dir).unwrap());
    assert_eq!(ensure_gone(&dir, Duration::from_millis(50)), Ok(()));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn no_host_is_gone_at_once_and_a_held_lock_is_one() {
    let dir = scratch("none");
    assert_eq!(ensure_gone(&dir, Duration::from_secs(5)), Ok(()), "no file");
    let running = hold(&dir).unwrap();
    assert!(hold(&dir).is_err(), "a second host started");
    drop(running);
    let started = Instant::now();
    assert_eq!(ensure_gone(&dir, Duration::from_secs(5)), Ok(()), "a host that stopped");
    assert!(started.elapsed() < Duration::from_secs(1));
    let _ = std::fs::remove_dir_all(&dir);
}
