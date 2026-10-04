//! `terminal.relaunch` and `terminal.input.send_kept` (R81 stage A, G2):
//! the two operations on a terminal whose launch failed after its accept.
//! Both are exactly-once effects. The relaunch fields (program, directory,
//! environment) can hold credentials, so the effect receipt keeps only
//! their keyed digest (`effects::sensitive_input_operation`).

use std::sync::Arc;

use serde_json::{Value, json};

use super::effects::{self, EffectPreparation};
use super::{ParsedResourceRequest, resolve_terminal_wait_exit_id, validation_error};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};

pub(super) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::TerminalRelaunch | ResourceOperation::TerminalInputSendKept
    )
}

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let relaunch = match request.envelope.operation {
        ResourceOperation::TerminalRelaunch => Some(relaunch_fields(&request)?),
        _ => None,
    };
    let preparation = effects::prepare(mux, &request, || {
        let terminal = resolve_terminal_wait_exit_id(mux, &request.selectors)?;
        Ok(json!({"terminal_id":terminal,"fields":request.fields}))
    })?;
    let prepared = match preparation {
        EffectPreparation::Complete(result) => return result,
        EffectPreparation::Execute(prepared) => prepared,
    };
    let operation = prepared.operation.clone();
    let terminal = prepared.intent["terminal_id"].as_str().unwrap_or_default().to_string();
    let host = match mux.resolve_terminal(&terminal) {
        Ok(Some(resolution)) => resolution.terminal.terminal_id,
        Ok(None) => {
            return effects::commit_known_failure(
                mux,
                prepared,
                ResourceError::not_found("terminal", &terminal),
            );
        }
        Err(_) => return Err(effects::mark_indeterminate(mux, prepared)),
    };
    let outcome = match relaunch {
        // The host incarnation stays private to the owner; the
        // `terminal-lifecycle` event and `resolve-terminal` carry it.
        Some(relaunch) => {
            mux.relaunch_exited_terminal(&host, relaunch).map(|_| json!({"terminal":terminal}))
        }
        None => mux
            .send_kept_terminal_input(&host)
            .map(|bytes| json!({"terminal":terminal,"bytes":bytes})),
    };
    match outcome {
        Ok(value) => effects::commit_success_without_changes(mux, prepared, value),
        Err(error) => effects::commit_known_failure(
            mux,
            prepared,
            ResourceError::operation_failed(&operation, format!("{error:#}"), json!({})),
        ),
    }
}

/// The program, directory and environment of a relaunch. `shell_args`
/// runs `env.SHELL` (or the default shell) with those arguments, as for
/// `new-tab`.
fn relaunch_fields(
    request: &ParsedResourceRequest,
) -> Result<crate::mux::TerminalRelaunch, ResourceError> {
    let env = match request.fields.get("env") {
        None | Some(Value::Null) => Vec::new(),
        Some(value) => {
            let env =
                serde_json::from_value::<std::collections::BTreeMap<String, String>>(value.clone())
                    .map_err(|_| validation_error("env must map names to strings", json!({})))?;
            crate::mux::validate_terminal_env(&env)
                .map_err(|error| validation_error(&format!("{error:#}"), json!({})))?
        }
    };
    let shell_args = match request.fields.get("shell_args") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            serde_json::from_value::<Vec<String>>(value.clone())
                .map_err(|_| validation_error("shell_args must be strings", json!({})))?,
        ),
    };
    let cwd = match request.fields.get("cwd") {
        None | Some(Value::Null) => None,
        Some(Value::String(cwd)) => Some(cwd.clone()),
        Some(_) => return Err(validation_error("cwd must be a string", json!({}))),
    };
    let argv = crate::server::split_respawn::shell_argv(&env, shell_args, false);
    Ok(crate::mux::TerminalRelaunch { argv, cwd, env })
}
