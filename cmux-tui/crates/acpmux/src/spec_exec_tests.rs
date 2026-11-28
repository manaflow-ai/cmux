use super::*;

#[test]
fn only_a_lone_check_counts_as_one() {
    for yes in [
        "cargo check -p acpmux",
        "cargo clippy -p acpmux --all-targets",
        "cd cmux-tui && cargo check -p acpmux 2>&1 | tail -n 40",
        "cargo check --message-format short 2>&1 | grep error | head",
        "npx tsc --noEmit -p .",
        "pnpm exec tsc --noEmit",
    ] {
        assert!(is_check(yes), "{yes}");
    }
    for no in [
        "cargo test -p acpmux",
        "cargo check > out.txt",
        "cargo check; rm -rf target",
        "cargo check && cargo test",
        "cd a b && cargo check",
        "cargo check | tee log",
        "cargo check $(echo -p x)",
        "tsc -p .",
        "cargo check &",
        "echo 'cargo check'",
        "",
    ] {
        assert!(!is_check(no), "{no}");
    }
}

#[test]
fn the_rewrite_wraps_a_check_and_nothing_else() {
    assert_eq!(
        rewrite("cargo check -p x ", "'acpmux' 'spec-serve' '--'").as_deref(),
        Some("'acpmux' 'spec-serve' '--' 'cargo check -p x'")
    );
    assert_eq!(rewrite("cargo test", "'acpmux' 'spec-serve' '--'"), None);
}

#[test]
fn the_setting_is_off_unless_true_and_the_switch_wins() {
    let on = json!({"agents": {"harnessMagic": {"speculative": {"enabled": true}}}});
    assert!(!enabled_with(None, None));
    assert!(enabled_with(Some(&on), None));
    assert!(!enabled_with(Some(&on), Some("0")));
    assert!(enabled_with(None, Some("1")));
}

fn git_tree() -> tempfile::TempDir {
    let t = tempfile::tempdir().unwrap();
    let run = |args: &[&str]| {
        let ok = Command::new("git")
            .args(args)
            .current_dir(t.path())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success();
        assert!(ok, "git {args:?}");
    };
    run(&["init", "-q"]);
    run(&["-c", "user.email=a@b", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "0"]);
    std::fs::write(t.path().join("a.rs"), "fn a() {}\n").unwrap();
    t
}

/// A stand-in `cargo`, found first on the run's `PATH`: it sleeps, prints the file and exits 3,
/// so the kept run's time and exit code are real.
fn fake_cargo(bin: &Path, sleep: &str) {
    let script = bin.join("cargo");
    std::fs::write(&script, format!("#!/bin/sh\nsleep {sleep}\ncat a.rs\nexit 3\n")).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn a_kept_run_is_served_until_the_tree_moves() {
    let tree = git_tree();
    let store = tempfile::tempdir().unwrap();
    let bin = tempfile::tempdir().unwrap();
    fake_cargo(bin.path(), "1");
    let path = format!("{}:{}", bin.path().display(), std::env::var("PATH").unwrap_or_default());
    let command = "cargo check -p a";

    let t = Instant::now();
    let kept = prerun_with_path(
        store.path(),
        tree.path(),
        command,
        Duration::from_secs(20),
        Some(path.as_ref()),
    )
    .unwrap();
    let cold = t.elapsed();
    assert_eq!(kept.exit, 3);
    assert_eq!(kept.output, "fn a() {}\n");

    let t = Instant::now();
    let served = serve_from(store.path(), tree.path(), command).unwrap();
    let warm = t.elapsed();
    assert_eq!(served, kept);
    eprintln!("speculative: cold run {cold:?}, served {warm:?}");
    assert!(warm < cold);

    // A second edit to the same changed file moves the fingerprint: not served.
    std::thread::sleep(Duration::from_millis(20));
    std::fs::write(tree.path().join("a.rs"), "fn a() { 1; }\n").unwrap();
    assert_eq!(serve_from(store.path(), tree.path(), command), None);
    // Another folder or another command has no record.
    assert_eq!(serve_from(store.path(), tree.path(), "cargo check -p b"), None);
}

#[test]
fn no_git_means_nothing_kept() {
    let plain = tempfile::tempdir().unwrap();
    let store = tempfile::tempdir().unwrap();
    assert_eq!(fingerprint(plain.path()), None);
    assert_eq!(prerun_in(store.path(), plain.path(), "cargo check", Duration::from_secs(5)), None);
}
