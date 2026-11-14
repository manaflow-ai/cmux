use super::super::{RequestPlan, ResponseView, parse as parse_command};
use super::*;

const TERMINAL: &str = "term_55555555555555555555555555555555";

fn parsed(args: &[&str]) -> Result<CommandPlan, UsageError> {
    let args = args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    parse_command(&args, crate::cli::Surface::CmuxTui)
}

fn protocol(args: &[&str]) -> RequestPlan {
    match parsed(args) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        _ => panic!("{args:?} is not a protocol request"),
    }
}

#[test]
fn agent_list_ranks_by_needs_me_by_default() {
    let list = protocol(&["agent", "list"]);
    assert_eq!(list.operation.name().unwrap(), "agent.list");
    assert_eq!(list.params.get("state"), None);
    assert_eq!(list.view, ResponseView::AgentRoster(AgentRosterView::default()));
}

#[test]
fn agent_list_takes_sort_limit_and_needs_me() {
    for (sort, expected) in
        [("needs-me", AgentSort::NeedsMe), ("recent", AgentSort::Recent), ("none", AgentSort::None)]
    {
        let list = protocol(&["agent", "list", "--sort", sort, "--limit", "5"]);
        assert_eq!(
            list.view,
            ResponseView::AgentRoster(AgentRosterView {
                sort: expected,
                limit: Some(5),
                counts: false,
                status: None,
            })
        );
    }
    let counts = protocol(&["agent", "list", "--counts"]);
    assert_eq!(
        counts.view,
        ResponseView::AgentRoster(AgentRosterView { counts: true, ..Default::default() })
    );
    // --needs-me is the daemon's `state: blocked` filter.
    let needs_me = protocol(&["agent", "list", "--needs-me", "--terminal", TERMINAL]);
    assert_eq!(needs_me.params["state"], "blocked");
    assert_eq!(needs_me.params["terminal_id"], TERMINAL);
    // W5-P: any other terminal selector is the `terminal` field the
    // daemon resolves: a raw `run` reply's host id, a prefix, a name.
    for selector in ["00000000000040008000000000000001", "term_5555", "pane_abcd", "alpha"] {
        let list = protocol(&["agent", "list", "--terminal", selector]);
        assert_eq!(list.params["terminal"], selector);
        assert_eq!(list.params.get("terminal_id"), None);
    }
    // An id prefix needs 4 hex digits: a shorter one is a usage error.
    let short = parsed(&["agent", "list", "--terminal", "pane_ab"]).err().map(|e| e.0);
    assert!(short.as_deref().is_some_and(|e| e.contains("at least 4 hex digits")), "{short:?}");
    let both = protocol(&["agent", "list", "--needs-me", "--state", "blocked"]);
    assert_eq!(both.params["state"], "blocked");
    let ResponseView::AgentRoster(view) = needs_me.view else { panic!("a roster") };
    assert_eq!(view.status, Some("blocked"));
    for invalid in [
        &["agent", "list", "--needs-me", "--state", "working"][..],
        &["agent", "list", "--state", "busy"],
        &["agent", "list", "--sort", "oldest"],
        &["agent", "list", "--limit", "0"],
        &["agent", "list", "--limit", "many"],
    ] {
        assert!(parsed(invalid).is_err(), "accepted {invalid:?}");
    }
}

/// `--state` takes the shared status words: `done` and `idle` both ask
/// the daemon for `idle` (the unread marker tells them apart), `ended`
/// asks for the daemon's `done` (a session that ended).
#[test]
fn w4j_agent_list_state_takes_the_shared_status_words() {
    for (status, daemon) in [
        ("done", "idle"),
        ("idle", "idle"),
        ("ended", "done"),
        ("working", "working"),
        ("blocked", "blocked"),
        ("unknown", "unknown"),
    ] {
        let list = protocol(&["agent", "list", "--state", status]);
        assert_eq!(list.params["state"], daemon, "--state {status}");
        let ResponseView::AgentRoster(view) = list.view else { panic!("a roster") };
        assert_eq!(view.status, Some(status));
    }
}
