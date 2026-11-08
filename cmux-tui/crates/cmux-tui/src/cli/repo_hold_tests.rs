use super::*;
use cmux_git::sync_barrier::{Probe, probe};

fn words(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

fn checkout() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir(&repo).unwrap();
    std::fs::write(repo.join("AGENTS.md"), "head").unwrap();
    (dir, repo)
}

fn state(path: &Path) -> &'static str {
    match probe(path).unwrap() {
        Probe::Ready(_) => "ready",
        Probe::HeadReady => "head",
        Probe::Syncing => "syncing",
        Probe::Incomplete => "incomplete",
    }
}

#[test]
fn the_head_is_ready_while_the_command_runs_and_the_checkout_after_it() {
    let (_dir, repo) = checkout();
    let mut seen = "";
    let at_held = || seen = state(&repo.join("src/lib.rs"));
    assert_eq!(hold_run(&repo, &words(&["true"]), at_held), 0);
    assert_eq!(seen, "head");
    assert_eq!(state(&repo), "ready");
}

#[test]
fn a_failed_command_leaves_the_checkout_incomplete() {
    let (_dir, repo) = checkout();
    assert_eq!(hold_run(&repo, &words(&["false"]), || {}), 1);
    assert_eq!(state(&repo), "incomplete");
    assert_eq!(hold_run(&repo, &words(&["/nonexistent/cmux-fill"]), || {}), 1);
    assert_eq!(state(&repo), "incomplete");
}

#[test]
fn a_head_with_harness_start_settings_is_never_marked() {
    let (_dir, repo) = checkout();
    std::fs::create_dir(repo.join(".claude")).unwrap();
    std::fs::write(repo.join(".claude/settings.json"), r#"{"hooks":{}}"#).unwrap();
    assert!(!head_allowed(&repo));
    let mut seen = "";
    assert_eq!(hold_run(&repo, &words(&["true"]), || seen = state(&repo)), 0);
    assert_eq!(seen, "syncing", "a start waits for the whole checkout");
    assert_eq!(state(&repo), "ready");
}

#[test]
fn a_held_checkout_refuses_a_second_hold() {
    let (_dir, repo) = checkout();
    let mut inner = -1;
    let second = || inner = hold_run(&repo, &words(&["true"]), || {});
    let outer = hold_run(&repo, &words(&["true"]), second);
    assert_eq!((outer, inner), (0, 1));
}

#[test]
fn the_verbs_parse() {
    assert_eq!(run(&words(&["hold", "--help"])), 0);
    assert_eq!(run(&words(&["hold", "/tmp/x"])), 2);
    assert_eq!(run(&words(&["hold", "/tmp/x", "--"])), 2);
    assert_eq!(run(&words(&["fill"])), 2);
    let args = words(&["/tmp/x", "--", "sh", "-c", "true"]);
    let (dir, cmd) = parse(&args).unwrap();
    assert_eq!((dir, cmd.to_vec()), (PathBuf::from("/tmp/x"), words(&["sh", "-c", "true"])));
}
