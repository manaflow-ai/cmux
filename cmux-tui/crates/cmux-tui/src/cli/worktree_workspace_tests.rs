use std::cell::RefCell;

use serde_json::{Value, json};

use super::super::command::RequestPlan;
use super::super::mcp::{CallFailure, FailureKind};
use super::super::terminal_talk::send::Daemon;
use super::super::wire::request_value;
use super::*;

const WORKSPACE: &str = "ws_0123456789abcdef0123456789abcdef";

/// Answers each operation from `answers`; records every request.
struct FakeDaemon {
    answers: Vec<(&'static str, Result<Value, Value>)>,
    sent: RefCell<Vec<Value>>,
}

impl FakeDaemon {
    fn new(answers: Vec<(&'static str, Result<Value, Value>)>) -> Self {
        Self { answers, sent: RefCell::new(Vec::new()) }
    }

    fn operations(&self) -> Vec<String> {
        self.sent
            .borrow()
            .iter()
            .map(|request| request["operation"].as_str().unwrap_or_default().to_owned())
            .collect()
    }

    fn params(&self, operation: &str) -> Value {
        self.sent
            .borrow()
            .iter()
            .find(|request| request["operation"] == operation)
            .map(|request| request["params"].clone())
            .unwrap_or_default()
    }

    fn key(&self, operation: &str) -> Value {
        self.sent
            .borrow()
            .iter()
            .find(|request| request["operation"] == operation)
            .map(|request| request["idempotency_key"].clone())
            .unwrap_or_default()
    }
}

impl Daemon for FakeDaemon {
    fn request(&self, _session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        let request = request_value(&plan).expect("a valid request");
        let operation = request["operation"].as_str().unwrap_or_default().to_owned();
        self.sent.borrow_mut().push(request);
        match self.answers.iter().find(|(name, _)| *name == operation) {
            Some((_, Ok(value))) => Ok(value.clone()),
            Some((_, Err(error))) => Err(CallFailure {
                kind: FailureKind::Rejected,
                error: error.clone(),
                idempotency_key: None,
            }),
            None => Ok(json!({})),
        }
    }
}

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn worktree_answer(root: &str) -> Value {
    json!({"value": {"root": root, "branch": "cmux/feature-x", "base": "main",
                     "base_commit": "abcdef12", "main_root": "/tmp/repo",
                     "setup": {"state": "none"}},
           "generation": "g", "revision": "1", "replayed": false})
}

fn created_answer() -> Value {
    json!({"value": {"kind": "terminal", "workspace_id": WORKSPACE,
                     "screen_id": "screen_1", "pane_id": "pane_1", "tab_id": "tab_1",
                     "terminal_id": "term_1"},
           "generation": "g", "revision": "2", "replayed": false})
}

#[test]
fn read_run_worktree_create_parses_its_options_and_keeps_the_workspace_options() {
    let request = parse_create(&strings(&[
        "--worktree",
        "feature-x",
        "--repo",
        "/cmux-test-no-such-dir/repo",
        "--focus",
    ]))
    .expect("parsed");
    assert_eq!(request.name, "feature-x");
    assert_eq!(request.repo.as_deref(), Some("/cmux-test-no-such-dir/repo"));
    assert_eq!(
        request.workspace_words,
        strings(&["workspace", "create", "--name", "feature-x", "--focus"])
    );
    let named =
        parse_create(&strings(&["--worktree=x", "--name", "Mine", "--", "htop"])).expect("parsed");
    assert_eq!(
        named.workspace_words,
        strings(&["workspace", "create", "--name", "Mine", "--", "htop"])
    );
    assert!(parse_create(&strings(&["--worktree"])).is_err());
    assert!(parse_create(&strings(&["--worktree", "x", "--cwd", "/tmp"])).is_err());
    assert!(parse_create(&strings(&["--worktree", "x", "--empty"])).is_err());
}

#[test]
fn read_run_worktree_create_makes_the_worktree_then_a_workspace_in_it_and_returns_both() {
    let root = std::env::temp_dir().join("cmux-worktree-workspace-test");
    std::fs::create_dir_all(&root).expect("temp folder");
    let root_text = root.to_string_lossy().into_owned();
    let daemon = FakeDaemon::new(vec![
        ("git.worktree.create", Ok(worktree_answer(&root_text))),
        ("workspace.create", Ok(created_answer())),
    ]);
    let request = parse_create(&strings(&[
        "--worktree",
        "feature-x",
        "--repo",
        "/cmux-test-no-such-dir/repo",
    ]))
    .expect("parsed");
    let result = create(&daemon, &request, "key-1").expect("created");
    assert_eq!(
        daemon.operations(),
        ["git.worktree.create", "workspace.create", "workspace.agent_folder.set"]
    );
    let made = daemon.params("git.worktree.create");
    assert_eq!(made["path"], "/cmux-test-no-such-dir/repo");
    assert_eq!(made["name"], "feature-x");
    let workspace = daemon.params("workspace.create");
    assert_eq!(workspace["cwd"], root_text);
    assert_eq!(workspace["name"], "feature-x");
    let folder = daemon.params("workspace.agent_folder.set");
    assert_eq!(folder["workspace"], WORKSPACE);
    let canonical = std::fs::canonicalize(&root).unwrap();
    assert_eq!(folder["path"], canonical.to_string_lossy().as_ref());
    // The workspace create result, plus the worktree with its folder.
    assert_eq!(result["value"]["workspace_id"], WORKSPACE);
    assert_eq!(result["value"]["terminal_id"], "term_1");
    assert_eq!(result["worktree"]["root"], root_text);
    assert_eq!(result["worktree"]["branch"], "cmux/feature-x");
    assert_eq!(result["worktree"]["workspace_folder"], true);
    // A retry with the same command key sends the same step keys.
    let again = FakeDaemon::new(vec![
        ("git.worktree.create", Ok(worktree_answer(&root_text))),
        ("workspace.create", Ok(created_answer())),
    ]);
    create(&again, &request, "key-1").expect("created");
    for operation in ["git.worktree.create", "workspace.create", "workspace.agent_folder.set"] {
        assert_eq!(again.key(operation), daemon.key(operation), "{operation}");
    }
    assert_ne!(daemon.key("git.worktree.create"), daemon.key("workspace.create"));
}

#[test]
fn read_run_worktree_create_failure_of_the_workspace_names_the_worktree_it_made() {
    let daemon = FakeDaemon::new(vec![
        ("git.worktree.create", Ok(worktree_answer("/tmp/wt"))),
        ("workspace.create", Err(json!({"code": "operation.failed", "message": "no"}))),
    ]);
    let request = parse_create(&strings(&["--worktree", "x"])).expect("parsed");
    let failure = create(&daemon, &request, "key-2").expect_err("failed");
    assert_eq!(failure.error["details"]["step"], "workspace");
    assert_eq!(failure.error["details"]["idempotency_key"], "key-2");
    assert_eq!(failure.error["details"]["made"]["worktree"]["root"], "/tmp/wt");
}

#[test]
fn read_run_worktree_close_removes_the_recorded_worktree_then_closes_the_workspace() {
    let shown = json!({"id": WORKSPACE, "name": "feature-x",
                       "extra": {"agent_folder": "/Users/me/.cmux/worktrees.noindex/repo/x"}});
    let removed = json!({"value": {"root": "/Users/me/.cmux/worktrees.noindex/repo/x",
                                   "main_root": "/tmp/repo", "branch": "cmux/x",
                                   "branch_deleted": true}});
    let daemon = FakeDaemon::new(vec![
        ("workspace.get", Ok(shown)),
        ("git.worktree.remove", Ok(removed)),
        ("workspace.close", Ok(json!({"value": {}, "revision": "3"}))),
    ]);
    let request =
        parse_close("feature-x", &strings(&["--remove-worktree", "--discard"])).expect("parsed");
    let result = close(&daemon, &request, "key-3").expect("closed");
    assert_eq!(daemon.operations(), ["workspace.get", "git.worktree.remove", "workspace.close"]);
    let remove = daemon.params("git.worktree.remove");
    assert_eq!(remove["path"], "/Users/me/.cmux/worktrees.noindex/repo/x");
    assert_eq!(remove["discard"], true);
    assert_eq!(daemon.params("workspace.close")["workspace"], WORKSPACE);
    assert_eq!(result["worktree"]["branch_deleted"], true);
}

#[test]
fn read_run_worktree_close_refused_by_git_closes_nothing() {
    let shown = json!({"id": WORKSPACE, "extra": {"agent_folder": "/w"}});
    let daemon = FakeDaemon::new(vec![
        ("workspace.get", Ok(shown)),
        (
            "git.worktree.remove",
            Err(json!({"code": "operation.failed", "details": {"reason": "uncommitted_changes"}})),
        ),
    ]);
    let request = parse_close(WORKSPACE, &strings(&["--remove-worktree"])).expect("parsed");
    let failure = close(&daemon, &request, "key-4").expect_err("refused");
    assert_eq!(failure.error["details"]["reason"], "uncommitted_changes");
    assert_eq!(failure.error["details"]["step"], "remove");
    assert!(!daemon.operations().contains(&"workspace.close".to_owned()));
}

#[test]
fn read_run_worktree_close_without_an_agent_folder_removes_the_terminals_worktree() {
    // An agent's CLI cannot set the agent folder: the close names the
    // workspace, whose current terminal's folder names the worktree.
    let daemon = FakeDaemon::new(vec![
        ("workspace.get", Ok(json!({"id": WORKSPACE, "extra": {}}))),
        ("git.worktree.remove", Ok(json!({"value": {"root": "/w", "branch_deleted": true}}))),
    ]);
    let request = parse_close("feature-x", &strings(&["--remove-worktree"])).expect("parsed");
    let result = close(&daemon, &request, "key-5").expect("closed");
    assert_eq!(daemon.operations(), ["workspace.get", "git.worktree.remove", "workspace.close"]);
    let remove = daemon.params("git.worktree.remove");
    assert_eq!(remove["workspace"], WORKSPACE);
    assert!(remove.get("path").is_none(), "{remove}");
    assert_eq!(daemon.params("workspace.close")["workspace"], WORKSPACE);
    assert_eq!(result["worktree"]["root"], "/w");
    assert!(parse_close("current", &strings(&["--remove-worktree"])).is_err());
    assert!(parse_close(WORKSPACE, &strings(&["--remove-worktree", "--others"])).is_err());
}
