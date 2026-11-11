//! The value of a public topology close (`workspace.close`, `screen.close`,
//! `pane.close`, `tab.close`). `workspace.close` with `report_closed_ids`
//! names the closed groups the close stored (`closed_ids`; absent on a replay
//! of a close committed before they were recorded). A close that names its
//! `terminals` choice (`end`, the default, or `keep`) gets the terminals it
//! ended (`ended_terminal_ids`) and the ones it left running with no tab
//! (`running_terminal_ids`; absent on a replay of a close committed before
//! they were recorded). Without those fields the value stays empty: older
//! SDKs decode it as an empty object.

use serde_json::{Map, Value};

use super::mutation_result;
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::workspace_registry::ResourcePatchCommit;

/// The close field that says what happens to the terminals the close leaves
/// with no tab: `end` (the default) or `keep`.
pub(super) const TERMINALS_FIELD: &str = "terminals";
/// The default of ``TERMINALS_FIELD``.
pub(super) const END_TERMINALS: &str = "end";

/// What a topology close's value reports, read from the request before the
/// router fills its defaults.
#[derive(Clone, Copy)]
pub(super) struct Report {
    /// The operation is a topology close.
    pub(super) is_close: bool,
    /// `report_closed_ids: true`.
    closed_ids: bool,
    /// The caller named `terminals`, so it decodes the terminal lists.
    terminals: bool,
}

impl Report {
    pub(super) fn of(operation: ResourceOperation, fields: &Map<String, Value>) -> Self {
        let is_close = matches!(
            operation,
            ResourceOperation::WorkspaceClose
                | ResourceOperation::ScreenClose
                | ResourceOperation::PaneClose
                | ResourceOperation::TabClose
        );
        Self {
            is_close,
            closed_ids: fields.get("report_closed_ids").and_then(Value::as_bool).unwrap_or(false),
            terminals: is_close && fields.contains_key(TERMINALS_FIELD),
        }
    }
}

/// The mutation result of a committed topology close.
pub(super) fn of(
    mux: &Mux,
    operation: ResourceOperation,
    commit: ResourcePatchCommit,
    report: Report,
) -> Result<Value, ResourceError> {
    let mut value = Map::new();
    if report.closed_ids
        && operation == ResourceOperation::WorkspaceClose
        && let Some(ids) = commit.result.get("closed_ids")
    {
        value.insert("closed_ids".into(), ids.clone());
    }
    if report.terminals {
        for field in ["ended_terminal_ids", "running_terminal_ids"] {
            if let Some(ids) = commit.result.get(field) {
                value.insert(field.into(), ids.clone());
            }
        }
    }
    mutation_result(mux, Value::Object(value), commit.revision, commit.replayed)
}
