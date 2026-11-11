//! `cmux session NAME reset-state`: removes a session's saved state (moved
//! out of command.rs), and with it the session's queued agent hook events.

use std::path::PathBuf;

use serde_json::json;

use super::super::GlobalArgs;
use super::SessionResetStatePlan;

pub(in crate::cli) fn run_session_reset_state(
    global: GlobalArgs,
    plan: SessionResetStatePlan,
) -> i32 {
    let output = global.output;
    let messages = &crate::localization::catalog().session_reset;
    let routing_options = [
        global.socket.as_ref().map(|_| "--socket"),
        global.session.as_ref().map(|_| "--session"),
        global.machine.as_ref().map(|_| "--machine"),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>();
    if !routing_options.is_empty() {
        let options = routing_options.join(", ");
        return super::super::wire::print_local_error(
            &json!({
                "code": "session.reset_state.routing_options_unsupported",
                "message": messages.routing_options_unsupported(&options),
                "details": { "options": routing_options },
                "retryable": false,
            }),
            output,
            2,
        );
    }
    let state_root =
        match plan.state.map(PathBuf::from).or_else(cmux_tui_core::platform::workspace_state_dir) {
            Some(path) => cmux_tui_core::platform::normalize_filesystem_path(path),
            None => {
                return super::super::wire::print_local_error(
                    &json!({
                        "code": "session.reset_state.no_state_root",
                        "message": messages.no_state_root,
                        "details": {},
                        "retryable": false,
                    }),
                    output,
                    1,
                );
            }
        };
    let resetter = cmux_tui_core::PersistentSessionStateResetter::new(state_root);
    if !plan.force {
        let preview = match resetter.preview(&plan.session) {
            Ok(preview) => preview,
            Err(error) => {
                let advice = reset_failure_advice(&error);
                return super::super::wire::print_local_error(
                    &json!({
                        "code": advice.code,
                        "message": format!("{}; {}", messages.reset_failed(&plan.session), advice.recovery),
                        "details": {
                            "session": &plan.session,
                            "reason": advice.reason,
                            "recovery": advice.recovery,
                        },
                        "retryable": false,
                    }),
                    output,
                    1,
                );
            }
        };
        return super::super::wire::print_local_success(
            &json!({
                "session": plan.session,
                "state_root": preview.state_root,
                "session_dir": preview.session_dir,
                "terminal_host_root": preview.terminal_host_root,
                "pending_reset_dirs": preview.pending_reset_dirs,
                "requires_force": preview.requires_force,
                "confirm_reset": preview.confirm_reset,
            }),
            output,
        );
    }
    match resetter.reset(&plan.session, plan.confirm_reset.as_deref()) {
        Ok(reset) => {
            let (hook_queue_key, hook_queue_value) = drop_hook_queue(&plan.session);
            let mut result = serde_json::Map::new();
            result.insert("session".to_owned(), json!(plan.session));
            result.insert("removed_session_state".to_owned(), json!(reset.removed_session_state));
            result.insert("removed_terminal_hosts".to_owned(), json!(reset.removed_terminal_hosts));
            result.insert(hook_queue_key.to_owned(), hook_queue_value);
            super::super::wire::print_local_success(&serde_json::Value::Object(result), output)
        }
        Err(error) => {
            let advice = reset_failure_advice(&error);
            let message = if advice.code == "session.reset_state.confirmation_required" {
                format!("{}; {}", messages.confirmation_required, messages.confirmation_recovery)
            } else {
                format!("{}; {}", messages.reset_failed(&plan.session), advice.recovery)
            };
            super::super::wire::print_local_error(
                &json!({
                    "code": advice.code,
                    "message": message,
                    "details": {
                        "session": plan.session,
                        "reason": advice.reason,
                        "recovery": advice.recovery,
                    },
                    "retryable": false,
                }),
                output,
                1,
            )
        }
    }
}

/// After `daemon stop --end-terminals` (W5-R, bench round 4 item 10):
/// removes the stopped owner's terminal and resume state (its launch
/// snapshot and terminal-host records) under `session_dir`, as the owner
/// reported it. The Chief store, conversations, git checkpoints, diff
/// comments and session settings stay. The removal waits (until `deadline`)
/// for the stopping owner to release its session locks, and never touches
/// the state of an owner that runs. Returns the fields for the stop result:
/// `removed_terminal_state` (true once none is left), and on failure
/// `terminal_state_error` (a `session.reset_state.*` code).
pub(in crate::cli) fn end_stopped_terminal_state(
    session: &str,
    session_dir: &std::path::Path,
    deadline: std::time::Instant,
) -> serde_json::Map<String, serde_json::Value> {
    let mut fields = serde_json::Map::new();
    let ended = session_dir
        .parent()
        .map(|root| cmux_tui_core::PersistentSessionStateResetter::new(root.to_path_buf()))
        .filter(|resetter| {
            resetter.session_dir(session)
                == cmux_tui_core::platform::normalize_filesystem_path(session_dir.to_path_buf())
        })
        .ok_or("session.reset_state.invalid_state_path")
        .and_then(|resetter| {
            resetter
                .end_terminal_state(session, deadline)
                .map_err(|error| reset_failure_advice(&error).code)
        });
    fields.insert("removed_terminal_state".to_owned(), json!(ended.is_ok()));
    if let Err(code) = ended {
        fields.insert("terminal_state_error".to_owned(), json!(code));
    }
    fields
}

/// The session has no saved state left, so no owner will ever send its
/// queued agent hook events: drops and counts them. A queue that cannot be
/// dropped is reported, and waits for a session of the same name. Returns
/// the result field: `dropped_hook_events` or `hook_queue_error`.
fn drop_hook_queue(session: &str) -> (&'static str, serde_json::Value) {
    let hook_queue = cmux_tui_core::server::try_default_socket_path(session)
        .map_err(|error| error.to_string())
        .and_then(|socket| {
            cmux_tui_core::diagnostics::drop_session_hook_queues(&socket)
                .map_err(|error| error.to_string())
        });
    match hook_queue {
        Ok(dropped) => ("dropped_hook_events", json!(dropped)),
        Err(error) => ("hook_queue_error", json!(error)),
    }
}

/// Why `daemon stop --purge` did not remove the stopped session's state:
/// a `session.reset_state.*` code and its localized reason.
pub(in crate::cli) struct PurgeFailure {
    pub(in crate::cli) code: &'static str,
    pub(in crate::cli) reason: &'static str,
}

/// `daemon stop --purge` (W6-E, bench round 5 A8): removes the stopped
/// session's whole folder, its terminal-host records and its guard file,
/// as `session <name> reset-state --force` does with its preview's
/// confirmation token, and drops its queued hook events. It first waits
/// (until `deadline`, with a blocking lock call) for the stopping owner to
/// release the session's locks: a session that another owner still runs is
/// refused at `deadline` (`session.reset_state.session_running`) and keeps
/// everything. The state root is the one the owner named (`session_dir`'s
/// parent), else this process's. Another session's folder is never
/// touched. Returns the stop result's fields: `removed_session_state`,
/// `removed_terminal_hosts`, and the hook queue field; or why it failed.
pub(in crate::cli) fn purge_stopped_session_state(
    session: Option<&str>,
    session_dir: Option<&std::path::Path>,
    deadline: std::time::Instant,
) -> Result<serde_json::Map<String, serde_json::Value>, PurgeFailure> {
    use cmux_tui_core::PersistentSessionStateResetter as Resetter;
    let local_server = &crate::localization::catalog().local_server;
    let session_reset = &crate::localization::catalog().session_reset;
    let session = session.ok_or(PurgeFailure {
        code: "session.reset_state.no_session",
        reason: local_server.purge_needs_session,
    })?;
    let resetter = match session_dir {
        Some(dir) => dir
            .parent()
            .map(|root| Resetter::new(root.to_path_buf()))
            .filter(|resetter| {
                resetter.session_dir(session)
                    == cmux_tui_core::platform::normalize_filesystem_path(dir.to_path_buf())
            })
            .ok_or(PurgeFailure {
                code: "session.reset_state.invalid_state_path",
                reason: session_reset.reason_invalid_state_path,
            }),
        None => {
            cmux_tui_core::platform::workspace_state_dir().map(Resetter::new).ok_or(PurgeFailure {
                code: "session.reset_state.no_state_root",
                reason: local_server.purge_no_state_root,
            })
        }
    }?;
    let purge = || -> anyhow::Result<_> {
        let ended = resetter.end_terminal_state(session, deadline)?;
        let preview = resetter.preview(session)?;
        let reset = resetter.purge(session, Some(&preview.confirm_reset))?;
        Ok(ended.removed_terminal_hosts || reset.removed_terminal_hosts)
    };
    let removed_terminal_hosts = purge().map_err(|error| {
        let advice = reset_failure_advice(&error);
        // The token is this purge's own preview: a mismatch means the
        // state changed between the two.
        if advice.code == "session.reset_state.confirmation_required" {
            PurgeFailure {
                code: "session.reset_state.state_changed",
                reason: session_reset.reason_state_changed,
            }
        } else {
            PurgeFailure { code: advice.code, reason: advice.reason }
        }
    })?;
    let mut fields = serde_json::Map::new();
    fields.insert("removed_session_state".to_owned(), json!(true));
    fields.insert("removed_terminal_hosts".to_owned(), json!(removed_terminal_hosts));
    let (key, value) = drop_hook_queue(session);
    fields.insert(key.to_owned(), value);
    Ok(fields)
}

struct ResetFailureAdvice {
    code: &'static str,
    reason: &'static str,
    recovery: &'static str,
}

fn reset_failure_advice(error: &anyhow::Error) -> ResetFailureAdvice {
    let messages = &crate::localization::catalog().session_reset;
    if reset_error_starts_with(error, &["reset confirmation is required"]) {
        ResetFailureAdvice {
            code: "session.reset_state.confirmation_required",
            reason: messages.confirmation_required,
            recovery: messages.confirmation_recovery,
        }
    } else if reset_error_starts_with(
        error,
        &["safe saved-state reset is not supported on this platform"],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.unsupported",
            reason: messages.reason_reset_unsupported,
            recovery: messages.recovery_reset_unsupported,
        }
    } else if reset_error_starts_with(
        error,
        &[
            "workspace state root is not a directory",
            "workspace session state path is not a directory",
            "terminal host state path is not a directory",
            "private reset path is not a directory",
            "session lock directory is not a directory",
            "not a directory:",
        ],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.invalid_state_path",
            reason: messages.reason_invalid_state_path,
            recovery: messages.recovery_invalid_state_path,
        }
    } else if reset_error_starts_with(
        error,
        &["workspace session is already owned by another daemon"],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.session_running",
            reason: messages.reason_session_running,
            recovery: messages.recovery_session_running,
        }
    } else if reset_error_starts_with(
        error,
        &[
            "terminal host state still has live or unverified hosts",
            "terminal host state has live or unverified hosts",
        ],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.terminal_hosts_live",
            reason: messages.reason_terminal_hosts_live,
            recovery: messages.recovery_terminal_hosts_live,
        }
    } else if reset_error_starts_with(
        error,
        &["terminal host liveness cannot be verified on this platform"],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.terminal_hosts_unsupported",
            reason: messages.reason_terminal_hosts_unsupported,
            recovery: messages.recovery_terminal_hosts_unsupported,
        }
    } else if reset_error_starts_with(
        error,
        &["reset path changed during reset", "reset path changed during fingerprint"],
    ) {
        ResetFailureAdvice {
            code: "session.reset_state.state_changed",
            reason: messages.reason_state_changed,
            recovery: messages.recovery_state_changed,
        }
    } else if reset_error_starts_with(error, &["reset confirmation scan exceeds"]) {
        ResetFailureAdvice {
            code: "session.reset_state.state_too_large",
            reason: messages.reason_state_too_large,
            recovery: messages.recovery_state_too_large,
        }
    } else {
        ResetFailureAdvice {
            code: "session.reset_state.filesystem",
            reason: messages.reason_filesystem,
            recovery: messages.recovery_filesystem,
        }
    }
}

fn reset_error_starts_with(error: &anyhow::Error, prefixes: &[&str]) -> bool {
    error.chain().any(|cause| {
        let cause = cause.to_string();
        prefixes.iter().any(|prefix| cause.starts_with(prefix))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reset_failure_advice_classifies_fingerprint_race_as_state_changed() {
        let advice = reset_failure_advice(&anyhow::anyhow!(
            "reset path changed during fingerprint: /tmp/cmux-state/registry"
        ));
        assert_eq!(advice.code, "session.reset_state.state_changed");
        assert!(advice.recovery.contains("rerun the preview"), "{}", advice.recovery);
    }

    #[test]
    fn reset_failure_advice_classifies_confirmation_scan_limit() {
        let advice = reset_failure_advice(&anyhow::anyhow!(
            "reset confirmation scan exceeds 64 paths; scoped state is too large"
        ));
        assert_eq!(advice.code, "session.reset_state.state_too_large");
        assert!(advice.recovery.contains("reduce the scoped saved state"), "{}", advice.recovery);
    }

    #[test]
    fn reset_failure_advice_classifies_unsupported_checked_deletion() {
        let advice = reset_failure_advice(&anyhow::anyhow!(
            "safe saved-state reset is not supported on this platform because cmux cannot verify saved state during deletion"
        ));
        assert_eq!(advice.code, "session.reset_state.unsupported");
        assert!(advice.recovery.contains("supported platform build"), "{}", advice.recovery);
    }

    #[test]
    fn reset_failure_advice_ignores_marker_text_inside_paths() {
        let advice = reset_failure_advice(&anyhow::anyhow!(
            "workspace state root is not a directory: /tmp/already owned by another daemon"
        ));
        assert_eq!(advice.code, "session.reset_state.invalid_state_path");
    }
}
