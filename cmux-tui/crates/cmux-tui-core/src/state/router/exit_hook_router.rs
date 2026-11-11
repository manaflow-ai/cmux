//! The `terminal.exit_hook.*` operations of the state router
//! (`terminal-exit-hooks-v1`; state/terminal_exit_hooks.rs).

use serde_json::{Value, json};

use super::{mutation, state_error, state_result};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::{ParsedResourceRequest, expected_revision};
use crate::state::terminal_exit_hooks::{ExitHookRequest, exit_hook_id};

/// The exit hook operations this router owns.
pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::TerminalExitHookAdd | ResourceOperation::TerminalExitHookList
    )
}

pub(super) fn dispatch(mux: &Mux, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let fields = &request.fields;
    let selectors = &request.selectors;
    match request.envelope.operation {
        ResourceOperation::TerminalExitHookList => {
            mux.terminal_exit_hook_snapshots(selectors).map(Value::Array)
        }
        ResourceOperation::TerminalExitHookAdd => {
            let mutation = mutation(request)?;
            let terminal = crate::resource_router::resolve_terminal_wait_exit_id(mux, selectors)?;
            // A closed terminal has no end left to report.
            mux.terminal_exit_state(&terminal).map_err(state_error)?;
            let prepared = mux.prepare_terminal_exit_hook(
                &request.actor,
                selectors,
                ExitHookRequest::from_add(fields)?,
            )?;
            let hook = exit_hook_id(&mutation.id, &terminal);
            let commit = mux
                .arm_terminal_exit_hook(
                    &mutation,
                    expected_revision(fields)?,
                    &terminal,
                    &hook,
                    &prepared,
                )
                .map_err(state_error)?;
            state_result(mux, commit)
        }
        operation => Err(ResourceError::operation_failed(
            operation.wire_name(),
            "exit hook router received an operation it does not own",
            json!({}),
        )),
    }
}
