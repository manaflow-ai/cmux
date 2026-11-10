//! `pane run`, `tab create terminal|browser` and `browser open` send `focus`
//! only with `--focus` (W6-A): the daemon keeps the pane's selected tab for a
//! programmatic tab otherwise (cmux-tui-core
//! `resource_router/tab_create_focus_tests.rs`). `--no-focus` is accepted.

use serde_json::Value;

use super::super::{CommandPlan, parse as parse_command};

const PANE: &str = "pane_5555555555555555555555555555aaaa";

fn params(args: &[&str]) -> Value {
    let args = args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    match parse_command(&args, crate::cli::Surface::CmuxTui) {
        Ok(CommandPlan::Protocol(plan)) => plan.params,
        other => panic!("{args:?} is not a protocol request: {:?}", other.err()),
    }
}

#[test]
fn w6a_tab_creations_send_focus_only_with_the_flag() {
    let creations: [&[&str]; 4] = [
        &["pane", PANE, "run", "--", "htop"],
        &["tab", "create", "terminal", "--pane", PANE, "--", "htop"],
        &["tab", "create", "browser", "--pane", PANE, "--url", "https://example.com"],
        &["browser", "open", "https://example.com", "--pane", PANE],
    ];
    for words in creations {
        let plain = params(words);
        assert!(plain.get("focus").is_none(), "{words:?}: {plain}");
        let with = |flag: &str| {
            let at = words.iter().position(|word| *word == "--").unwrap_or(words.len());
            let mut args = words.to_vec();
            args.insert(at, flag);
            params(&args)
        };
        assert!(with("--no-focus").get("focus").is_none(), "{words:?}");
        assert_eq!(with("--focus")["focus"], true, "{words:?}");
    }
}
