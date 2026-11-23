//! `cmux-projection git-mount` as `wt new --projected` runs it under a service manager: a stop
//! (SIGTERM) unmounts before the process exits, and a mount whose server died anyway (SIGKILL, an
//! OOM kill) is mounted over again by the next start at the same path, with the edits kept.
#![cfg(target_os = "linux")]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && Command::new("fusermount3")
            .arg("--version")
            .output()
            .is_ok_and(|output| output.status.success())
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

/// A bare repo with one commit; returns it and the commit.
fn repo(root: &Path) -> (PathBuf, String) {
    let work = root.join("work");
    std::fs::create_dir_all(work.join("src")).unwrap();
    git(&work, &["init", "-q"]);
    std::fs::write(work.join("README.md"), "hello\n").unwrap();
    std::fs::write(work.join("src/main.rs"), "fn main() {}\n").unwrap();
    git(&work, &["add", "-A"]);
    git(&work, &["commit", "-qm", "one"]);
    let commit = git(&work, &["rev-parse", "HEAD"]);
    let bare = root.join("mirror.git");
    git(root, &["clone", "-q", "--bare", work.to_str().unwrap(), bare.to_str().unwrap()]);
    (bare, commit)
}

fn mount(bare: &Path, commit: &str, at: &Path, keep: &Path, ready: &Path) -> Child {
    let _ = std::fs::remove_file(ready);
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-projection"))
        .args(["git-mount", "--git-dir"])
        .arg(bare)
        .args(["--commit", commit, "--at"])
        .arg(at)
        .arg("--keep")
        .arg(keep)
        .args(["--name", "restart"])
        .arg("--ready-file")
        .arg(ready)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    while !std::fs::metadata(ready).is_ok_and(|meta| meta.len() > 0) {
        if let Some(status) = child.try_wait().unwrap() {
            let mut text = String::new();
            std::io::Read::read_to_string(child.stderr.as_mut().unwrap(), &mut text).unwrap();
            panic!("git-mount exited {status} before it was ready: {text}");
        }
        assert!(Instant::now() < deadline, "git-mount not ready within 60 s");
        std::thread::sleep(Duration::from_millis(20));
    }
    child
}

fn mounted(at: &Path) -> bool {
    let at = at.canonicalize().unwrap_or_else(|_| at.to_path_buf());
    std::fs::read_to_string("/proc/self/mountinfo")
        .unwrap()
        .lines()
        .any(|line| line.split(' ').nth(4) == Some(at.to_str().unwrap()))
}

fn wait_exit(child: &mut Child) -> std::process::ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "git-mount still running 30 s after the signal");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_stopped_mount_unmounts_and_a_killed_one_mounts_again_with_its_edits() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let root = tempfile::tempdir().unwrap();
    let (bare, commit) = repo(root.path());
    let at = root.path().join("checkout");
    let keep = root.path().join("keep");
    let ready = root.path().join("ready");

    // A stop: SIGTERM unmounts, and the process exits cleanly.
    let mut child = mount(&bare, &commit, &at, &keep, &ready);
    assert_eq!(std::fs::read_to_string(at.join("README.md")).unwrap(), "hello\n");
    std::fs::write(at.join("README.md"), "edited\n").unwrap();
    // SAFETY: kill on a child this test spawned.
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    let status = wait_exit(&mut child);
    assert!(status.success(), "a stop exits 0, got {status}");
    assert!(!mounted(&at), "a stop leaves no mount behind");
    std::fs::metadata(&at).expect("the mount point is a plain folder again");

    // A crash: SIGKILL leaves a dead mount (ENOTCONN) or, where fusermount3's helper outlives the
    // server and detaches it, none; either way the next start mounts there, edits kept.
    let mut child = mount(&bare, &commit, &at, &keep, &ready);
    assert_eq!(std::fs::read_to_string(at.join("README.md")).unwrap(), "edited\n");
    child.kill().unwrap();
    child.wait().unwrap();
    if let Err(dead) = std::fs::metadata(&at) {
        assert_eq!(
            dead.raw_os_error(),
            Some(libc::ENOTCONN),
            "SIGKILL leaves a dead mount: {dead}"
        );
    }
    let mut child = mount(&bare, &commit, &at, &keep, &ready);
    assert_eq!(std::fs::read_to_string(at.join("README.md")).unwrap(), "edited\n");
    assert_eq!(std::fs::read_to_string(at.join("src/main.rs")).unwrap(), "fn main() {}\n");
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert!(wait_exit(&mut child).success());
    assert!(!mounted(&at));
}

fn lower(bare: &Path, commit: &str, at: &Path, keep: &Path, index: &Path, ready: &Path) -> Child {
    let _ = std::fs::remove_file(ready);
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-projection"))
        .args(["git-lower", "--git-dir"])
        .arg(bare)
        .args(["--commit", commit, "--at"])
        .arg(at)
        .arg("--keep")
        .arg(keep)
        .arg("--index")
        .arg(index)
        .arg("--ready-file")
        .arg(ready)
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    while !ready.exists() {
        assert!(child.try_wait().unwrap().is_none(), "git-lower exited before it was ready");
        assert!(Instant::now() < deadline, "git-lower was not ready in 60 s");
        std::thread::sleep(Duration::from_millis(50));
    }
    child
}

#[test]
fn a_lower_is_read_only_and_its_index_matches_it() {
    if !fuse_here() {
        eprintln!("skipped: no FUSE here");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let (bare, commit) = repo(dir.path());
    let at = dir.path().join("lower");
    let index = dir.path().join("index");
    let ready = dir.path().join("ready");
    let mut child = lower(&bare, &commit, &at, &dir.path().join("keep"), &index, &ready);
    assert_eq!(std::fs::read_to_string(at.join("README.md")).unwrap(), "hello\n");
    assert!(!at.join(".git").exists(), "a lower has no .git of its own");
    let write = std::fs::write(at.join("README.md"), "no\n").unwrap_err();
    assert_eq!(write.raw_os_error(), Some(libc::EROFS), "a lower takes no writes: {write}");
    // git, pointed at the lower with its index, finds every file clean from stat data alone:
    // `diff-files` never refreshes, so a stat mismatch would list the file.
    let status = Command::new("git")
        .arg("--git-dir")
        .arg(&bare)
        .arg("--work-tree")
        .arg(&at)
        .args(["diff-files", "--name-only"])
        .env("GIT_INDEX_FILE", &index)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(status.status.success(), "{}", String::from_utf8_lossy(&status.stderr));
    assert_eq!(String::from_utf8_lossy(&status.stdout), "", "the index matches the lower");
    // SAFETY: kill on a child this test spawned.
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert!(wait_exit(&mut child).success());
    assert!(!mounted(&at));
}
