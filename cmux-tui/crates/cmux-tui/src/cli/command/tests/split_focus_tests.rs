//! `pane split` keeps the caller's focus unless `--focus` is given, and takes
//! the command its new pane runs (`-- argv` or `--shell`), so an agent never
//! leaves an empty shell tab behind (tests/agent-evals/RESULTS.md, failure
//! modes 1 and 3).

use super::*;

const PANE: &str = "pane_00000000000000000000000000000006";

#[test]
fn pane_split_sends_focus_only_when_asked() {
    let catalog = operation_catalog();
    let plain = protocol(&["pane", PANE, "split", "--right"]);
    assert_eq!(operation(&plain), "pane.split");
    assert_eq!(plain.params.get("focus"), None, "{:?}", plain.params);

    let focused = protocol(&["pane", PANE, "split", "--down", "--focus"]);
    assert_eq!(focused.params["focus"], true);
    assert_plan_matches_catalog(&focused, "pane.split", &catalog);
}

#[test]
fn pane_split_takes_the_new_panes_command() {
    let catalog = operation_catalog();
    let argv = protocol(&["pane", PANE, "split", "--right", "--", "npm", "run", "dev"]);
    assert_eq!(argv.params["argv"], json!(["npm", "run", "dev"]));
    assert_plan_matches_catalog(&argv, "pane.split", &catalog);

    let shell = protocol(&["pane", PANE, "split", "--right", "--shell", "make watch"]);
    assert_eq!(shell.params["shell"], "make watch");
    assert_plan_matches_catalog(&shell, "pane.split", &catalog);

    let both = parse(
        &strings(&["pane", PANE, "split", "--shell", "make", "--", "make"]),
        super::super::super::Surface::CmuxTui,
    );
    assert!(both.is_err(), "argv and --shell together must be refused");
}

#[test]
fn workspace_create_sends_focus_only_when_asked() {
    let catalog = operation_catalog();
    let plain = protocol(&["workspace", "create", "--name", "bg"]);
    assert_eq!(operation(&plain), "workspace.create");
    assert_eq!(plain.params.get("focus"), None, "{:?}", plain.params);
    let focused = protocol(&["workspace", "create", "--name", "shown", "--focus"]);
    assert_eq!(focused.params["focus"], true);
    assert_plan_matches_catalog(&focused, "workspace.create", &catalog);
}
