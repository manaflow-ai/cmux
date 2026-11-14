//! `cmux pane <pane> move` parses to one `pane.move` request (W5-P). The
//! move itself (the kept pane id, the focus, one commit, the resolver) is
//! tested in the daemon: cmux-tui-core `resource_router/pane_move_tests.rs`.

use serde_json::{Value, json};

use super::super::{CommandPlan, RequestPlan, parse as parse_command};
use super::*;

const PANE_S: &str = "pane_5555555555555555555555555555aaaa";
const PANE_T: &str = "pane_7777777777777777777777777777bbbb";

fn parsed(args: &[&str]) -> Result<CommandPlan, UsageError> {
    let args = args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    parse_command(&args, crate::cli::Surface::CmuxTui)
}

fn protocol(args: &[&str]) -> RequestPlan {
    match parsed(args) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        other => panic!("{args:?} is not a protocol request: {:?}", other.err()),
    }
}

/// The `pane.move` fields of `pane <PANE_S> move <flags>`.
fn fields(flags: &[&str]) -> Value {
    let mut args = vec!["pane", PANE_S, "move"];
    args.extend_from_slice(flags);
    let plan = protocol(&args);
    assert_eq!(plan.operation.name().ok().as_deref(), Some("pane.move"), "{args:?}");
    let mut params = plan.params;
    for routing in ["machine", "session", "pane"] {
        params.as_object_mut().map(|params| params.remove(routing));
    }
    params
}

#[test]
fn w4j_pane_move_parses_one_destination_and_refuses_the_rest() {
    assert_eq!(
        fields(&["--to-pane", PANE_T, "--split", "right"]),
        json!({"destination_pane": PANE_T, "split": "right"})
    );
    assert_eq!(fields(&["--to-tab=tab_abcd"]), json!({"destination_tab": "tab_abcd"}));
    assert_eq!(
        fields(&["--to-workspace", "other", "--name", "logs"]),
        json!({"destination_workspace": "other", "new_screen": true, "name": "logs"})
    );
    for flag in ["--new-screen", "--new-tab"] {
        assert_eq!(fields(&[flag, "--focus"]), json!({"new_screen": true, "focus": true}));
    }
    assert_eq!(
        fields(&["--to-pane", PANE_T, "--index", "2"]),
        json!({"destination_pane": PANE_T, "index": 2})
    );
    // With --to-pane or --to-tab, --to-workspace and --to-screen are its parents.
    assert_eq!(
        fields(&["--to-tab", "build", "--to-workspace", "other", "--to-screen", "logs"]),
        json!({"destination_tab": "build", "destination_workspace": "other",
               "destination_screen": "logs"})
    );
    for bad in [
        &[][..],
        &["--new-screen", "--to-pane", PANE_T],
        &["--to-tab", "x", "--split", "right"],
        &["--to-pane", PANE_T, "--split", "sideways"],
        &["--to-pane", PANE_T, "--name", "logs"],
        &["--to-pane"],
        &["--new-screen", "--index", "2"],
        &["--to-pane", PANE_T, "--split", "left", "--index", "1"],
        &["--to-pane", PANE_T, "--index", "-1"],
        &["--new-screen", "--to-screen", "logs"],
        &["--to-workspace", "other", "--to-screen", "logs"],
    ] {
        let mut args = vec!["pane", PANE_S, "move"];
        args.extend_from_slice(bad);
        assert!(parsed(&args).is_err(), "accepted {bad:?}");
    }
    let flag_as_pane = parse("--new-screen", &mut Selectors::default(), &mut Flags::default());
    assert!(flag_as_pane.is_err(), "a flag is not a pane");
}

/// W5-P: the CLI no longer reads a snapshot and sends a `tab.move` per tab;
/// the whole move is one request, and the selectors go to the daemon as
/// typed (a name, a prefix, a bare id, `focused`), where the one resolver
/// reads them.
#[test]
fn w5p_pane_move_is_one_request_with_the_selectors_as_typed() {
    let plan = protocol(&["pane", "logs", "move", "--to-pane", "focused", "--split", "down"]);
    assert_eq!(plan.operation.name().ok().as_deref(), Some("pane.move"));
    assert_eq!(plan.params["pane"], "logs");
    assert_eq!(plan.params["destination_pane"], "focused");
    for selector in ["pane_7777", "7777777777777777777777777777bbbb", "name:build"] {
        assert_eq!(
            fields(&["--to-pane", selector]),
            json!({"destination_pane": selector}),
            "{selector}"
        );
    }
    // An id prefix needs 4 hex digits (W5-P review): a shorter one is a
    // usage error that says the minimum.
    for short in ["pane_77", "tab_ab"] {
        let flag = if short.starts_with("tab") { "--to-tab" } else { "--to-pane" };
        let error =
            parsed(&["pane", PANE_S, "move", flag, short]).err().map(|error| error.to_string());
        assert!(
            error.as_deref().is_some_and(|error| error.contains("at least 4 hex digits")),
            "{short}: {error:?}"
        );
    }
    // `pane move` alone moves the caller's pane.
    let own = protocol(&["pane", "move", "--new-screen"]);
    assert_eq!(own.params["pane"], "current");
    assert_eq!(own.params["new_screen"], true);
}
