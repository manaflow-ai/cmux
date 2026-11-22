//! Focused regression and measurement harnesses for finished-worktree checks.

#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cmux_worktree_care::inventory::{self, FinishedMemo};

// The shim and HOME are process-global. Keep the integration tests from
// racing each other's temporary repositories when the harness runs in
// parallel (the default for `cargo test`).
static ENV_LOCK: Mutex<()> = Mutex::new(());

fn scratch(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "care-bounds-{name}-{}-{}",
        std::process::id(),
        inventory::now_ms()
    ));
    std::fs::create_dir(&path).unwrap();
    path
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.name=test", "-c", "user.email=test@example.com"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

fn write(path: &Path, text: &str) {
    std::fs::write(path, text).unwrap();
}

fn repository(name: &str) -> (PathBuf, PathBuf) {
    let root = scratch(name);
    let origin = root.join("origin.git");
    git(&root, &["init", "--bare", origin.to_str().unwrap()]);
    let main = root.join("main");
    git(&root, &["clone", origin.to_str().unwrap(), "main"]);
    write(&main.join("file"), "base\n");
    git(&main, &["add", "file"]);
    git(&main, &["commit", "-m", "base"]);
    git(&main, &["push", "origin", "HEAD:main"]);
    git(&main, &["remote", "set-head", "origin", "main"]);
    (root, main)
}

#[cfg(target_os = "linux")]
fn many_squashed_worktrees(name: &str, count: usize) -> (PathBuf, PathBuf) {
    let (root, main) = repository(name);
    let mut branches = Vec::with_capacity(count);
    // Create every linked worktree before advancing main, so all histories
    // have the same unsquashed starting point.
    for index in 0..count {
        let branch = format!("perf-{index:02}");
        let path = root.join(format!("wt-{index:02}"));
        git(&main, &["worktree", "add", "-b", &branch, path.to_str().unwrap()]);
        write(&path.join(format!("change-{index:02}")), &format!("change {index}\n"));
        git(&path, &["add", "."]);
        git(&path, &["commit", "-m", &branch]);
        branches.push(branch);
    }
    for branch in branches {
        git(&main, &["merge", "--squash", &branch]);
        git(&main, &["commit", "-m", "squash"]);
    }
    git(&main, &["push", "origin", "HEAD:main"]);
    git(&main, &["fetch", "origin"]);
    (root, main)
}

fn common(main: &Path) -> PathBuf {
    PathBuf::from(git(main, &["rev-parse", "--path-format=absolute", "--git-common-dir"]))
}

/// The git a shim in front of PATH runs: native Git from its own executable
/// directory. Hosted runners may put a Go caching wrapper on PATH, and the
/// peak RSS measured here must be Git's own; invoking the shim recursively
/// would otherwise hide real git.
fn native_git() -> PathBuf {
    let path_git = std::env::var_os("PATH")
        .unwrap()
        .to_string_lossy()
        .split(':')
        .map(PathBuf::from)
        .map(|dir| dir.join("git"))
        .find(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("/usr/bin/git"));
    let exec_path = Command::new(&path_git).arg("--exec-path").output().unwrap();
    assert!(exec_path.status.success());
    let native = PathBuf::from(String::from_utf8_lossy(&exec_path.stdout).trim()).join("git");
    if native.is_file() { native } else { path_git }
}

fn trace_git(root: &Path) -> (PathBuf, Option<std::ffi::OsString>) {
    let (trace, _rss, old_path) = trace_git_with_rss(root);
    (trace, old_path)
}

fn trace_git_with_rss(root: &Path) -> (PathBuf, PathBuf, Option<std::ffi::OsString>) {
    let trace = root.join("git.trace");
    let rss = root.join("merge-tree.rss-kb");
    let real = native_git();
    let shim = root.join("git");
    let time = if cfg!(target_os = "linux") { "/usr/bin/time" } else { "/nonexistent" };
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nfor arg do\n  if [ \"$arg\" = merge-tree ]; then\n    if [ -x {time} ]; then\n      exec /usr/bin/time -f '%M' -a -o '{}' '{}' \"$@\"\n    fi\n    break\n  fi\ndone\nexec '{}' \"$@\"\n",
        trace.display(),
        rss.display(),
        real.display(),
        real.display()
    );
    write(&shim, &script);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    (trace, rss, std::env::var_os("PATH"))
}

fn prepend_path(root: &Path, old: Option<&std::ffi::OsString>) {
    let mut path = root.display().to_string();
    if let Some(old) = old {
        path.push(':');
        path.push_str(&old.to_string_lossy());
    }
    // Tests are selected individually by the hosted command; restoring the
    // process environment at the end keeps this harness polite to other tests.
    unsafe { std::env::set_var("PATH", path) };
}

fn isolate_home(root: &Path) -> Option<std::ffi::OsString> {
    let old = std::env::var_os("HOME");
    unsafe { std::env::set_var("HOME", root) };
    old
}

fn restore_home(old: Option<std::ffi::OsString>) {
    unsafe {
        match old {
            Some(home) => std::env::set_var("HOME", home),
            None => std::env::remove_var("HOME"),
        }
    }
}

fn clear_file(path: &Path) {
    std::fs::write(path, b"").unwrap();
}

#[cfg(target_os = "linux")]
fn peak_rss_kb(path: &Path) -> Option<u64> {
    std::fs::read_to_string(path)
        .ok()?
        .lines()
        .filter_map(|line| line.trim().parse::<u64>().ok())
        .max()
}

#[cfg(target_os = "linux")]
fn child_result(path: &Path) -> u128 {
    std::fs::read_to_string(path).unwrap().trim().parse().unwrap()
}

fn run_scan_child(mode: &str, common_dir: &Path, memo: &Path, result: &Path) {
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "finished_scan_child", "--nocapture"])
        .env("CARE_BOUNDS_MODE", mode)
        .env("CARE_BOUNDS_COMMON", common_dir)
        .env("CARE_BOUNDS_MEMO", memo)
        .env("CARE_BOUNDS_RESULT", result)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "scan child {mode} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn trace_count(trace: &Path, command: &str) -> usize {
    std::fs::read_to_string(trace)
        .unwrap_or_default()
        .lines()
        .filter(|line| line.split_whitespace().any(|token| token == command))
        .count()
}

#[test]
fn restart_uses_persisted_finished_answer_without_merge_tree() {
    let _environment = ENV_LOCK.lock().unwrap();
    let (root, main) = repository("restart");
    let worktree = root.join("wt");
    git(&main, &["worktree", "add", "-b", "feature", worktree.to_str().unwrap()]);
    write(&worktree.join("file"), "feature\n");
    git(&worktree, &["commit", "-am", "feature"]);
    git(&main, &["merge", "--squash", "feature"]);
    git(&main, &["commit", "-m", "squash"]);
    git(&main, &["push", "origin", "HEAD:main"]);
    git(&main, &["fetch", "origin"]);
    let (trace, old_path) = trace_git(&root);
    prepend_path(&root, old_path.as_ref());
    let old_home = isolate_home(&root);
    let memo_path = root.join("memo.json");
    let common_dir = common(&main);
    let result = root.join("scan-ns");
    run_scan_child("prime", &common_dir, &memo_path, &result);
    assert!(trace_count(&trace, "merge-tree") >= 1, "first scan did not exercise merge-tree");
    clear_file(&trace);
    run_scan_child("persisted", &common_dir, &memo_path, &result);
    assert_eq!(trace_count(&trace, "merge-tree"), 0, "restart recomputed a persisted pair");
    unsafe { std::env::set_var("PATH", old_path.unwrap_or_default()) };
    restore_home(old_home);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn oversized_history_skips_merge_tree_before_running_it() {
    let _environment = ENV_LOCK.lock().unwrap();
    let (root, main) = repository("cutoff");
    let worktree = root.join("wt");
    git(&main, &["worktree", "add", "-b", "large", worktree.to_str().unwrap()]);
    for index in 0..129 {
        write(&worktree.join("file"), &format!("{index}\n"));
        git(&worktree, &["add", "file"]);
        git(&worktree, &["commit", "-m", "step"]);
    }
    git(&main, &["push", "origin", "HEAD:main"]);
    let (trace, old_path) = trace_git(&root);
    prepend_path(&root, old_path.as_ref());
    let old_home = isolate_home(&root);
    inventory::scan_with_memo(&common(&main), &[], Arc::new(FinishedMemo::memory())).unwrap();
    let log = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(log.lines().any(|line| line.contains("rev-list") && line.contains("--max-count=129")));
    assert!(
        !log.lines().any(|line| line.split_whitespace().any(|token| token == "merge-tree")),
        "cutoff still ran merge-tree"
    );
    unsafe { std::env::set_var("PATH", old_path.unwrap_or_default()) };
    restore_home(old_home);
    std::fs::remove_dir_all(root).unwrap();
}

/// A squash-merged worktree scanned through a `git` on PATH whose
/// merge-tree first maps 1 GiB of anonymous memory with `prot` (Python's
/// `mmap` names), the way a Go git wrapper's runtime reserves address space,
/// then runs native Git. Returns the worktree's `finished` answer.
#[cfg(target_os = "linux")]
fn squash_answer_with_merge_tree_mapping(name: &str, prot: &str) -> Option<String> {
    let python = Command::new("python3").arg("-V").output();
    assert!(python.is_ok_and(|out| out.status.success()), "the shim needs python3");
    let (root, main) = repository(name);
    let worktree = root.join("wt");
    git(&main, &["worktree", "add", "-b", "feature", worktree.to_str().unwrap()]);
    write(&worktree.join("file"), "feature\n");
    git(&worktree, &["commit", "-am", "feature"]);
    git(&main, &["merge", "--squash", "feature"]);
    git(&main, &["commit", "-m", "squash"]);
    git(&main, &["push", "origin", "HEAD:main"]);
    git(&main, &["fetch", "origin"]);
    let real = native_git();
    let mapped = root.join("mapped");
    let script = format!(
        "#!/bin/sh\nfor arg do\n  if [ \"$arg\" = merge-tree ]; then\n    exec python3 -c 'import mmap, os, sys\nmapping = mmap.mmap(-1, 1 << 30, flags=mmap.MAP_PRIVATE, prot={prot})\nopen(sys.argv[1], \"w\").close()\nos.execv(sys.argv[2], sys.argv[2:])' '{}' '{}' \"$@\"\n  fi\ndone\nexec '{}' \"$@\"\n",
        mapped.display(),
        real.display(),
        real.display()
    );
    let shim = root.join("git");
    write(&shim, &script);
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let old_path = std::env::var_os("PATH");
    prepend_path(&root, old_path.as_ref());
    let old_home = isolate_home(&root);
    let repo = inventory::scan_with_memo(&common(&main), &[], Arc::new(FinishedMemo::memory()));
    unsafe { std::env::set_var("PATH", old_path.unwrap_or_default()) };
    restore_home(old_home);
    let repo = repo.unwrap();
    let canonical = std::fs::canonicalize(&worktree).unwrap();
    let listed = repo
        .worktrees
        .iter()
        .find(|w| std::fs::canonicalize(&w.path).ok().as_deref() == Some(canonical.as_path()))
        .expect("listed");
    let facts = listed.facts.as_ref().expect("readable");
    let answer = facts.finished.clone();
    let reached = mapped.exists();
    std::fs::remove_dir_all(root).unwrap();
    // A shim that never ran merge-tree, or whose mapping failed, proves nothing.
    if prot.contains("PROT_WRITE") {
        assert!(!reached, "the 1 GiB writable mapping fit under the merge-tree memory cap");
    } else {
        assert!(reached, "merge-tree's 1 GiB address-space reservation was refused");
    }
    answer
}

/// A git whose runtime reserves address space it never uses (the Go git
/// wrapper on hosted runners, git-lfs) still answers: merge-tree's cap bounds
/// memory, not address space. It failed under the 768 MiB `RLIMIT_AS` at
/// random, by load, and the squash-merged branch read as unfinished.
#[test]
#[cfg(target_os = "linux")]
fn a_git_that_reserves_unused_address_space_still_gets_an_answer() {
    let _environment = ENV_LOCK.lock().unwrap();
    let answer = squash_answer_with_merge_tree_mapping("reserve", "mmap.PROT_READ");
    assert!(answer.as_deref().is_some_and(|f| f.contains("origin/main")), "{answer:?}");
}

/// The cap still holds memory a merge-tree writes: 1 GiB of writable memory
/// is refused, and the check is unknown, never a remembered answer.
#[test]
#[cfg(target_os = "linux")]
fn a_merge_tree_that_writes_past_the_memory_cap_has_no_answer() {
    let _environment = ENV_LOCK.lock().unwrap();
    let answer = squash_answer_with_merge_tree_mapping("write", "mmap.PROT_READ | mmap.PROT_WRITE");
    assert_eq!(answer, None);
}

/// A subprocess entry point for the perf harness. Keeping this as a separate
/// process proves the persisted answer is useful across daemon restarts rather
/// than only after dropping and rebuilding an Arc in one process.
#[test]
fn finished_scan_child() {
    let Some(mode) = std::env::var_os("CARE_BOUNDS_MODE") else { return };
    let common_dir = PathBuf::from(std::env::var_os("CARE_BOUNDS_COMMON").unwrap());
    let memo_path = PathBuf::from(std::env::var_os("CARE_BOUNDS_MEMO").unwrap());
    let result_path = PathBuf::from(std::env::var_os("CARE_BOUNDS_RESULT").unwrap());
    let started = Instant::now();
    let memo = if mode == "memory" {
        Arc::new(FinishedMemo::memory())
    } else {
        Arc::new(FinishedMemo::load(memo_path))
    };
    inventory::scan_with_memo(&common_dir, &[], Arc::clone(&memo)).unwrap();
    // Match pass::run, which flushes the final partial batch before returning.
    memo.flush();
    std::fs::write(result_path, started.elapsed().as_nanos().to_string()).unwrap();
}

/// Same-repository timing harness. Run with `--ignored --nocapture`; it emits
/// an uncached (memory-only) versus persisted-restart comparison. The shim
/// wraps only `merge-tree` with `/usr/bin/time -f %M`, recording peak RSS KB.
#[test]
#[ignore = "measurement harness; run explicitly on the hosted testbox"]
#[cfg(target_os = "linux")]
fn finished_scan_perf_harness() {
    let _environment = ENV_LOCK.lock().unwrap();
    assert!(Path::new("/usr/bin/time").is_file(), "GNU time is unavailable");
    const WORKTREES: usize = 16;
    let (root, main) = many_squashed_worktrees("perf", WORKTREES);
    let common_dir = common(&main);
    let (trace, rss, old_path) = trace_git_with_rss(&root);
    prepend_path(&root, old_path.as_ref());
    let old_home = isolate_home(&root);
    let memo = root.join("memo.json");
    let result = root.join("scan-ns");

    // This is the uncached baseline: a fresh process with the old-style
    // memory-only memo asks merge-tree for every worktree.
    clear_file(&trace);
    clear_file(&rss);
    run_scan_child("memory", &common_dir, &memo, &result);
    let before_ns = child_result(&result);
    let before_calls = trace_count(&trace, "merge-tree");
    let before_peak = peak_rss_kb(&rss).expect("merge-tree RSS measurement missing");
    assert_eq!(before_calls, WORKTREES, "uncached pass must check every pair");
    assert!(before_peak > 0, "merge-tree RSS was not measured");

    // Prime a durable memo, then clear all measurements before the simulated
    // restart. The after pass is a new process loading exactly those answers.
    run_scan_child("prime", &common_dir, &memo, &result);
    clear_file(&trace);
    clear_file(&rss);
    run_scan_child("persisted", &common_dir, &memo, &result);
    let after_ns = child_result(&result);
    let after_calls = trace_count(&trace, "merge-tree");
    let after_peak = peak_rss_kb(&rss).unwrap_or(0);
    assert_eq!(after_calls, 0, "persisted restart unexpectedly ran merge-tree");

    eprintln!(
        "worktree-care perf (simulated uncached restart; {WORKTREES} worktrees): before(memory-only) pass_ms={:.3} merge_tree_calls={before_calls} peak_rss_kb={before_peak}; after(persisted restart) pass_ms={:.3} merge_tree_calls={after_calls} peak_rss_kb={after_peak}",
        before_ns as f64 / 1_000_000.0,
        after_ns as f64 / 1_000_000.0,
    );
    unsafe { std::env::set_var("PATH", old_path.unwrap_or_default()) };
    restore_home(old_home);
    std::fs::remove_dir_all(root).unwrap();
}
