//! `_acpmux/wait`: block until sessions reach a state, server side. The
//! state sequence is read before the first check, every hub event of a
//! target session re-evaluates, and the targets are re-read once a second,
//! so a change between "list" and "subscribe" cannot be missed. Only the
//! targets' summaries are built: building every session's on each hub event
//! (thousands a minute while agents stream) made a few idle waiters cost the
//! daemon most of a core with 200 chats (cosmic-gray, 2026-10-21).

use super::*;
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
        match self {
            Self::Ready => status != "running" && status != "waiting" && !pending && !turn,
            Self::Permission => pending || status == "waiting",
            Self::Closed => status == "closed",
            Self::Done => unread && status != "running" && status != "waiting",
            Self::Running => status == "running" || status == "waiting" || turn,
        }
    }
}

/// Params: `sessions` (keys; empty = every running or waiting session on
/// every host), `until` (list; default ready+permission), `all` (wait for
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
            if Until::Running.matches(&s)
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
    let targets: std::collections::HashSet<&str> = ids.iter().map(String::as_str).collect();
    let deadline = timeout.map(|t| tokio::time::Instant::now() + t);
    let evaluate = |hub: &Hub| -> (Vec<Value>, Vec<Value>) {
        let mut rows = Vec::new();
        let mut resolved = Vec::new();
        for id in &ids {
            let s = hub
                .session_summary_by_id(id)
                .unwrap_or_else(|| json!({"sessionId": id, "status": "closed", "missing": true}));
            let seq_ok = after
                .get(id)
                .map(|a| s.get("stateSeq").and_then(Value::as_u64).unwrap_or(0) > *a)
                .unwrap_or(true);
            let hit = seq_ok && until.iter().any(|u| u.matches(&s));
            let mut row = s.clone();
            row["resolved"] = json!(hit);
            row["matched"] = json!(
                until
                    .iter()
                    .filter(|u| seq_ok && u.matches(&s))
                    .map(|u| format!("{u:?}").to_lowercase())
                    .collect::<Vec<_>>()
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
        let poll = tokio::time::sleep(std::time::Duration::from_millis(1000));
        tokio::pin!(poll);
        let wake = async {
            loop {
                tokio::select! {
                    _ = &mut poll => return,
                    r = events.recv() => match r {
                        // Another session's record cannot change a target.
                        Ok(ev) if !targets.contains(ev.session_id.as_str()) => {}
                        // A target's record, or records were dropped: evaluate.
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
