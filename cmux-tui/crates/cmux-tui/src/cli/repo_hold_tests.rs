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

/// `state` once it reads `want`, or what it reads after 5 s. Other tests in this process spawn
/// children, and a forked child holds copies of this process's lock descriptors until it execs,
/// so a lock this process let go of can read held for a moment. A release can lag, a take never.
fn settled(path: &Path, want: &str) -> &'static str {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let now = state(path);
        if now == want || std::time::Instant::now() >= deadline {
            return now;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}

#[test]
fn the_head_is_ready_while_the_command_runs_and_the_checkout_after_it() {
    let (_dir, repo) = checkout();
    let mut seen = "";
    let at_held = || seen = settled(&repo.join("src/lib.rs"), "head");
    assert_eq!(hold_run(&repo, &words(&["true"]), at_held), 0);
    assert_eq!(seen, "head");
    assert_eq!(settled(&repo, "ready"), "ready");
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
    assert_eq!(settled(&repo, "ready"), "ready");
}

/// A project `.mcp.json` starts its servers when the harness starts, outside the tool gate,
/// so a head that has one is never marked: they would run on a partial checkout.
#[test]
fn a_head_with_project_mcp_servers_is_never_marked() {
    let (_dir, repo) = checkout();
    std::fs::write(repo.join(".mcp.json"), r#"{"mcpServers":{}}"#).unwrap();
    assert!(!head_allowed(&repo));
}

/// Review F1 (cmux#38099, c64fa326f5b): a `CLAUDE.md` linked into a folder the head left out
/// would start a harness with no instructions, so such a head is never marked.
#[test]
fn a_head_whose_instructions_link_out_of_it_is_never_marked() {
    let (_dir, repo) = checkout();
    std::os::unix::fs::symlink("docs/instructions.md", repo.join("CLAUDE.md")).unwrap();
    assert!(!head_allowed(&repo));
    std::fs::create_dir(repo.join("docs")).unwrap();
    std::fs::write(repo.join("docs/instructions.md"), "x").unwrap();
    assert!(head_allowed(&repo), "a link whose target is there is fine");
    std::fs::create_dir_all(repo.join(".claude/agents")).unwrap();
    std::os::unix::fs::symlink("../../shared/a.md", repo.join(".claude/agents/a.md")).unwrap();
    assert!(!head_allowed(&repo), "nor one in a harness folder");
}

#[test]
fn a_held_checkout_refuses_a_second_hold() {
    let (_dir, repo) = checkout();
    let mut inner = -1;
    let second = || inner = hold_run(&repo, &words(&["true"]), || {});
    let outer = hold_run(&repo, &words(&["true"]), second);
    assert_eq!((outer, inner), (0, 1));
}

/// The machine-config applier's wait: open once the hold's command succeeds, refused after one
/// that failed, and a wait that runs out says so.
#[test]
fn a_wait_ends_with_the_barrier() {
    let (_dir, repo) = checkout();
    assert_eq!(wait(&repo, std::time::Duration::ZERO), 0, "no barrier: nothing to wait for");
    let mut during = -1;
    let at_held = || during = wait(&repo, std::time::Duration::from_millis(50));
    assert_eq!(hold_run(&repo, &words(&["true"]), at_held), 0);
    assert_eq!(during, 124);
    assert_eq!(wait(&repo, std::time::Duration::from_secs(5)), 0);
    assert_eq!(hold_run(&repo, &words(&["false"]), || {}), 1);
    assert_eq!(wait(&repo, std::time::Duration::from_secs(5)), 1);
}

#[test]
fn the_verbs_parse() {
    assert_eq!(run(&words(&["hold", "--help"])), 0);
    assert_eq!(run(&words(&["hold", "/tmp/x"])), 2);
    assert_eq!(run(&words(&["hold", "/tmp/x", "--"])), 2);
    assert_eq!(run(&words(&["fill"])), 2);
    assert_eq!(run(&words(&["wait", "/tmp/x"])), 2);
    assert_eq!(run(&words(&["wait", "/tmp/x", "soon"])), 2);
    let args = words(&["/tmp/x", "--", "sh", "-c", "true"]);
    let (dir, cmd) = parse(&args).unwrap();
    assert_eq!((dir, cmd.to_vec()), (PathBuf::from("/tmp/x"), words(&["sh", "-c", "true"])));
}
