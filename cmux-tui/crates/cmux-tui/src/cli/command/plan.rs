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
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(in crate::cli) enum ResponseView {
    #[default]
    Full,
    TerminalProgramStatus,
}

impl ResponseView {
    pub(in crate::cli) fn project(self, result: Value) -> Value {
        match self {
            Self::Full => result,
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
    /// `field` names a state record (room or group) by id or exact name; a
    /// unique name becomes that record's id.
    StateName { field: &'static str, list: ResourceOperation },
    /// The request is a terminal's font zoom (`tab.update`). A browser tab's
    /// page zoom goes to the app instead (cli/resolve.rs).
    TabZoom { step: ZoomStep },
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
