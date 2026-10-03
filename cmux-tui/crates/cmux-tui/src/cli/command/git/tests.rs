use serde_json::{Value, json};

use super::super::{CommandPlan, parse};
use crate::cli::Surface;

const WS: &str = "ws_00000000000000000000000000000004";
const TERM: &str = "term_00000000000000000000000000000008";
const SCREEN: &str = "screen_00000000000000000000000000000005";

/// Operation name and params without the routing defaults.
fn sent(args: &[&str]) -> (String, Value) {
    let args = args.iter().map(|value| (*value).to_string()).collect::<Vec<_>>();
    let plan = match parse(&args, Surface::Cmux) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        Ok(_) => panic!("{args:?} is not a protocol plan"),
        Err(error) => panic!("{args:?}: {error}"),
    };
    let mut params = plan.params.as_object().unwrap().clone();
    assert_eq!(params.remove("machine"), Some(json!("current")), "{args:?}");
    assert_eq!(params.remove("session"), Some(json!("current")), "{args:?}");
    (plan.operation.name().unwrap(), Value::Object(params))
}

fn rejects(args: &[&str]) -> String {
    let args = args.iter().map(|value| (*value).to_string()).collect::<Vec<_>>();
    match parse(&args, Surface::Cmux) {
        Err(error) => error.0,
        Ok(_) => panic!("accepted {args:?}"),
    }
}

#[test]
fn git_reads_the_current_directory_unless_given_a_target() {
    let here = std::env::current_dir().unwrap().to_string_lossy().into_owned();
    assert_eq!(sent(&["git", "status"]), ("git.status".into(), json!({"path": here})));
    assert_eq!(
        sent(&["git", "diff"]),
        ("git.diff".into(), json!({"path": here, "scope": "uncommitted"}))
    );
    let nested = std::env::current_dir().unwrap().join("src").to_string_lossy().into_owned();
    assert_eq!(
        sent(&["git", "status", "--path", "src"]),
        ("git.status".into(), json!({"path": nested}))
    );
    assert_eq!(
        sent(&["git", "status", "--terminal", TERM]),
        ("git.status".into(), json!({"terminal": TERM}))
    );
    assert_eq!(
        sent(&["git", "status", "--screen", SCREEN]),
        ("git.status".into(), json!({"screen": SCREEN}))
    );
    assert_eq!(
        sent(&["git", "diff", "--workspace", WS, "--scope", "branch"]),
        ("git.diff".into(), json!({"workspace": WS, "scope": "branch"}))
    );
}

#[test]
fn git_diff_takes_bounds_a_patch_and_paths() {
    assert_eq!(
        sent(&[
            "git",
            "diff",
            "--path",
            "/repo",
            "--patch",
            "--max-patch-bytes",
            "4096",
            "--max-files",
            "20",
            "src",
            "README.md",
        ]),
        (
            "git.diff".into(),
            json!({
                "path": "/repo",
                "scope": "uncommitted",
                "include_patch": true,
                "max_patch_bytes": 4096,
                "max_files": 20,
                "paths": ["src", "README.md"],
            })
        )
    );
}

#[test]
fn git_refuses_two_targets_an_unknown_scope_and_bad_bounds() {
    assert!(
        rejects(&["git", "status", "--path", "/repo", "--terminal", TERM]).contains("at most one")
    );
    assert!(rejects(&["git", "diff", "--scope", "lastTurn"]).contains("--scope"));
    assert!(rejects(&["git", "diff", "--max-files", "0"]).contains("--max-files"));
    assert!(
        rejects(&["git", "diff", "--max-patch-bytes", "9999999"]).contains("--max-patch-bytes")
    );
    assert!(rejects(&["git", "log"]).contains("git action"));
    // Status takes no paths.
    assert!(rejects(&["git", "status", "src"]).contains("git action"));
}

#[test]
fn git_checkpoint_create_sends_selections_exclusions_and_bounds() {
    let here = std::env::current_dir().unwrap().to_string_lossy().into_owned();
    assert_eq!(
        sent(&["git", "checkpoint", "create"]),
        ("git.checkpoint.create".into(), json!({"path": here}))
    );
    assert_eq!(
        sent(&[
            "git",
            "checkpoint",
            "create",
            "--terminal",
            TERM,
            "--exclude",
            "target,.env.local",
            "--reason",
            "handoff",
            "--max-files",
            "10",
            "notes.md",
            "dir with space/a.txt",
        ]),
        (
            "git.checkpoint.create".into(),
            json!({
                "terminal": TERM,
                "include_untracked": ["notes.md", "dir with space/a.txt"],
                "exclude_paths": ["target", ".env.local"],
                "reason": "handoff",
                "limits": {"max_files": 10},
            })
        )
    );
    assert_eq!(
        sent(&["git", "checkpoint", "create", "--path", "/repo", "--untracked", "eligible"]),
        ("git.checkpoint.create".into(), json!({"path": "/repo", "include_untracked": "eligible"}))
    );
    assert!(
        rejects(&["git", "checkpoint", "create", "--untracked", "all"]).contains("--untracked")
    );
    assert!(
        rejects(&["git", "checkpoint", "create", "--untracked", "eligible", "a.txt"])
            .contains("not both")
    );
    assert!(rejects(&["git", "checkpoint", "create", "--reason", "later"]).contains("--reason"));
    assert!(rejects(&["git", "checkpoint", "create", "--max-bytes", "0"]).contains("--max-bytes"));
}

#[test]
fn git_checkpoint_reads_and_pins_name_one_checkpoint() {
    let id = "ckpt_00000000000000000000000000000001";
    assert_eq!(
        sent(&["git", "checkpoint", "get", id, "--path", "/repo"]),
        ("git.checkpoint.get".into(), json!({"path": "/repo", "checkpoint_id": id}))
    );
    assert_eq!(
        sent(&["git", "checkpoint", "get", "--path", "/repo", "--key", "k1"]),
        ("git.checkpoint.get".into(), json!({"path": "/repo", "idempotency_key": "k1"}))
    );
    assert!(rejects(&["git", "checkpoint", "get", id, "--key", "k1"]).contains("not both"));
    assert!(rejects(&["git", "checkpoint", "get"]).contains("--key"));
    assert_eq!(
        sent(&["git", "checkpoint", "list", "--path", "/repo", "--limit", "5", "--candidates"]),
        (
            "git.checkpoint.list".into(),
            json!({"path": "/repo", "limit": 5, "include_candidates": true})
        )
    );
    assert_eq!(
        sent(&[
            "git",
            "checkpoint",
            "pin",
            id,
            "--path",
            "/repo",
            "--pin",
            "user:a",
            "--reason",
            "r"
        ]),
        (
            "git.checkpoint.pin".into(),
            json!({"path": "/repo", "checkpoint_id": id, "pin_id": "user:a", "reason": "r"})
        )
    );
    assert!(rejects(&["git", "checkpoint", "pin", id, "--pin", "user:a"]).contains("--reason"));
    assert_eq!(
        sent(&["git", "checkpoint", "unpin", id, "--path", "/repo", "--pin", "user:a"]),
        (
            "git.checkpoint.unpin".into(),
            json!({"path": "/repo", "checkpoint_id": id, "pin_id": "user:a"})
        )
    );
    assert!(rejects(&["git", "checkpoint", "rewind", id]).contains("git checkpoint action"));
}

#[test]
fn git_files_joins_the_query_and_takes_a_limit() {
    let here = std::env::current_dir().unwrap().to_string_lossy().into_owned();
    assert_eq!(
        sent(&["git", "files", "app", "tsx"]),
        ("git.files.search".into(), json!({"path": here, "query": "app tsx"}))
    );
    assert_eq!(
        sent(&["git", "files", "--terminal", TERM, "--limit", "200", "main"]),
        ("git.files.search".into(), json!({"terminal": TERM, "query": "main", "limit": 200}))
    );
    assert!(rejects(&["git", "files"]).contains("git action"), "a query is required");
    assert!(rejects(&["git", "files", "--limit", "201", "x"]).contains("--limit"));
}

#[test]
fn git_commit_names_a_message_and_what_to_stage() {
    assert_eq!(
        sent(&["git", "commit", "--path", "/repo", "--message", "Fix", "a.rs", "b/"]),
        ("git.commit".into(), json!({"path": "/repo", "message": "Fix", "paths": ["a.rs", "b/"]}))
    );
    assert_eq!(
        sent(&[
            "git",
            "commit",
            "--path",
            "/repo",
            "--message",
            "Fix",
            "--all",
            "--include-untracked",
            "--no-verify",
            "--expected-head",
            "abc1234",
        ]),
        (
            "git.commit".into(),
            json!({
                "path": "/repo",
                "message": "Fix",
                "all": true,
                "include_untracked": true,
                "no_verify": true,
                "expected_head": "abc1234",
            })
        )
    );
    assert!(rejects(&["git", "commit", "--path", "/repo"]).contains("--message"));
    assert!(rejects(&["git", "commit", "--message", "m", "--all", "a.rs"]).contains("not both"));
    assert!(rejects(&["git", "commit", "--message", "m", "--include-untracked"]).contains("--all"));
}

#[test]
fn git_push_names_a_remote_branch_and_upstream_choice() {
    assert_eq!(
        sent(&["git", "push", "--path", "/repo"]),
        ("git.push".into(), json!({"path": "/repo"}))
    );
    assert_eq!(
        sent(&["git", "push", "--path", "/repo", "--remote", "fork", "--set-upstream"]),
        ("git.push".into(), json!({"path": "/repo", "remote": "fork", "set_upstream": true}))
    );
    assert!(
        rejects(&["git", "push", "--set-upstream", "--no-set-upstream"]).contains("not both")
    );
    assert!(rejects(&["git", "push", "--force"]).contains("--force"));
}
