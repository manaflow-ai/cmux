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
