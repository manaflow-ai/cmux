//! A test's scratch folder goes with its test (2026-11-17). The god bench (`god_daemon.rs`) made
//! `god-<shape>-<pid>` under the temp directory and removed it only at its next start, which a new
//! pid never reached: every run left 2 GB (a 1 GB daemon log) behind, pool VMs filled to their
//! 10 GiB disk guard and fleet jobs died at about 1 h 52 min. `daemon_env::Scratch` removes its
//! folder when it drops (the test returns, fails or panics), sweeps the folders of its tag whose
//! process is gone, and stays only with `ACPMUX_KEEP_SCRATCH=1`, printing its path.
//!
//! The detector, [`hand_made_temp_dirs_do_not_grow`]: test files may not add a hand-made
//! `temp_dir().join(…)` folder; a new one uses `daemon_env::Scratch` (or `tempfile`).
#![cfg(unix)]

use crate::daemon_env;

use daemon_env::Scratch;
use std::path::{Path, PathBuf};

fn fill(dir: &Path) {
    std::fs::create_dir_all(dir.join("home/logs")).unwrap();
    std::fs::write(dir.join("home/logs/daemon.log"), vec![b'x'; 1 << 20]).unwrap();
}

#[test]
fn a_scratch_is_removed_when_its_test_returns() {
    let parent = tempfile::tempdir().unwrap();
    let path = {
        let scratch = Scratch::under(parent.path(), "god-small", false);
        fill(&scratch);
        assert!(scratch.join("home/logs/daemon.log").exists());
        scratch.to_path_buf()
    };
    assert!(!path.exists(), "{} outlived its test", path.display());
}

#[test]
fn a_scratch_is_removed_when_its_test_panics() {
    let parent = tempfile::tempdir().unwrap();
    let seen = std::sync::Mutex::new(PathBuf::new());
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let scratch = Scratch::under(parent.path(), "god-small", false);
        fill(&scratch);
        *seen.lock().unwrap() = scratch.to_path_buf();
        panic!("a failed assertion mid-run");
    }));
    assert!(outcome.is_err());
    let path = seen.into_inner().unwrap();
    assert!(path.starts_with(parent.path()) && path != parent.path());
    assert!(!path.exists(), "{} outlived its panicking test", path.display());
}

#[test]
fn a_scratch_asked_to_stay_stays() {
    let parent = tempfile::tempdir().unwrap();
    let path = {
        let scratch = Scratch::under(parent.path(), "god-small", true);
        fill(&scratch);
        scratch.to_path_buf()
    };
    assert!(path.join("home/logs/daemon.log").exists());
}

#[test]
fn two_scratches_of_one_tag_in_one_process_are_two_folders() {
    let parent = tempfile::tempdir().unwrap();
    let a = Scratch::under(parent.path(), "god-small", false);
    let b = Scratch::under(parent.path(), "god-small", false);
    assert_ne!(a.path(), b.path());
    assert!(a.exists() && b.exists());
}

/// A pid that was this test's child and has been reaped: no process runs with it now.
fn dead_pid() -> u32 {
    let mut child = std::process::Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
    let pid = child.id();
    child.wait().unwrap();
    assert!(!daemon_env::alive(pid));
    pid
}

#[test]
fn a_new_scratch_sweeps_its_tags_folders_whose_process_is_gone() {
    let parent = tempfile::tempdir().unwrap();
    let dead = dead_pid();
    let mut live = std::process::Command::new("/bin/sh").args(["-c", "sleep 30"]).spawn().unwrap();
    let make = |name: String| {
        let dir = parent.path().join(name);
        fill(&dir);
        dir
    };
    // Left by a killed run of this tag: swept.
    let gone = make(format!("god-small-p{dead}-0"));
    // A running process's, another tag's, and a tag that only starts with this one: kept.
    let running = make(format!("god-small-p{}-0", live.id()));
    let other_tag = make(format!("god-churn-p{dead}-0"));
    let longer_tag = make(format!("god-small-2-p{dead}-0"));
    let not_a_pid = make("god-small-pnotes".to_owned());
    let scratch = Scratch::under(parent.path(), "god-small", false);
    let _ = live.kill();
    let _ = live.wait();
    assert!(!gone.exists(), "a dead run's folder was kept");
    for kept in [&running, &other_tag, &longer_tag, &not_a_pid] {
        assert!(kept.exists(), "{} was swept", kept.display());
    }
    assert!(scratch.exists());
}

#[test]
fn the_process_and_tool_folders_of_gone_processes_are_swept() {
    let parent = tempfile::tempdir().unwrap();
    let dead = dead_pid();
    let proc_dir = parent.path().join(format!("amx-proc-{dead}"));
    let bin_dir = parent.path().join(format!("amx-bin-{dead}-python3-git"));
    let own = parent.path().join(format!("amx-proc-{}", std::process::id()));
    for dir in [&proc_dir, &bin_dir, &own] {
        fill(dir);
    }
    daemon_env::sweep_dead(parent.path(), "amx-proc-");
    daemon_env::sweep_dead(parent.path(), "amx-bin-");
    assert!(!proc_dir.exists() && !bin_dir.exists());
    assert!(own.exists(), "this process's own folder was swept");
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

/// `temp_dir()` then `.join(`, with any whitespace (rustfmt may break the line) between.
fn hand_made(text: &str) -> usize {
    text.match_indices("temp_dir()")
        .filter(|(at, m)| text[at + m.len()..].trim_start().starts_with(".join("))
        .count()
}

/// The hand-made temp folders in `tests/` when this guard landed. Each one a test file adds is a
/// folder no one removes unless its author writes the removal on every path, panics included;
/// `daemon_env::Scratch` does. Lower this as files move to it; never raise it.
const HAND_MADE_BASELINE: usize = 485;

#[test]
fn hand_made_temp_dirs_do_not_grow() {
    let tests = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let mut files = Vec::new();
    rust_files(&tests, &mut files);
    let mut count = 0;
    for file in &files {
        let rel = file.strip_prefix(&tests).unwrap();
        // The helper's own tool links, and this file's needle.
        if rel == Path::new("support/daemon_env.rs") || rel == Path::new("scratch_guard.rs") {
            continue;
        }
        count += hand_made(&std::fs::read_to_string(file).unwrap());
    }
    assert!(
        count <= HAND_MADE_BASELINE,
        "tests/ has {count} hand-made `temp_dir().join(…)` folders, more than the \
         {HAND_MADE_BASELINE} of tests/scratch_guard.rs: a new test's scratch folder is \
         `daemon_env::Scratch::new(\"<tag>\")` (removed when the test returns or panics, swept \
         when its process is gone, kept with ACPMUX_KEEP_SCRATCH=1) or a `tempfile::TempDir`"
    );
}
