use std::os::unix::fs::MetadataExt as _;
use std::path::Path;
use std::time::{Duration, Instant};

use super::{runs_this_install, stop};

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
