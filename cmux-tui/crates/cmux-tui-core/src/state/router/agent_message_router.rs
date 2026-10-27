//! The `agent.message.*` operations of the state router
//! (plans/feat-agent-rooms/DESIGN.md; agent_messages.rs).

use serde_json::{Value, json};

use super::{index, mutation, state_error, state_result, string, strings};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{ParsedResourceRequest, expected_revision};
use crate::state::agent_message_store::{AgentMessageFilter, NewAgentMessage};

/// The agent message operations this router owns.
pub(super) fn handles(operation: ResourceOperation) -> bool {
    use ResourceOperation as Op;
    matches!(
        operation,
        Op::AgentMessageSend
            | Op::AgentMessageList
            | Op::AgentMessageMark
            | Op::AgentMessageRelease
            | Op::AgentMessageUnsend
    )
}

#[track_caller]
pub(super) fn dispatch(mux: &Mux, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    use ResourceOperation as Op;
    let fields = &request.fields;
    let selectors = &request.selectors;
    match request.envelope.operation {
        Op::AgentMessageList => {
            let filter = AgentMessageFilter {
                recipient: string(fields, "recipient"),
                sender: string(fields, "sender"),
                thread_id: string(fields, "thread_id"),
                state: string(fields, "state"),
                oldest_first: fields.get("oldest_first").and_then(Value::as_bool).unwrap_or(false),
            };
            let limit = index(fields, "limit").unwrap_or(50);
            mux.agent_message_list(selectors, &filter, limit).map(Value::Array)
        }
        Op::AgentMessageSend => {
            // `sender` is a claim the verified actor must match.
            let message = NewAgentMessage {
                sender: string(fields, "sender"),
                sender_name: string(fields, "sender_name"),
                recipients: strings(fields, "recipients"),
                body: string(fields, "body").unwrap_or_default(),
                thread_id: string(fields, "thread_id"),
                in_reply_to: string(fields, "in_reply_to"),
            };
            let commit = mux
                .agent_message_send(
                    &mutation(request)?,
                    expected_revision(fields)?,
                    selectors,
                    message,
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        Op::AgentMessageMark => {
            let commit = mux
                .agent_message_mark(
                    &mutation(request)?,
                    expected_revision(fields)?,
                    selectors,
                    &strings(fields, "ids"),
                    &string(fields, "recipient").unwrap_or_default(),
                    &string(fields, "state").unwrap_or_default(),
                    string(fields, "via").as_deref(),
                    string(fields, "error").as_deref(),
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        Op::AgentMessageRelease => {
            let commit = mux
                .agent_message_release(
                    &mutation(request)?,
                    expected_revision(fields)?,
                    selectors,
                    &string(fields, "message_id").unwrap_or_default(),
                    &string(fields, "recipient").unwrap_or_default(),
                    &string(fields, "decision").unwrap_or_default(),
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        Op::AgentMessageUnsend => {
            let commit = mux
                .agent_message_unsend(
                    &mutation(request)?,
                    expected_revision(fields)?,
                    selectors,
                    &string(fields, "message_id").unwrap_or_default(),
                    string(fields, "recipient").as_deref(),
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        operation => Err(ResourceError::operation_failed(
            operation.wire_name(),
            "the agent message router received an operation it does not own",
            json!({}),
        )),
    }
}
