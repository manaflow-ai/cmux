//! The value of a public topology close (`workspace.close`, `screen.close`,
//! `pane.close`, `tab.close`). `workspace.close` with `report_closed_ids`
//! names the closed groups the close stored (`closed_ids`; absent on a replay
//! of a close committed before they were recorded). Without the flag, and for
//! the other closes, the value stays empty: older SDKs decode it as an empty
//! object.

use serde_json::{Map, Value, json};

use super::mutation_result;
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::workspace_registry::ResourcePatchCommit;

/// Whether the request asks for `closed_ids` (`report_closed_ids: true`).
pub(super) fn reports_closed_ids(fields: &Map<String, Value>) -> bool {
    fields.get("report_closed_ids").and_then(Value::as_bool).unwrap_or(false)
}

/// The mutation result of a committed topology close.
pub(super) fn of(
    mux: &Mux,
    operation: ResourceOperation,
    commit: ResourcePatchCommit,
    report_closed_ids: bool,
) -> Result<Value, ResourceError> {
    let value = match commit.result.get("closed_ids") {
        Some(ids) if report_closed_ids && operation == ResourceOperation::WorkspaceClose => {
            json!({"closed_ids": ids})
        }
        _ => json!({}),
    };
    mutation_result(mux, value, commit.revision, commit.replayed)
}
