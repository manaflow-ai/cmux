//! The `workspace_checklist.*` operations of the state router
//! (`workspace-checklist-v1`; state/workspace_checklist.rs).

use serde_json::{Value, json};

use super::{index, mutation, state_error, state_result, string};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{ParsedResourceRequest, expected_revision};
use crate::state::workspace_checklist::WorkspaceChecklistChange;
use crate::state::workspace_checklist_store::{ChecklistAttachmentInput, ChecklistItemUpdate};
use crate::workspace_registry::Actor;

/// The checklist operations this router owns.
pub(super) fn handles(operation: ResourceOperation) -> bool {
    use ResourceOperation as Op;
    matches!(
        operation,
        Op::WorkspaceChecklistList
            | Op::WorkspaceChecklistAdd
            | Op::WorkspaceChecklistUpdate
            | Op::WorkspaceChecklistRemove
    )
}

/// Who created an item when the request does not say: an agent for a
/// process in a cmux terminal or an ACP session, else the person.
fn default_origin(actor: &Actor) -> &'static str {
    match actor {
        Actor::Terminal { .. } | Actor::AcpSession { .. } => "agent",
        _ => "user",
    }
}

fn attachments(
    fields: &serde_json::Map<String, Value>,
) -> Result<Option<Vec<ChecklistAttachmentInput>>, ResourceError> {
    let Some(value) = fields.get("attachments") else { return Ok(None) };
    serde_json::from_value(value.clone()).map(Some).map_err(|error| {
        ResourceError::validation_invalid(Some("attachments"), format!("attachments: {error}"))
    })
}

#[track_caller]
pub(super) fn dispatch(mux: &Mux, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    use ResourceOperation as Op;
    let fields = &request.fields;
    let selectors = &request.selectors;
    let operation = request.envelope.operation;
    let change = match operation {
        Op::WorkspaceChecklistList => {
            return mux.workspace_checklist_snapshots(selectors).map(Value::Array);
        }
        Op::WorkspaceChecklistAdd => WorkspaceChecklistChange::Add {
            text: string(fields, "text").unwrap_or_default(),
            state: string(fields, "state"),
            origin: string(fields, "origin")
                .unwrap_or_else(|| default_origin(&request.actor).to_string()),
            index: index(fields, "index"),
        },
        Op::WorkspaceChecklistUpdate => WorkspaceChecklistChange::Update {
            item: string(fields, "item").unwrap_or_default(),
            update: ChecklistItemUpdate {
                text: string(fields, "text"),
                state: string(fields, "state"),
                index: index(fields, "index"),
                attachments: attachments(fields)?,
            },
        },
        Op::WorkspaceChecklistRemove => {
            WorkspaceChecklistChange::Remove { item: string(fields, "item").unwrap_or_default() }
        }
        operation => {
            return Err(ResourceError::operation_failed(
                operation.wire_name(),
                "checklist router received an operation it does not own",
                json!({}),
            ));
        }
    };
    let commit = mux
        .state_workspace_checklist(
            &mutation(request)?,
            operation.wire_name(),
            expected_revision(fields)?,
            selectors,
            change,
        )
        .map_err(state_error)?;
    state_result(mux, commit)
}
