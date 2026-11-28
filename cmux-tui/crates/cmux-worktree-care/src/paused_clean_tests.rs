use super::*;
use std::fs;
use std::time::{Duration, SystemTime};

fn sh(dir: &Path, args: &[&str]) {
    let ok = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .current_dir(dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(ok, "git {args:?}");
}

fn write(path: &Path, bytes: usize) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, vec![b'x'; bytes]).unwrap();
}

fn repo(ignore: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    sh(dir.path(), &["init", "-q"]);
    fs::write(dir.path().join(".gitignore"), ignore).unwrap();
    write(&dir.path().join("Cargo.toml"), 10);
    write(&dir.path().join("src/main.rs"), 20);
    sh(dir.path(), &["add", "-A"]);
    sh(dir.path(), &["commit", "-qm", "init"]);
    dir
}

fn options() -> Options {
    Options { now_ms: now_ms(), ..Options::default() }
}

fn files_before(dir: &Path) -> usize {
    walkdir_count(dir)
}

fn walkdir_count(dir: &Path) -> usize {
    let mut n = 0;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(p) = stack.pop() {
        n += 1;
        if let Ok(rd) = fs::read_dir(&p) {
            stack.extend(rd.flatten().map(|e| e.path()));
        }
    }
    n
}

#[test]
fn ignored_target_beside_cargo_toml_is_planned_and_nothing_is_deleted() {
    let dir = repo("target/\n");
    write(&dir.path().join("target/debug/big"), 4096);
    let before = files_before(dir.path());
    let plan = plan(dir.path(), &options());
    assert_eq!(plan.items.len(), 1, "{plan:?}");
    assert_eq!(plan.items[0].path, dir.path().join("target"));
    assert_eq!(plan.items[0].why, Why::BuildOutput);
    assert_eq!(plan.items[0].bytes, 4096);
    assert_eq!(plan.reclaim_bytes, 4096);
    assert!(plan.checkout_bytes >= 4096 + 30);
    assert_eq!(plan.build_output_skipped, None);
    assert!(!plan.partial);
    assert_eq!(files_before(dir.path()), before, "a plan deletes nothing");
    assert!(dir.path().join("target/debug/big").exists());
}

#[test]
fn untracked_not_ignored_output_is_the_persons() {
    let dir = repo("");
    write(&dir.path().join("target/debug/big"), 4096);
    let plan = plan(dir.path(), &options());
    assert!(plan.items.is_empty(), "{plan:?}");
}

#[test]
fn output_holding_a_tracked_file_stays() {
    let dir = repo("");
    write(&dir.path().join("target/keep.txt"), 5);
    sh(dir.path(), &["add", "target/keep.txt"]);
    sh(dir.path(), &["commit", "-qm", "keep"]);
    fs::write(dir.path().join(".gitignore"), "target/\n").unwrap();
    write(&dir.path().join("target/debug/big"), 4096);
    let plan = plan(dir.path(), &options());
    assert!(plan.items.is_empty(), "{plan:?}");
}

#[test]
fn output_without_its_marker_stays() {
    let dir = repo("node_modules/\n");
    write(&dir.path().join("node_modules/x/index.js"), 100);
    let plan = plan(dir.path(), &options());
    assert!(plan.items.is_empty(), "no package.json beside it: {plan:?}");
}

#[test]
fn nested_node_modules_and_pycache_are_planned() {
    let dir = repo("node_modules/\n__pycache__/\n");
    write(&dir.path().join("web/package.json"), 2);
    write(&dir.path().join("web/node_modules/x/index.js"), 100);
    write(&dir.path().join("py/__pycache__/a.pyc"), 50);
    let plan = plan(dir.path(), &options());
    let mut paths: Vec<_> = plan.items.iter().map(|i| i.path.clone()).collect();
    paths.sort();
    assert_eq!(paths, vec![dir.path().join("py/__pycache__"), dir.path().join("web/node_modules")]);
    assert_eq!(plan.reclaim_bytes, 150);
}

#[test]
fn outside_git_no_build_output_is_planned() {
    let dir = tempfile::tempdir().unwrap();
    if git(dir.path(), &["rev-parse", "--is-inside-work-tree"])
        .is_some_and(|b| b.trim_ascii() == b"true")
    {
        eprintln!("tempdir sits inside a git work tree; nothing to check here");
        return;
    }
    write(&dir.path().join("Cargo.toml"), 10);
    write(&dir.path().join("target/debug/big"), 4096);
    let plan = plan(dir.path(), &options());
    assert!(plan.items.is_empty(), "{plan:?}");
    assert_eq!(plan.build_output_skipped, Some("notGit"));
}

#[test]
fn caches_older_than_a_week_are_planned_fresh_ones_stay() {
    let dir = repo("");
    let cache = tempfile::tempdir().unwrap();
    write(&cache.path().join("old/blob"), 300);
    write(&cache.path().join("new/blob"), 200);
    let week_ago = SystemTime::now() - Duration::from_millis(WEEK_MS + 60_000);
    for p in ["old", "old/blob"] {
        fs::File::options()
            .write(true)
            .open(cache.path().join(p))
            .or_else(|_| fs::File::open(cache.path().join(p)))
            .unwrap()
            .set_modified(week_ago)
            .unwrap();
    }
    std::os::unix::fs::symlink(cache.path().join("old"), cache.path().join("link")).unwrap();
    let opts = Options { cache_roots: vec![cache.path().to_path_buf()], ..options() };
    let plan = plan(dir.path(), &opts);
    assert_eq!(plan.items.len(), 1, "{plan:?}");
    assert_eq!(plan.items[0].path, cache.path().join("old"));
    assert_eq!(plan.items[0].why, Why::StaleCache);
    assert_eq!(plan.items[0].bytes, 300);
    assert!(cache.path().join("old/blob").exists());
}

#[test]
fn limits_are_rfd_0144s() {
    let dir = repo("target/\n");
    let plan = plan(dir.path(), &options());
    assert_eq!(plan.included_bytes, 20 * 1024 * 1024 * 1024);
    assert_eq!(plan.cap_bytes, 64 * 1024 * 1024 * 1024);
    assert_eq!(plan.over_included_after, 0);
    let json = serde_json::to_value(&plan).unwrap();
    assert!(json.get("reclaimBytes").is_some() && json.get("overIncludedAfter").is_some());
}

#[test]
fn a_walk_past_its_bound_says_partial() {
    let dir = repo("target/\n");
    for i in 0..50 {
        write(&dir.path().join(format!("src/f{i}.rs")), 1);
    }
    let plan = plan(dir.path(), &Options { max_entries: 10, ..options() });
    assert!(plan.partial);
}

#[test]
fn duress_plan_of_a_20k_file_tree() {
    let dir = repo("target/\nnode_modules/\n");
    write(&dir.path().join("package.json"), 2);
    // 20,000 files: 8,000 in the checkout, 6,000 in target/, 6,000 in node_modules/.
    for i in 0..8_000 {
        write(&dir.path().join(format!("src/d{}/f{i}.rs", i % 80)), 64);
    }
    for i in 0..6_000 {
        write(&dir.path().join(format!("target/debug/deps/d{}/o{i}.o", i % 60)), 128);
        write(&dir.path().join(format!("node_modules/p{}/i{i}.js", i % 300)), 32);
    }
    let started = Instant::now();
    let plan = plan(dir.path(), &options());
    let took = started.elapsed();
    eprintln!(
        "RFD 0144 paused-disk clean plan: 20000 files, {} entries, {} items, {} reclaim bytes, {} ms",
        plan.entries,
        plan.items.len(),
        plan.reclaim_bytes,
        took.as_millis()
    );
    assert_eq!(plan.items.len(), 2, "{:?}", plan.items);
    assert_eq!(plan.reclaim_bytes, 6_000 * 128 + 6_000 * 32);
    assert!(!plan.partial);
    assert!(took < PLAN_BOUND, "plan took {took:?}, bound {PLAN_BOUND:?}");
}
