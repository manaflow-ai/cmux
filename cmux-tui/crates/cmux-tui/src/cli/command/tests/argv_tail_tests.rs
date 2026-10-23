//! Text after `--` is a command only where the target runs one (workspace,
//! screen, pane and terminal-tab create, workspace and pane run, pane split,
//! the status/log/checklist text). Every other command refuses it, so no
//! command drops `htop` without a word.

use super::*;

fn refused(args: &[&str]) -> bool {
    parse(&strings(args), super::super::super::Surface::CmuxTui).is_err()
}

#[test]
fn argv_after_dashes_is_refused_where_nothing_runs_it() {
    for args in [
        &["workspace", "current", "rename", "--name", "x", "--", "htop"][..],
        &["tab", "create", "browser", "--url", "https://example.com", "--", "htop"],
        &["tab", "list", "--", "htop"],
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

#[test]
fn argv_after_dashes_runs_in_a_new_terminal_tab_pane_or_screen() {
    for (args, operation) in [
        (&["tab", "create", "terminal", "--", "htop", "-d", "5"][..], "tab.create_terminal"),
        (
            &["pane", "current", "tab", "create", "terminal", "--", "htop", "-d", "5"],
            "tab.create_terminal",
        ),
        (&["pane", "create", "--", "htop", "-d", "5"], "pane.create"),
        (&["screen", "create", "--", "htop", "-d", "5"], "screen.create"),
        (&["workspace", "current", "screen", "create", "--", "htop", "-d", "5"], "screen.create"),
        (
            &[
                "workspace",
                "current",
                "screen",
                "current",
                "pane",
                "create",
                "--",
                "htop",
                "-d",
                "5",
            ],
            "pane.create",
        ),
    ] {
        let plan = protocol(args);
        assert_eq!(plan.operation.name().unwrap(), operation, "{args:?}");
        assert_eq!(plan.params["argv"], json!(["htop", "-d", "5"]), "{args:?}");
    }
    let shell = protocol(&["tab", "create", "terminal", "--shell", "htop -d 5"]);
    assert_eq!(shell.params["shell"], "htop -d 5");
    assert!(refused(&["tab", "create", "terminal", "--shell", "x", "--", "htop"]));
    assert!(refused(&["pane", "create", "--", ""]));
}
