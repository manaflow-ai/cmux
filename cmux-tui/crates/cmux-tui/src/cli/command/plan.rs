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
/// `caller`, `current` or `focused`, which the CLI resolves against the
/// caller (or the person's focus) before it sends the request, or when a
/// person's terminal creates a tab with no place
/// ([`fill_terminal_caller_place`]).
pub(super) fn with_caller_lookup(
    mut plan: super::CommandPlan,
    selectors: &std::collections::BTreeMap<&'static str, String>,
) -> super::CommandPlan {
    let named = CALLER_SCOPES.iter().any(|scope| {
        selectors
            .get(scope)
            .is_some_and(|value| matches!(value.as_str(), "caller" | "current" | "focused"))
    });
    if let super::CommandPlan::Protocol(plan) = &mut plan {
        let env = |key: &str| std::env::var(key).ok();
        if fill_terminal_caller_place(plan, env) || named {
            plan.resolve.push(Resolve::Caller);
        }
    }
    plan
}

/// A terminal tab created from a person's cmux terminal with no
/// `--workspace`, `--screen` or `--pane` opens in that terminal's own pane,
/// not the daemon's active one, which can be a workspace the person is not
/// in (https://github.com/manaflow-ai/cmux/issues/25590). It names `current`
/// for each, which [`Resolve::Caller`] turns into the caller's ids; a caller
/// that cannot be found, or a request to another session or machine, keeps
/// the daemon's default as before. An agent's goes beside its chat instead
/// (beside.rs). Whether it filled them.
fn fill_terminal_caller_place(
    plan: &mut RequestPlan,
    env: impl Fn(&str) -> Option<String>,
) -> bool {
    let set = |key: &str| env(key).is_some_and(|value| !value.is_empty());
    let person_terminal =
        set("CMUX_TUI_TERMINAL_ID") && !set("CMUX_AGENT_SESSION") && !set("CMUX_CALLER_HOME_CHAT");
    let creates_terminal =
        matches!(plan.operation, WireOperation::Typed(ResourceOperation::TabCreateTerminal));
    let Some(params) = plan.params.as_object_mut() else { return false };
    const PARENTS: [&str; 3] = ["workspace", "screen", "pane"];
    if !person_terminal || !creates_terminal || PARENTS.iter().any(|key| params.contains_key(*key))
    {
        return false;
    }
    for key in PARENTS {
        params.insert(key.into(), Value::String("current".into()));
    }
    true
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

    fn creation(operation: ResourceOperation, params: Value) -> RequestPlan {
        RequestPlan {
            operation: WireOperation::Typed(operation),
            params,
            idempotency_key: None,
            stream: false,
            resolve: Vec::new(),
            view: ResponseView::Full,
        }
    }

    #[test]
    fn a_persons_terminal_tab_with_no_place_names_the_callers_place() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |key: &str| {
                pairs.iter().find(|(name, _)| *name == key).map(|(_, value)| (*value).to_owned())
            }
        };
        let terminal = &[("CMUX_TUI_TERMINAL_ID", "term_a")];
        let mut plan =
            creation(ResourceOperation::TabCreateTerminal, json!({"machine": "current"}));
        assert!(fill_terminal_caller_place(&mut plan, env(terminal)));
        assert_eq!(plan.params["workspace"], "current");
        assert_eq!(plan.params["screen"], "current");
        assert_eq!(plan.params["pane"], "current");

        // A named place, another operation, an agent, a Chief turn or no
        // terminal: unchanged.
        let mut named = creation(ResourceOperation::TabCreateTerminal, json!({"pane": "pane_x"}));
        assert!(!fill_terminal_caller_place(&mut named, env(terminal)));
        assert_eq!(named.params, json!({"pane": "pane_x"}));
        let mut browser = creation(ResourceOperation::TabCreateBrowser, json!({}));
        assert!(!fill_terminal_caller_place(&mut browser, env(terminal)));
        for others in [
            &[("CMUX_TUI_TERMINAL_ID", "term_a"), ("CMUX_AGENT_SESSION", "s")][..],
            &[("CMUX_TUI_TERMINAL_ID", "term_a"), ("CMUX_CALLER_HOME_CHAT", "1")][..],
            &[][..],
        ] {
            let mut plan = creation(ResourceOperation::TabCreateTerminal, json!({}));
            assert!(!fill_terminal_caller_place(&mut plan, env(others)));
        }
    }
}
