//! The protocol request a parsed command sends, and what it prints.

use cmux_tui_core::resource::{OperationClass, ResourceOperation};
use serde_json::Value;

use super::UsageError;

#[derive(Clone, Debug)]
pub(in crate::cli) struct RequestPlan {
    pub operation: WireOperation,
    pub params: Value,
    pub idempotency_key: Option<String>,
    pub stream: bool,
    /// Reads to run on the same connection before the request is sent.
    pub resolve: Vec<Resolve>,
    /// The part of the result the command prints.
    pub view: ResponseView,
}

/// The part of a result a command prints. `TerminalProgramStatus` is
/// `terminal <selector> status`: the `extra.program_status` records of the
/// `terminal.get` result (OSC 7501), `[]` when the terminal has none.
/// `AgentRoster` is `agent list`: the `agent.list` rows ranked, limited and
/// counted on the client (wire/agent_roster.rs).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) enum ResponseView {
    #[default]
    Full,
    TerminalProgramStatus,
    AgentRoster(AgentRosterView),
}

/// How `agent list` orders and trims its rows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) struct AgentRosterView {
    pub sort: AgentSort,
    /// At most this many rows; the counts still cover every listed agent.
    pub limit: Option<usize>,
    /// `--counts`: `--json` prints `{"agents","counts"}` instead of the
    /// bare agent array.
    pub counts: bool,
}

/// `agent list --sort`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) enum AgentSort {
    /// Blocked first, then working, then idle and done, then unknown; the
    /// most recently updated first within each group.
    #[default]
    NeedsMe,
    /// The most recently updated first.
    Recent,
    /// The daemon's order.
    None,
}

impl ResponseView {
    pub(in crate::cli) fn project(self, result: Value) -> Value {
        match self {
            // wire/agent_roster.rs shapes the roster once it has the
            // terminals' titles and folders.
            Self::Full | Self::AgentRoster(_) => result,
            Self::TerminalProgramStatus => match result.pointer("/extra/program_status") {
                Some(Value::Array(records)) => Value::Array(records.clone()),
                _ => Value::Array(Vec::new()),
            },
        }
    }
}

/// A parameter the command names indirectly. The CLI fills it with reads on
/// the request's own connection just before it sends the request, so the
/// request itself (and its idempotency fingerprint) carries only ids.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Resolve {
    /// `workspace` becomes the workspace that holds this terminal: the
    /// caller's own terminal (`CMUX_TUI_TERMINAL_ID`). With `--socket` or
    /// `--session` the target is that session's `current` workspace.
    CallerWorkspace { terminal: String },
    /// The command names a structural scope `caller`, or `current`: each
    /// becomes the caller's own object at that scope (its terminal's tab,
    /// pane, screen and workspace, or an agent session's, as
    /// `system.identify` reports). `current` stays the focused object when
    /// no caller is known or the request routes to another session.
    Caller,
    /// `field` names a state record (room or group) by id or exact name; a
    /// unique name becomes that record's id.
    StateName { field: &'static str, list: ResourceOperation },
    /// The request is a terminal's font zoom (`tab.update`). A browser tab's
    /// page zoom goes to the app instead (cli/resolve.rs).
    TabZoom { step: ZoomStep },
    /// `tab` becomes the tab that shows an agent's terminal (`agent <agent>
    /// focus`): an `agent_...` id from `agent.list`, or the `term_...` id of
    /// a terminal that has an agent.
    AgentTab { agent: String },
}

/// What `tab … zoom` asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::cli) enum ZoomStep {
    In,
    Out,
    Reset,
    /// An exact value (`zoom 1.5`, `update --zoom 1.5`).
    Value,
}

#[derive(Clone, Debug)]
pub(in crate::cli) enum WireOperation {
    Typed(ResourceOperation),
    Raw { name: String, class: OperationClass },
}

impl WireOperation {
    pub fn class(&self) -> OperationClass {
        match self {
            Self::Typed(operation) => operation.class(),
            Self::Raw { class, .. } => *class,
        }
    }

    pub fn name(&self) -> Result<String, UsageError> {
        match self {
            Self::Typed(operation) => Ok(operation.wire_name().to_owned()),
            Self::Raw { name, .. } => Ok(name.clone()),
        }
    }
}

impl super::CommandPlan {
    /// `terminal <selector> status`: the `terminal.get` request printed as
    /// its program status records.
    pub(super) fn terminal_program_status(self) -> Self {
        match self {
            Self::Protocol(mut plan) => {
                plan.view = ResponseView::TerminalProgramStatus;
                Self::Protocol(plan)
            }
            other => other,
        }
    }

    /// `agent list`: the `agent.list` request printed as a ranked roster.
    pub(super) fn agent_roster(self, view: AgentRosterView) -> Self {
        match self {
            Self::Protocol(mut plan) => {
                plan.view = ResponseView::AgentRoster(view);
                Self::Protocol(plan)
            }
            other => other,
        }
    }
}

/// The scopes a `caller` selector names, outermost first.
pub(in crate::cli) const CALLER_SCOPES: [&str; 5] =
    ["workspace", "screen", "pane", "tab", "terminal"];

/// `plan` with a [`Resolve::Caller`] lookup when a structural selector is
/// `caller` or `current`, which the CLI resolves against the caller before it
/// sends the request.
pub(super) fn with_caller_lookup(
    mut plan: super::CommandPlan,
    selectors: &std::collections::BTreeMap<&'static str, String>,
) -> super::CommandPlan {
    let named = CALLER_SCOPES.iter().any(|scope| {
        selectors.get(scope).is_some_and(|value| value == "caller" || value == "current")
    });
    if let super::CommandPlan::Protocol(plan) = &mut plan
        && named
    {
        plan.resolve.push(Resolve::Caller);
    }
    plan
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn terminal_status_prints_only_the_program_status_records() {
        let records = json!([{"id": "", "state": "working", "progress": 40}]);
        let terminal =
            json!({"id": "term_1", "extra": {"progress": null, "program_status": records}});
        assert_eq!(ResponseView::TerminalProgramStatus.project(terminal.clone()), records);
        assert_eq!(ResponseView::Full.project(terminal.clone()), terminal);
        assert_eq!(
            ResponseView::TerminalProgramStatus.project(json!({"id": "term_1"})),
            json!([]),
            "a terminal without records prints an empty list"
        );
    }

    #[test]
    fn terminal_status_is_a_terminal_get_with_the_status_view() {
        let args =
            ["terminal", "term_0123456789abcdef0123456789abcdef", "status"].map(str::to_owned);
        let Ok(super::super::CommandPlan::Protocol(plan)) =
            super::super::parse(&args, crate::cli::Surface::Cmux)
        else {
            panic!("terminal status parses to a protocol request");
        };
        assert_eq!(plan.operation.name().unwrap(), "terminal.get");
        assert_eq!(plan.view, ResponseView::TerminalProgramStatus);
    }
}
