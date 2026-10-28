//! `_acpmux/wait`: block until sessions reach a state, server side. The
//! state sequence is read before the first check, every hub event
//! re-evaluates, and peer sessions are re-read once a second, so a change
//! between "list" and "subscribe" cannot be missed.

use super::*;
use crate::no_panic::JsonExt;
use std::collections::HashMap;
use std::time::Duration;

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

/// `turnEnded {turnId, startedAt}`: the turn a steered `acpmux send` went into
/// (`cli/steer_reply.rs`) is over. Its end is recorded (`lastTurn`, set with
/// its `turn_result`) once it is `lastTurn`, a turn ended after `startedAt`
/// (the turn's own start, from the same daemon's clock: turns run one at a time,
/// so that is a later one; the one before may end in the very millisecond it
/// starts), or another turn runs. While it runs it has not ended. A session that
/// is closed, gone, or on a peer that is unreachable (`stale`) resolves too: its
/// end may never come.
/// A status of `waiting` after the turn (a background ask) does not hold it.
struct TurnEnded {
    turn_id: String,
    started_at: u64,
}

impl TurnEnded {
    fn parse(v: Option<&Value>) -> Option<Self> {
        let v = v?;
        let turn_id = v.get("turnId").and_then(Value::as_str).filter(|t| !t.is_empty())?;
        let started_at = v.get("startedAt").and_then(Value::as_u64).unwrap_or(u64::MAX);
        Some(Self { turn_id: turn_id.to_owned(), started_at })
    }

    fn matches(&self, s: &Value) -> bool {
        if s.get("status").and_then(Value::as_str) == Some("closed")
            || s.get("missing").and_then(Value::as_bool) == Some(true)
            || s.get("stale").and_then(Value::as_bool) == Some(true)
        {
            return true;
        }
        let running = s.pointer("/turn/turnId").and_then(Value::as_str);
        if running == Some(self.turn_id.as_str()) {
            return false;
        }
        let last = s.get("lastTurn").filter(|t| !t.is_null());
        let last_is = last.and_then(|t| t.get("turnId")).and_then(Value::as_str);
        let ended_at = last.and_then(|t| t.get("endedAt")).and_then(Value::as_u64);
        last_is == Some(self.turn_id.as_str())
            || ended_at.is_some_and(|at| at > self.started_at)
            || running.is_some()
    }
}

/// Params: `sessions` (keys; empty = every running or waiting session on
/// every host, and every sub-session waiting for a run slot), `until` (list; default ready+permission), `all` (wait for
/// every target instead of the first), `afterSeq` (map of session id to a
/// state sequence the resolution must exceed), `timeoutMs`, and `turnEnded`
/// (`{turnId, startedAt}`: a session also resolves once that turn ended,
/// `turnEnded`).
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
    let turn_ended = TurnEnded::parse(params.get("turnEnded"));
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
    // Counted from its subscription until it answers or its request ends.
    let _open = OpenWait::new(&hub.open_waits);
    let deadline = timeout.map(|t| tokio::time::Instant::now() + t);
    // Only the chats it waits on: summarizing every chat on every record any chat logs
    // kept huge-blue's daemon at 6 to 8 cores and 4.5 GB with 13 waits open (2026-10-22).
    // Since when each chat's row has said its failed turn's retry is being decided.
    let mut deciding: HashMap<String, tokio::time::Instant> = HashMap::new();
    let mut evaluate = |hub: &Hub| -> (Vec<Value>, Vec<Value>) {
        let now = tokio::time::Instant::now();
        let summaries = hub.session_summaries_of(&ids);
        let mut rows = Vec::new();
        let mut resolved = Vec::new();
        for id in &ids {
            // `get`, not `remove`: two keys can name one chat (its name and its id).
            let s = summaries
                .get(id)
                .cloned()
                .unwrap_or_else(|| json!({"sessionId": id, "status": "closed", "missing": true}));
            let seq_ok = after
                .get(id)
                .map(|a| s.get("stateSeq").and_then(Value::as_u64).unwrap_or(0) > *a)
                .unwrap_or(true);
            // A failed turn whose retry is not settled yet is not over for a waiter: the row
            // it answers with says whether a retry waits, and when (`retry`).
            let seq_ok = seq_ok && !holds_for_retry(&s, deciding.entry(id.clone()), now);
            let ended = turn_ended.as_ref().is_some_and(|t| t.matches(&s));
            let hit = seq_ok && (ended || until.iter().any(|u| u.matches(&s)));
            let mut row = s.clone();
            row.set("resolved", json!(hit));
            row.set(
                "matched",
                json!(
                    until
                        .iter()
                        .filter(|u| seq_ok && u.matches(&s))
                        .map(|u| format!("{u:?}").to_lowercase())
                        .chain((seq_ok && ended).then(|| "turnEnded".to_owned()))
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
        let poll = tokio::time::sleep(std::time::Duration::from_millis(1000));
        tokio::pin!(poll);
        let wake = async {
            loop {
                tokio::select! {
                    _ = &mut poll => break,
                    r = events.recv() => match r {
                        // Another chat's record changes none of these: the poll still
                        // catches a change that logs no record.
                        Ok(ev) if !concerns(&ev, &ids) => continue,
                        Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => break,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            // Daemon shutting down.
                            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                            break;
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

/// Longest a wait holds its answer for a row whose failed turn's retry is being decided. It is
/// settled within moments (`Hub::retry_row`), and its settling is recorded either way
/// (`auto_resume_scheduled`, `auto_resume_settled`), so a peer's row hears it too; this bounds
/// only a row nothing refreshes (a record its peer link lost).
const RETRY_DECIDING_MAX: Duration = Duration::from_secs(5);

/// Whether the row `s` holds the wait's answer: no turn runs and its failed turn's retry is
/// being decided (`retryDeciding`), for at most [`RETRY_DECIDING_MAX`] from when this wait
/// first saw it so (`since`, kept per chat). A closed, gone or unreachable chat holds nothing.
fn holds_for_retry(
    s: &Value,
    since: std::collections::hash_map::Entry<'_, String, tokio::time::Instant>,
    now: tokio::time::Instant,
) -> bool {
    let deciding = s["retryDeciding"] == true
        && s["turn"].is_null()
        && s["status"] != "closed"
        && s["missing"] != true
        && s["stale"] != true;
    if !deciding {
        if let std::collections::hash_map::Entry::Occupied(seen) = since {
            seen.remove();
        }
        return false;
    }
    now.duration_since(*since.or_insert(now)) < RETRY_DECIDING_MAX
}

/// Whether `ev` is a record of one of the chats `ids` names, a peer's by its id or its row's.
fn concerns(ev: &crate::hub::HubEvent, ids: &[String]) -> bool {
    let row = ev.remote.as_ref().and_then(|r| r.summary.get("sessionId")).and_then(Value::as_str);
    ids.iter().any(|id| *id == ev.session_id || Some(id.as_str()) == row)
}

/// One `_acpmux/wait` in `Hub::open_waits` while it lives.
struct OpenWait<'a>(&'a std::sync::atomic::AtomicUsize);

impl<'a> OpenWait<'a> {
    fn new(count: &'a std::sync::atomic::AtomicUsize) -> Self {
        count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Self(count)
    }
}

impl Drop for OpenWait<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

#[cfg(test)]
mod retry_deciding_tests {
    use super::*;

    /// A row whose failed turn's retry is being decided holds a wait's answer, for at most
    /// `RETRY_DECIDING_MAX` from when the wait first saw it so; any other row holds nothing.
    #[test]
    fn a_row_deciding_its_retry_holds_a_wait_for_a_bounded_time() {
        let mut since = HashMap::new();
        let t0 = tokio::time::Instant::now();
        let deciding = json!({"status": "ready", "turn": null, "retryDeciding": true});
        let mut holds = |s: &Value, at| holds_for_retry(s, since.entry("s".to_owned()), at);
        assert!(holds(&deciding, t0));
        assert!(holds(&deciding, t0 + Duration::from_secs(4)));
        assert!(!holds(&deciding, t0 + RETRY_DECIDING_MAX), "bounded");
        // Settled, then deciding again (its retry failed too): counted afresh.
        let settled = json!({"status": "ready", "turn": null, "retry": {"attempt": 1}});
        assert!(!holds(&settled, t0 + Duration::from_secs(6)));
        assert!(holds(&deciding, t0 + Duration::from_secs(7)));
        for s in [
            json!({"status": "running", "turn": {"turnId": "t2"}, "retryDeciding": true}),
            json!({"status": "closed", "turn": null, "retryDeciding": true}),
            json!({"status": "closed", "missing": true, "retryDeciding": true}),
            json!({"status": "unreachable", "stale": true, "turn": null, "retryDeciding": true}),
            json!({"status": "ready", "turn": null}),
        ] {
            let mut since = HashMap::new();
            assert!(!holds_for_retry(&s, since.entry("s".to_owned()), t0), "{s}");
        }
    }
}

#[cfg(test)]
mod turn_ended_tests {
    use super::*;

    fn ended(s: Value) -> bool {
        let t = TurnEnded::parse(Some(&json!({"turnId": "t1", "startedAt": 100}))).unwrap();
        t.matches(&s)
    }

    #[test]
    fn a_turn_has_ended_once_its_end_is_recorded_or_the_session_cannot_end_it() {
        let running = json!({"status": "running", "turn": {"turnId": "t1"}, "lastTurn": {"turnId": "t0", "endedAt": 90}});
        assert!(!ended(running), "still running");
        // Taken out of the session, its end not recorded yet: not yet.
        let between =
            json!({"status": "running", "turn": null, "lastTurn": {"turnId": "t0", "endedAt": 90}});
        assert!(!ended(between), "its end is not recorded yet");
        // The turn before it ended in the millisecond it started.
        let last = json!({"turnId": "t0", "endedAt": 100});
        let tie = json!({"status": "running", "turn": {"turnId": "t1"}, "lastTurn": last.clone()});
        assert!(!ended(tie), "it runs");
        let tie = json!({"status": "running", "turn": null, "lastTurn": last});
        assert!(!ended(tie), "its end is not recorded yet, in the same millisecond");
        let recorded = json!({"status": "waiting", "turn": null, "lastTurn": {"turnId": "t1", "endedAt": 120}});
        assert!(ended(recorded), "recorded, while a background ask waits");
        let later =
            json!({"status": "ready", "turn": null, "lastTurn": {"turnId": "t2", "endedAt": 150}});
        assert!(ended(later), "a later turn ended since");
        let next = json!({"status": "running", "turn": {"turnId": "t2"}, "lastTurn": null});
        assert!(ended(next), "another turn runs");
        assert!(ended(json!({"status": "closed", "turn": null})));
        assert!(ended(json!({"sessionId": "s", "status": "closed", "missing": true})));
        let lost = json!({"status": "unreachable", "stale": true, "turn": {"turnId": "t1"}});
        assert!(ended(lost), "its machine is unreachable");
        assert!(TurnEnded::parse(Some(&json!({"turnId": ""}))).is_none());
        assert!(TurnEnded::parse(None).is_none());
    }
}
