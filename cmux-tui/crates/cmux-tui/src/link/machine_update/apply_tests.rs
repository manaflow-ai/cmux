use std::os::unix::fs::MetadataExt as _;
use std::path::Path;
use std::time::{Duration, Instant};

use super::{claim, claim_path, keep_previous, runs_this_install, stop};

const INSTALL: &str = "/home/u/.cmux/bin/cmux-tui";

fn runs(running: &str) -> bool {
    runs_this_install(Path::new(running), Path::new(INSTALL), None)
}

#[test]
fn a_daemon_on_the_installed_binary_updates() {
    assert!(runs(INSTALL));
}

#[test]
fn a_daemon_on_a_replaced_copy_of_this_install_updates() {
    // An earlier update (or upgrade) renamed a new build over the binary while
    // this daemon kept running the old file, which the kernel now marks.
    assert!(runs("/home/u/.cmux/bin/cmux-tui (deleted)"));
    // The previous build an update kept beside it, or its rollback link.
    assert!(runs("/home/u/.cmux/bin/cmux-tui.prev"));
    assert!(runs("/home/u/.cmux/bin/cmux-tui.prev (deleted)"));
    assert!(runs("/home/u/.cmux/bin/.cmux-tui.rollback (deleted)"));
}

#[test]
fn a_daemon_on_the_file_now_kept_as_previous_updates() {
    let folder = tempfile::tempdir().unwrap();
    let install = folder.path().join("cmux-tui");
    let previous = folder.path().join("cmux-tui.prev");
    std::fs::write(&install, b"new").unwrap();
    std::fs::write(&previous, b"old").unwrap();
    let kept = std::fs::metadata(&previous).unwrap();
    let other = std::fs::metadata(&install).unwrap();
    let elsewhere = Path::new("/somewhere/else");
    assert!(runs_this_install(elsewhere, &install, Some((kept.dev(), kept.ino()))));
    assert!(!runs_this_install(elsewhere, &install, Some((other.dev(), other.ino() + 1_000_000))));
}

#[test]
fn a_foreign_binary_still_refuses() {
    for running in [
        "/usr/local/bin/cmux-tui",
        "/usr/local/bin/cmux-tui (deleted)",
        "/home/other/.cmux/bin/cmux-tui",
        "/home/other/.cmux/bin/cmux-tui (deleted)",
        "/home/u/.cmux/bin/cmux-tui-other",
        "/home/u/.cmux/bin/cmux",
        "/home/u/.cmux/bin/.cmux-tui.update-0123456789abcdef",
        "/home/u/.cmux/cmux-tui (deleted)",
        "cmux-tui (deleted)",
        "",
    ] {
        assert!(!runs(running), "{running}");
    }
}

#[test]
fn a_daemon_that_ignores_sigterm_is_stopped_with_sigkill() {
    // An ignored signal stays ignored across exec: this sleep ignores SIGTERM,
    // as a daemon whose stop never finished did.
    let mut child = std::process::Command::new("sh")
        .args(["-c", "trap '' TERM; exec sleep 60"])
        .spawn()
        .unwrap();
    let pid = i32::try_from(child.id()).unwrap();
    // Reap it at once so a dead child is not a zombie that still answers signal 0.
    let reaper = std::thread::spawn(move || child.wait());
    std::thread::sleep(Duration::from_millis(200));
    // SAFETY: a signal to the child this test started.
    assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    let started = Instant::now();
    assert!(stop(pid, Duration::from_millis(300), Duration::from_secs(10)));
    assert!(started.elapsed() < Duration::from_secs(10));
    let status = reaper.join().unwrap().unwrap();
    use std::os::unix::process::ExitStatusExt as _;
    assert_eq!(status.signal(), Some(libc::SIGKILL));
}

#[test]
fn a_daemon_that_stops_on_sigterm_is_not_killed() {
    let mut child = std::process::Command::new("sleep").arg("60").spawn().unwrap();
    let pid = i32::try_from(child.id()).unwrap();
    let reaper = std::thread::spawn(move || child.wait());
    // SAFETY: a signal to the child this test started.
    assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    assert!(stop(pid, Duration::from_secs(10), Duration::from_secs(10)));
    use std::os::unix::process::ExitStatusExt as _;
    assert_eq!(reaper.join().unwrap().unwrap().signal(), Some(libc::SIGTERM));
}

fn id(path: &Path) -> Option<(u64, u64)> {
    std::fs::metadata(path).ok().map(|file| (file.dev(), file.ino()))
}

/// A folder with an installed build B, a kept build A and a deleted build R
/// standing in for the file a daemon runs after its path was replaced.
fn builds() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
    let folder = tempfile::tempdir().unwrap();
    let install = folder.path().join("cmux-tui");
    let previous = folder.path().join("cmux-tui.prev");
    let running = folder.path().join("running");
    std::fs::write(&install, b"B").unwrap();
    std::fs::write(&previous, b"A").unwrap();
    std::fs::write(&running, b"R").unwrap();
    (folder, install, previous, running)
}

#[test]
fn a_daemon_on_the_installed_binary_keeps_it_as_previous() {
    let (_folder, install, previous, running) = builds();
    keep_previous(&install, &previous, &running, id(&install)).unwrap();
    assert_eq!(id(&previous), id(&install));
}

#[test]
fn a_daemon_on_the_kept_build_keeps_it_as_previous() {
    // An update installed B while the daemon kept running A, now kept as
    // previous: rolling back must go to A, which served, not to B.
    let (_folder, install, previous, running) = builds();
    let kept = id(&previous);
    keep_previous(&install, &previous, &running, kept).unwrap();
    assert_eq!(id(&previous), kept);
    assert_eq!(std::fs::read(&previous).unwrap(), b"A");
}

#[test]
fn a_daemon_on_a_deleted_build_keeps_a_copy_of_it_as_previous() {
    let (_folder, install, previous, running) = builds();
    keep_previous(&install, &previous, &running, id(&running)).unwrap();
    assert_eq!(std::fs::read(&previous).unwrap(), b"R");
    assert_eq!(std::fs::read(&install).unwrap(), b"B");
    assert!(!install.with_file_name(".cmux-tui.prev.part").exists());
}

#[test]
fn a_second_run_of_one_update_finds_its_outcome_claimed() {
    let folder = tempfile::tempdir().unwrap();
    let result = folder.path().join(".cmux-tui.update-0123456789abcdef.json");
    assert_eq!(claim_path(&result), folder.path().join(".cmux-tui.update-0123456789abcdef.lock"));
    let first = claim(&result).expect("the first run claims the outcome");
    // A start sent again while the first run checks: it writes nothing.
    assert!(claim(&result).is_none());
    // Another update (its own nonce) is not held by it; the folder lock orders those.
    assert!(claim(&folder.path().join(".cmux-tui.update-fedcba9876543210.json")).is_some());
    drop(first);
    assert!(claim(&result).is_some());
}
