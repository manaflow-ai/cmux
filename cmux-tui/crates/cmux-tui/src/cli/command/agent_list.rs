//! `agent list`: the `agent.list` read and how the CLI ranks, limits and
//! counts its rows (wire/agent_roster.rs).

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value};

use super::{
    AgentRosterView, AgentSort, CommandPlan, Flags, Selectors, UsageError, request,
    validate_one_of, validate_prefixed_id, validate_selector,
};

pub(super) fn parse(flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    // A full `term_` id stays `terminal_id`, which every daemon takes; any
    // other terminal selector (a prefix, a bare or host id such as a raw
    // `run` reply's `terminal_id`, a tab or pane id, a name) is the
    // `terminal` field, which the daemon's one resolver reads (W5-P).
    if let Some(terminal) = flags.take("terminal") {
        if validate_prefixed_id("terminal", "term", &terminal).is_ok() {
            params.insert("terminal_id".into(), Value::String(terminal));
        } else {
            validate_selector("terminal", "term", &terminal)?;
            params.insert("terminal".into(), Value::String(terminal));
        }
    }
    // `--state` takes the shared status words (`done` is a finished turn
    // nobody has viewed; `ended` a session that ended). The daemon filters by
    // its own state, the CLI then by status (wire/agent_roster.rs).
    let mut status = match flags.take("state") {
        Some(state) => {
            validate_one_of("--state", &state, &STATUS_WORDS)?;
            STATUS_WORDS.iter().copied().find(|word| *word == state)
        }
        None => None,
    };
    // `--needs-me` is the blocked filter.
    if flags.boolean("needs-me") {
        match status {
            None | Some("blocked") => status = Some("blocked"),
            Some(state) => {
                return Err(UsageError::new(format!(
                    "--needs-me lists blocked agents; it conflicts with --state {state}"
                )));
            }
        }
    }
    if let Some(status) = status {
        let state = crate::cli::wire::daemon_state_for_status(status);
        params.insert("state".into(), Value::String(state.to_owned()));
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
        .agent_roster(AgentRosterView { sort, limit, counts, status }))
}

/// The words `agent list --state` takes: the shared status vocabulary and
/// `ended`.
const STATUS_WORDS: [&str; 6] = ["working", "blocked", "done", "idle", "unknown", "ended"];

#[cfg(test)]
mod tests;
