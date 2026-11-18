//! `git status` in a projected repository answered by git's fsmonitor hook from the projection's
//! change set (`cmux link project fsmonitor`, RFD 0007 open question 4), against git's own scan of
//! every file. The repository is a plain folder laid out as the projection shows it, with the
//! projection's state (upper layer, whiteouts, manifest id, mount point) beside it, so the real
//! hook binary and the real git run; the agent's edits are made in both, as the overlay does.
//!
//! The regular test checks `git status` is the same with and without the hook after edits,
//! creates and deletes, and that the hook makes git look at fewer files.
//! `a_bench_of_git_status_with_the_hook` prints the times for a 200,000-file repository.
#![cfg(target_os = "linux")]

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

struct Repo {
    _root: tempfile::TempDir,
    state_dir: PathBuf,
    projection: PathBuf,
    work: PathBuf,
    hook: PathBuf,
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// A projected folder `folder` holding the repository `cmux` of `files` files, its projection's
/// state in `state/projections/chat-t`.
fn repo(files: usize) -> Repo {
    let root = tempfile::tempdir().unwrap();
    let base = std::fs::canonicalize(root.path()).unwrap();
    let folder = base.join("folder");
    let work = folder.join("cmux");
    for index in 0..files {
        let path =
            work.join(format!("d{:03}/e{:02}/f{index:07}.rs", index / 2000, (index / 50) % 40));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, format!("// {index}\n")).unwrap();
    }
    git(&work, &["init", "-q"]);
    git(&work, &["add", "."]);
    git(&work, &["commit", "-qm", "init"]);
    let state_dir = base.join("state");
    let projection = state_dir.join("projections/chat-t");
    std::fs::create_dir_all(projection.join("cache")).unwrap();
    std::fs::create_dir_all(projection.join("upper")).unwrap();
    std::fs::write(projection.join("cache/manifest-id"), "0123456789abcdef\n").unwrap();
    std::fs::write(projection.join("mount-point"), folder.as_os_str().as_encoded_bytes()).unwrap();
    let hook = base.join("fsmonitor-hook");
    std::fs::write(
        &hook,
        format!(
            "#!/bin/sh\nCMUX_TUI_STATE_DIR='{}' exec '{}' link project fsmonitor \"$@\"\n",
            state_dir.display(),
            env!("CARGO_BIN_EXE_cmux-tui")
        ),
    )
    .unwrap();
    std::fs::set_permissions(&hook, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    Repo { _root: root, state_dir, projection, work, hook }
}

impl Repo {
    /// An edit by the agent: in the working tree, and in the upper layer as the overlay keeps it.
    fn write(&self, relative: &str, text: &str) {
        for at in [self.work.join(relative), self.projection.join("upper/cmux").join(relative)] {
            std::fs::create_dir_all(at.parent().unwrap()).unwrap();
            std::fs::write(at, text).unwrap();
        }
    }

    fn delete(&self, relative: &str) {
        std::fs::remove_file(self.work.join(relative)).unwrap();
        let whiteouts = self.projection.join("whiteouts");
        let mut text = std::fs::read_to_string(&whiteouts).unwrap_or_default();
        text.push_str(&format!("cmux/{relative}\n"));
        std::fs::write(whiteouts, text).unwrap();
    }

    /// `git status --porcelain`, with the hook or git's own scan, and how long it took.
    fn status(&self, hooked: bool) -> (String, Duration) {
        let mut args = vec!["-c".to_owned(), "core.untrackedCache=true".to_owned()];
        if hooked {
            args.extend(["-c".to_owned(), format!("core.fsmonitor={}", self.hook.display())]);
        } else {
            args.extend(["-c".to_owned(), "core.fsmonitor=false".to_owned()]);
        }
        args.extend(["status".to_owned(), "--porcelain".to_owned()]);
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let started = Instant::now();
        let out = git(&self.work, &args);
        (out, started.elapsed())
    }

    /// How many stat calls `git status` made, the hook's own included (strace; 0 when strace is not
    /// installed). A run without the hook writes the index without git's fsmonitor token, so a
    /// hooked count first runs once to record it again.
    fn lstat_count(&self, hooked: bool) -> usize {
        if hooked {
            let _ = self.status(true);
        }
        let trace = self.state_dir.join(format!("trace-{hooked}.txt"));
        let _ = std::fs::remove_file(&trace);
        let hook = format!(
            "core.fsmonitor={}",
            if hooked { self.hook.display().to_string() } else { "false".into() }
        );
        let output = Command::new("strace")
            .args(["-f", "-c", "-e", "trace=lstat,newfstatat,statx", "-o"])
            .arg(&trace)
            .arg("git")
            .arg("-C")
            .arg(&self.work)
            .args(["-c", "core.untrackedCache=true", "-c", &hook, "status", "--porcelain"])
            .output();
        if !output.is_ok_and(|output| output.status.success()) {
            return 0;
        }
        std::fs::read_to_string(&trace)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| {
                let words: Vec<&str> = line.split_whitespace().collect();
                words.last().filter(|name| ["lstat", "newfstatat", "statx"].contains(name))?;
                words.get(3)?.parse::<usize>().ok()
            })
            .sum()
    }
}

fn edits(r: &Repo) {
    r.write("d000/e00/f0000000.rs", "// edited on the machine\n");
    r.write("d000/e01/new.rs", "// new on the machine\n");
    r.write("fresh/dir/made.rs", "// a new folder\n");
    r.delete("d000/e02/f0000100.rs");
}

#[test]
fn git_status_is_the_same_with_the_hook_and_checks_only_what_changed() {
    let r = repo(5_000);
    // git records our token on the first run (answered "everything"), then asks with it.
    let (first, _) = r.status(true);
    assert_eq!(first, "");
    let (warm, _) = r.status(true);
    assert_eq!(warm, "");
    edits(&r);
    let (scanned, _) = r.status(false);
    let (hooked, _) = r.status(true);
    assert_eq!(hooked, scanned, "the hook's status is git's own");
    assert!(scanned.contains(" M d000/e00/f0000000.rs"), "{scanned}");
    assert!(scanned.contains(" D d000/e02/f0000100.rs"), "{scanned}");
    assert!(scanned.contains("?? d000/e01/new.rs"), "{scanned}");
    assert!(scanned.contains("?? fresh/"), "{scanned}");
    // A second edit after the first hooked run is seen too.
    r.write("d001/e00/f0002000.rs", "// later\n");
    let (later, _) = r.status(true);
    assert!(later.contains(" M d001/e00/f0002000.rs"), "{later}");
    assert_eq!(later, r.status(false).0);
    let (with, without) = (r.lstat_count(true), r.lstat_count(false));
    eprintln!("stat calls: {with} with the hook, {without} without");
    if without > 0 {
        assert!(with * 4 < without, "{with} stat calls with the hook, {without} without");
    }
}

#[test]
#[ignore = "a bench: CMUX_FSMONITOR_BENCH_FILES=200000 cargo test --release --test link_project_fsmonitor -- --ignored --nocapture"]
fn a_bench_of_git_status_with_the_hook() {
    let files = std::env::var("CMUX_FSMONITOR_BENCH_FILES")
        .ok()
        .and_then(|n| n.parse().ok())
        .unwrap_or(200_000);
    let r = repo(files);
    let _ = r.status(true);
    let _ = r.status(true);
    edits(&r);
    // Each side's first run settles the index for it (a run without the hook drops git's token).
    let best = |hooked: bool| {
        let _ = r.status(hooked);
        (0..5).map(|_| r.status(hooked).1).min().unwrap()
    };
    let (without, with) = (best(false), best(true));
    println!("| git status, {files} files, 4 edits | best of 5 | stat calls |\n|---|---|---|");
    println!("| git's own scan (before) | {} ms | {} |", without.as_millis(), r.lstat_count(false));
    println!(
        "| fsmonitor from the change set (after) | {} ms | {} |",
        with.as_millis(),
        r.lstat_count(true)
    );
    println!(
        "plain disk; over the projection's FUSE mount each stat git skips is a round trip to the daemon"
    );
}
