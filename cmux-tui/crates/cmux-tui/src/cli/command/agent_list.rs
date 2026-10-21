//! `agent list`: the `agent.list` read and how the CLI ranks, limits and
//! counts its rows (wire/agent_roster.rs).

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value};

use super::{
    AgentRosterView, AgentSort, CommandPlan, Flags, Selectors, UsageError, request,
    validate_one_of, validate_prefixed_id,
};

pub(super) fn parse(flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    if let Some(terminal) = flags.take("terminal") {
        validate_prefixed_id("terminal", "term", &terminal)?;
        params.insert("terminal_id".into(), Value::String(terminal));
    }
    if let Some(state) = flags.take("state") {
        validate_one_of("--state", &state, &["working", "blocked", "idle", "done", "unknown"])?;
        params.insert("state".into(), Value::String(state));
    }
    // `--needs-me` is the daemon's blocked filter.
    if flags.boolean("needs-me") {
        match params.get("state").and_then(Value::as_str) {
            None | Some("blocked") => {
                params.insert("state".into(), Value::String("blocked".into()));
            }
            Some(state) => {
                return Err(UsageError::new(format!(
                    "--needs-me lists blocked agents; it conflicts with --state {state}"
                )));
            }
        }
    }
    let sort = match flags.take("sort").as_deref() {
        None | Some("needs-me") => AgentSort::NeedsMe,
        Some("recent") => AgentSort::Recent,
        Some("none") => AgentSort::None,
        Some(_) => return Err(UsageError::new("--sort must be one of needs-me, recent, none")),
    };
    let limit = match flags.take("limit") {
        Some(limit) => Some(
            limit
                .parse::<usize>()
                .ok()
                .filter(|limit| *limit >= 1)
                .ok_or_else(|| UsageError::new("--limit must be a positive integer"))?,
        ),
        None => None,
    };
    let counts = flags.boolean("counts");
    Ok(request(ResourceOperation::AgentList, &Selectors::default(), flags, params)?
        .agent_roster(AgentRosterView { sort, limit, counts }))
}

#[cfg(test)]
mod tests {
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
        for (sort, expected) in [
            ("needs-me", AgentSort::NeedsMe),
            ("recent", AgentSort::Recent),
            ("none", AgentSort::None),
        ] {
            let list = protocol(&["agent", "list", "--sort", sort, "--limit", "5"]);
            assert_eq!(
                list.view,
                ResponseView::AgentRoster(AgentRosterView {
                    sort: expected,
                    limit: Some(5),
                    counts: false
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
        let both = protocol(&["agent", "list", "--needs-me", "--state", "blocked"]);
        assert_eq!(both.params["state"], "blocked");
        for invalid in [
            &["agent", "list", "--needs-me", "--state", "working"][..],
            &["agent", "list", "--sort", "oldest"],
            &["agent", "list", "--limit", "0"],
            &["agent", "list", "--limit", "many"],
        ] {
            assert!(parsed(invalid).is_err(), "accepted {invalid:?}");
        }
    }
}
