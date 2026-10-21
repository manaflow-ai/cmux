//! Text after `--` is a command only where the target runs one (workspace
//! create and run, pane split and run, the status/log/checklist text). Every
//! other command refuses it, so `tab create terminal -- htop` never opens a
//! plain shell and drops `htop` without a word.

use super::*;

fn refused(args: &[&str]) -> bool {
    parse(&strings(args), super::super::super::Surface::CmuxTui).is_err()
}

#[test]
fn argv_after_dashes_is_refused_where_nothing_runs_it() {
    for args in [
        &["tab", "create", "terminal", "--", "htop"][..],
        &["screen", "create", "--", "htop"],
        &["pane", "create", "--", "htop"],
        &["workspace", "current", "screen", "create", "--", "htop"],
        &["workspace", "current", "screen", "current", "pane", "create", "--", "htop"],
        &["workspace", "current", "rename", "--name", "x", "--", "htop"],
        &["pane", "current", "focus", "--", "htop"],
        &["terminal", "list", "--", "htop"],
        &["browser", "list", "--", "x"],
        &["notification", "list", "--", "x"],
        &["notify", "--title", "t", "--", "x"],
        &["git", "status", "--", "x"],
    ] {
        assert!(refused(args), "{args:?} dropped its -- arguments");
    }
}

#[test]
fn argv_after_dashes_still_runs_where_the_target_runs_it() {
    let create = protocol(&["workspace", "create", "--", "htop"]);
    assert_eq!(create.params["argv"], json!(["htop"]));
    let run = protocol(&[
        "workspace",
        "current",
        "screen",
        "current",
        "pane",
        "current",
        "run",
        "--",
        "htop",
    ]);
    assert_eq!(run.params["argv"], json!(["htop"]));
    let split = protocol(&["pane", "current", "split", "--", "htop"]);
    assert_eq!(split.params["argv"], json!(["htop"]));
    let status = protocol(&["workspace", "current", "status", "set", "k", "--", "two", "words"]);
    assert_eq!(status.params["text"], "two words");
}
