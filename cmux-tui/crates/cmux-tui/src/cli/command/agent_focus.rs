//! `agent <agent> focus`: focus the tab that shows an agent's terminal. The
//! agent is an `agent_...` id from `agent list`, or the `term_...` id of a
//! terminal that has an agent. Any other `agent` words are a usage error.

use cmux_tui_core::resource::ResourceOperation;
use serde_json::Map;

use super::flags::usage;
use super::{CommandPlan, Flags, Resolve, Selectors, UsageError, request, validate_prefixed_id};

pub(super) fn parse(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let [selector, "focus"] = words else { return usage("agent action") };
    let (scope, prefix) = if selector.starts_with("agent_") {
        ("agent", "agent")
    } else if selector.starts_with("term_") {
        ("terminal", "term")
    } else {
        return usage("agent action");
    };
    validate_prefixed_id(scope, prefix, selector)?;
    // A tab focus whose tab the CLI looks up just before it sends it
    // (cli/resolve.rs), so the app follows as for `tab <tab> focus`.
    let mut plan = request(ResourceOperation::TabFocus, &Selectors::default(), flags, Map::new())?;
    if let CommandPlan::Protocol(plan) = &mut plan {
        plan.resolve.push(Resolve::AgentTab { agent: (*selector).to_owned() });
    }
    Ok(plan)
}
