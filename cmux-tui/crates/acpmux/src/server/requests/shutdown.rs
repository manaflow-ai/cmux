//! `_acpmux/shutdown` (`requests.rs`): stop the daemon, and the reason its client gave.

use super::*;

pub(super) async fn shutdown(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    // Stopping the daemon ends what runs at the VM boundary too: the owner's call only
    // (`hub/vm_boundary.rs`).
    let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
    if !crate::hub::vm_boundary::owner(conn.auth, control, &params) && hub.any_at_vm_boundary() {
        return Err(RpcError::new(
            -32000,
            "a chat here runs without the sandbox on its owner's own VM; only the owner's own devices stop this daemon",
        )
        .with_data(json!({"reason": "remote.unsandboxed_agent"})));
    }
    // The person's own daemon is never stopped by a test runner or a client from a
    // runner's `_work` or a temp folder (`exe_path::shutdown_refusal`). Only the daemon's
    // own environment can allow those; nothing a client sends does.
    let allow = crate::daemon::exe_path::allowed_by_env();
    if let Some(why) = crate::daemon::exe_path::peer_shutdown_refusal(conn.peer.as_ref(), allow) {
        tracing::warn!("{why}");
        return Err(
            RpcError::new(-32000, why).with_data(json!({"reason": "shutdown.refused_client"}))
        );
    }
    // `swapIfReplaced` (the app, for a daemon whose bundle an update replaced): swap to the
    // installed build make-before-break instead of stopping, so this daemon serves until
    // the new one asks for the home, and serves on if it never does. A stop here left
    // every chat without a daemon until the app's next one started (2026-11-22 23:44Z).
    // A daemon from before this ignores the flag and stops, as the app asked before.
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    if params.get("swapIfReplaced").and_then(Value::as_bool) == Some(true)
        && let Some(why) = crate::daemon::exe_swap::request_swap()
    {
        tracing::warn!(
            reason = %shutdown_reason(&params),
            "a client asked this daemon to stop; {why}: swapping make-before-break instead of stopping"
        );
        return Ok(json!({"swapping": true, "why": why}));
    }
    // Name who stopped it and why: the log's "a client asked it to" alone cannot tell an
    // app's update from another build's or a script's stop. `reason` is the client's own
    // word for its trigger (`shutdown_reason`); the daily count of the app's stops reads it.
    tracing::warn!(
        client = conn
            .peer
            .as_ref()
            .and_then(cmux_link::app_caller::executable_path)
            .map_or_else(|| "unknown".to_owned(), |exe| exe.display().to_string()),
        origin = ?conn.origin,
        reason = %shutdown_reason(&params),
        "a client asked this daemon to stop"
    );
    // A take-over start's ask for this daemon's listeners (`daemon/listener_handover.rs`):
    // from the unix socket only, to a side socket in this home that the asking process
    // listens on. Sent before the stop begins; a failure only means it binds as before.
    #[cfg(unix)]
    let handed: Vec<&'static str> = match (
        params.get(crate::daemon::listener_handover::PARAM).and_then(Value::as_str),
        conn.origin,
        conn.socket_peer,
    ) {
        (Some(side), Origin::Local, crate::sender_harness::SocketPeer::Pid(asker)) => {
            let side = std::path::PathBuf::from(side);
            let home = crate::config::home();
            match tokio::task::spawn_blocking(move || {
                crate::daemon::listener_handover::hand(&home, &side, asker)
            })
            .await
            {
                Ok(Ok(kinds)) => {
                    tracing::info!(asker, ?kinds, "handed the listeners to the take-over start");
                    kinds
                }
                Ok(Err(why)) => {
                    tracing::warn!(asker, "listener handover refused: {why}");
                    Vec::new()
                }
                Err(e) => {
                    tracing::warn!("listener handover task: {e}");
                    Vec::new()
                }
            }
        }
        _ => Vec::new(),
    };
    #[cfg(not(unix))]
    let handed: Vec<&'static str> = Vec::new();
    crate::daemon::supervision::stopping(crate::daemon::supervision::shutdown_cause(
        &shutdown_reason(&params),
        params.get("restart").and_then(Value::as_bool) == Some(true),
    ));
    // `endAgents: true` (the app's Quit Everything) ends agents that
    // run under agent hosts; otherwise they keep running for the next
    // daemon.
    // `keepSessions` (session ids) keeps those sessions' hosted agents
    // running even then (the app's Home Chief).
    let end_agents = params.get("endAgents").and_then(Value::as_bool) == Some(true);
    let keep: std::collections::HashSet<String> = params
        .get("keepSessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    if end_agents {
        hub.end_agents_at_shutdown(keep.clone())?;
    }
    if params.get("restart").and_then(Value::as_bool) == Some(true) {
        hub.restart_requested.store(true, std::sync::atomic::Ordering::SeqCst);
    }
    hub.stop_idle_reaper();
    hub.shutdown.notify_waiters();
    hub.shutdown.notify_one();
    let kept =
        if end_agents { keep.iter().filter(|id| hub.resolve(id).is_ok()).count() } else { 0 };
    Ok(json!({
        "endAgents": end_agents,
        "keptSessions": kept,
        "listenersHanded": handed,
    }))
}

/// The longest `_acpmux/shutdown` `reason` the log keeps, in characters.
const SHUTDOWN_REASON_MAX: usize = 160;

/// The `reason` a client gave for `_acpmux/shutdown`, one line for the log: control characters
/// become spaces and it is cut at [`SHUTDOWN_REASON_MAX`] characters. A client that gives none
/// (an older app or CLI) logs `unspecified`, which the daily count of stops reads as unknown.
fn shutdown_reason(params: &Value) -> String {
    let given = params.get("reason").and_then(Value::as_str).map(str::trim).unwrap_or_default();
    if given.is_empty() {
        return "unspecified".to_owned();
    }
    given.chars().take(SHUTDOWN_REASON_MAX).map(|c| if c.is_control() { ' ' } else { c }).collect()
}

#[cfg(test)]
#[path = "shutdown_tests.rs"]
mod tests;
