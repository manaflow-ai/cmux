//! `_acpmux/wait`: block until sessions reach a state, server side. The
//! state sequence is read before the first check, and every state record of
//! a waited-for session re-evaluates, so a change between "list" and
//! "subscribe" cannot be missed. Only the waited-for sessions are read, and
//! an agent's own traffic (each streamed token) wakes nothing: it changes no
//! state a wait reads, and it re-read every session's summary per token.
//! Peer sessions are also re-read once a second, while one is waited for:
//! a peer does not send every change.

use super::*;
use crate::no_panic::JsonExt;
use std::collections::HashMap;

/// What a caller can wait for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Until {
    /// The turn ended: not running, not waiting.
    Ready,
    /// A permission request is pending.
    Permission,
    Closed,
    /// Ended while no client was attached (the unread bit).
    Done,
    /// A turn is in progress (a prompt was accepted).
    Running,
}

impl Until {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "ready" | "idle" | "ended" => Self::Ready,
            "permission" | "blocked" | "waiting" => Self::Permission,
            "closed" | "stopped" => Self::Closed,
            "done" | "unread" => Self::Done,
            "running" | "working" | "started" => Self::Running,
            _ => return None,
        })
    }
    pub fn matches(self, s: &Value) -> bool {
        let status = s.get("status").and_then(Value::as_str).unwrap_or("");
        let pending = s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
        let unread = s.get("unread").and_then(Value::as_bool).unwrap_or(false);
        // An accepted turn whose agent is still starting is not ready yet
        // (its status turns running only once the prompt goes out).
        let turn = s.get("turn").is_some_and(|t| !t.is_null());
        // A sub-session whose prompt waits for a run slot (`hub/subsession_runs.rs`) has work
        // to do: it is not ready, nor done.
        let slot = s.get("waitsForSlot").and_then(Value::as_bool).unwrap_or(false);
        match self {
            Self::Ready => status != "running" && status != "waiting" && !pending && !turn && !slot,
            Self::Permission => pending || status == "waiting",
            Self::Closed => status == "closed",
            Self::Done => unread && status != "running" && status != "waiting" && !slot,
            Self::Running => status == "running" || status == "waiting" || turn,
        }
    }
}

/// Params: `sessions` (keys; empty = every running or waiting session on
/// every host, and every sub-session waiting for a run slot), `until` (list; default ready+permission), `all` (wait for
/// every target instead of the first), `afterSeq` (map of session id to a
/// state sequence the resolution must exceed), `timeoutMs`.
pub(super) async fn wait(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let until: Vec<Until> = match params.get("until").and_then(Value::as_array) {
        Some(a) if !a.is_empty() => a
            .iter()
            .filter_map(Value::as_str)
            .map(|s| {
                Until::parse(s).ok_or_else(|| {
                    RpcError::invalid_params(format!(
                        "unknown state {s:?}; use ready, permission, closed, done or running"
                    ))
                })
            })
            .collect::<Result<_, _>>()?,
        _ => vec![Until::Ready, Until::Permission],
    };
    let all = params.get("all").and_then(Value::as_bool).unwrap_or(false);
    let timeout =
        params.get("timeoutMs").and_then(Value::as_u64).map(std::time::Duration::from_millis);
    let after: HashMap<String, u64> = params
        .get("afterSeq")
        .and_then(Value::as_object)
        .map(|o| o.iter().filter_map(|(k, v)| v.as_u64().map(|n| (k.clone(), n))).collect())
        .unwrap_or_default();
    // Resolve targets once: explicit keys, or everything in flight now.
    let keys: Vec<String> = params
        .get("sessions")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default();
    let mut ids: Vec<String> = Vec::new();
    if keys.is_empty() {
        for s in hub.all_session_summaries() {
            let slot = s.get("waitsForSlot").and_then(Value::as_bool).unwrap_or(false);
            if (Until::Running.matches(&s) || slot)
                && let Some(id) = s.get("sessionId").and_then(Value::as_str)
            {
                ids.push(id.to_owned());
            }
        }
    } else {
        for k in &keys {
            match hub.resolve(k) {
                Ok(s) => ids.push(s.id.clone()),
                Err(_) => {
                    let (_, id, _) = hub
                        .resolve_remote(k)
                        .ok_or_else(|| RpcError::not_found(format!("no session matches {k:?}")))?;
                    ids.push(id);
                }
            }
        }
    }
    if ids.is_empty() {
        return Ok(json!({"sessions": [], "timedOut": false, "resolved": []}));
    }
    let mut events = hub.subscribe();
    let deadline = timeout.map(|t| tokio::time::Instant::now() + t);
    let local: std::collections::HashSet<String> =
        ids.iter().filter(|id| hub.resolve(id).is_ok_and(|s| &s.id == *id)).cloned().collect();
    let remote = ids.iter().any(|id| !local.contains(id));
    let evaluate = |hub: &Hub| -> (Vec<Value>, Vec<Value>) {
        let remote_summaries = if remote { hub.remote_sessions() } else { Vec::new() };
        let mut rows = Vec::new();
        let mut resolved = Vec::new();
        for id in &ids {
            let local_summary = local
                .contains(id)
                .then(|| hub.resolve(id).ok().filter(|s| &s.id == id))
                .flatten()
                .map(|s| hub.session_summary(&s));
            let s = local_summary
                .or_else(|| {
                    remote_summaries
                        .iter()
                        .find(|s| s.get("sessionId").and_then(Value::as_str) == Some(id))
                        .cloned()
                })
                .unwrap_or_else(|| json!({"sessionId": id, "status": "closed", "missing": true}));
            let seq_ok = after
                .get(id)
                .map(|a| s.get("stateSeq").and_then(Value::as_u64).unwrap_or(0) > *a)
                .unwrap_or(true);
            let hit = seq_ok && until.iter().any(|u| u.matches(&s));
            let mut row = s.clone();
            row.set("resolved", json!(hit));
            row.set(
                "matched",
                json!(
                    until
                        .iter()
                        .filter(|u| seq_ok && u.matches(&s))
                        .map(|u| format!("{u:?}").to_lowercase())
                        .collect::<Vec<_>>()
                ),
            );
            if hit {
                resolved.push(row.clone());
            }
            rows.push(row);
        }
        (rows, resolved)
    };
    loop {
        let (rows, resolved) = evaluate(hub);
        let finished = if all { resolved.len() == ids.len() } else { !resolved.is_empty() };
        if finished {
            return Ok(json!({"sessions": rows, "resolved": resolved, "timedOut": false}));
        }
        // Peer sessions only: a bounded re-read while this wait runs.
        let peer_reread = async {
            if remote {
                tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
            } else {
                std::future::pending::<()>().await;
            }
        };
        tokio::pin!(peer_reread);
        let wake = async {
            loop {
                tokio::select! {
                    _ = &mut peer_reread => return,
                    r = events.recv() => match r {
                        Ok(ev) if !changes_a_wait(&ev, &ids, remote) => continue,
                        // A lag may have dropped a state record: read again.
                        Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => return,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            // Daemon shutting down.
                            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                            return;
                        }
                    },
                }
            }
        };
        match deadline {
            Some(d) => {
                if tokio::time::timeout_at(d, wake).await.is_err() {
                    let (rows, resolved) = evaluate(hub);
                    let finished =
                        if all { resolved.len() == ids.len() } else { !resolved.is_empty() };
                    return Ok(
                        json!({"sessions": rows, "resolved": resolved, "timedOut": !finished}),
                    );
                }
            }
            None => wake.await,
        }
    }
}

/// Whether hub event `ev` may change what a wait for `ids` reads: a record of one of them that
/// is not the agent's own wire traffic (`in`/`out`: tokens, tool output), or any peer event
/// while a peer session is waited for.
fn changes_a_wait(ev: &crate::hub::HubEvent, ids: &[String], remote: bool) -> bool {
    if ev.remote.is_some() {
        return remote;
    }
    ids.contains(&ev.session_id) && !matches!(ev.record.dir.as_str(), "in" | "out")
}
