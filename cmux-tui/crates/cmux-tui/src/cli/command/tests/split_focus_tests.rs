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
fn browser_pane_split_cli_uses_the_socket_contract() {
    let url = "https://example.com/";
    let with_url =
        protocol(&["pane", PANE, "split", "--right", "--fit", "--browser", "--url", url]);
    assert_eq!(with_url.params["browser"], true);
    assert_eq!(with_url.params["url"], url);
    assert_plan_matches_catalog(&with_url, "pane.split", &operation_catalog());

    let blank = protocol(&["pane", PANE, "split", "--down", "--browser"]);
    assert_eq!(blank.params["browser"], true);
    assert!(blank.params.get("url").is_none());
    for args in [
        vec!["--url", url],
        vec!["--browser", "--url", ""],
        vec!["--browser", "--cwd", "/tmp"],
        vec!["--browser", "--shell", "echo test"],
        vec!["--browser", "--", "echo", "test"],
    ] {
        let mut words = vec!["pane", PANE, "split"];
        words.extend(args);
        assert!(
            parse(&strings(&words), super::super::super::Surface::CmuxTui).is_err(),
            "{words:?}",
        );
    }
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
