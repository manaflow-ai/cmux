//! A turn a connection error cut off goes on by itself (cmuxterm-hq#2503). On 2026-10-18 one
//! relay host went dark for 24 minutes and every Codex turn streaming through it failed with
//! "stream disconnected"; each chat then sat idle until a person typed "continue".
//!
//! When a turn fails with a transport error ([`super::turn_errors::is_transport_error`]), the hub waits, then sends
//! the same chat one prompt that tells the agent its last turn was cut off and to check what
//! finished before it goes on. The prompt runs through the ordinary prompt path, so the agent is
//! started or resumed as for any prompt (Claude `--resume`, Codex `thread/resume`, else the
//! restored transcript) and the turn's rules (`control`, trust gate) are checked again.
//!
//! - `autoResumeDelaysMs` in the config sets the wait before each attempt; the default
//!   [`DEFAULT_DELAYS_MS`] spans about 26 minutes. `[]` turns it off. At most
//!   [`MAX_ATTEMPTS`] entries, each between 1 s and 1 h; an entry that is not a whole number
//!   of milliseconds of 0 or more is refused with a warning and the default waits apply.
//! - Attempt `n` of the prompt `P` has the prompt id `P~resume-n`, so it runs once, across
//!   restarts too, and a continuation that fails the same way schedules attempt `n + 1`.
//! - It is skipped when anything else ran or waits in the chat meanwhile (a person's prompt,
//!   checked again under the turn lock), when the person pressed Stop or closed the chat, or
//!   when the chat is moving. A turn running when Stop or close came gets none, however it
//!   ends: an agent stopped mid-stream may still answer with a connection error. Each chat staggers its waits a little, so chats an outage cut
//!   off together do not all come back at the same moment.
//! - Its `user_message` carries `_meta.provenance = {kind: "auto_resume", promptId, attempt,
//!   turnId}` so a client can show it as acpmux's, not the person's.
//! - A continuation that completes resumes the prompts the cut turn held (`pause_queue`), and
//!   only those: they waited only because of the connection.
//! - Usage limits and sign-in failures are not transport errors: the fallback profile handles
//!   those (`turns.rs`). A daemon restart mid-turn stays `outcome_unknown` (`mod.rs`).
//! - A wait in progress is not persisted: a daemon restart during it drops the attempt.

use super::{Control, Hub, PromptOptions, Session, SessionStatus};
use crate::rpc::RpcError;
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Waits before attempts 1, 2, 3 and 4, in milliseconds.
pub const DEFAULT_DELAYS_MS: [u64; 4] = [10_000, 60_000, 300_000, 1_200_000];

/// Most attempts `autoResumeDelaysMs` may set.
pub const MAX_ATTEMPTS: usize = DEFAULT_DELAYS_MS.len();

/// Shortest and longest configured wait, in milliseconds.
const MIN_DELAY_MS: u64 = 1_000;
const MAX_DELAY_MS: u64 = 3_600_000;

/// The prompt-id suffix of an automatic continuation, before its attempt number.
const SUFFIX: &str = "~resume-";

/// Longest error text quoted to the agent, in characters.
const MAX_ERROR_CHARS: usize = 300;

/// The prompt a continuation answers for, and the attempt it is (0 for a prompt of its own).
fn split_attempt(prompt_id: &str) -> (&str, usize) {
    if let Some((root, n)) = prompt_id.rsplit_once(SUFFIX)
        && let Ok(n) = n.parse::<usize>()
        && !root.is_empty()
    {
        return (root, n);
    }
    (prompt_id, 0)
}

/// The text the agent gets.
fn continue_text(error: &str) -> String {
    let error: String = error.chars().take(MAX_ERROR_CHARS).collect();
    format!(
        "Your previous turn was cut off by a connection error ({error}). Check what already \
         finished (files, commands, messages), then continue from where it stopped. Do not \
         redo work that completed."
    )
}

/// What a failed turn needs to be continued.
pub(super) struct CutTurn<'a> {
    pub prompt_id: &'a str,
    pub turn_id: &'a str,
    pub control: Control,
    pub trust_gate: bool,
    pub error: &'a str,
}

/// What a chat's continuation state is.
enum Mark {
    /// A continuation waits to answer for this cut turn.
    Waiting(String),
    /// Stop or close came while this turn ran: it gets no continuation.
    Stopped(String),
}

/// Each chat's [`Mark`].
#[derive(Default)]
pub(crate) struct Pending(Mutex<HashMap<String, Mark>>);

impl Pending {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Mark>> {
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Whether the chat still ends on `cut_turn`: no turn runs, nothing waits that the cut turn did
/// not hold, and its last turn is that one.
pub(super) fn still_cut(session: &Session, cut_turn: &str) -> bool {
    session.turn().is_none()
        && session.queue().iter().all(|q| q.held)
        && session.meta().last_turn.as_ref().and_then(|t| t.get("turnId")).and_then(Value::as_str)
            == Some(cut_turn)
}

/// The refusal of a continuation something else in the chat overtook.
pub(super) fn superseded() -> RpcError {
    RpcError::invalid_params(
        "auto_resume.superseded: the chat moved on before the continuation ran",
    )
    .with_data(json!({"reason": "auto_resume.superseded"}))
}

/// `Err(superseded)` for a continuation (`after`) whose chat moved on, or that would wait.
pub(super) fn check_cut(
    session: &Session,
    after: Option<&str>,
    waiting: bool,
) -> Result<(), RpcError> {
    match after {
        Some(cut) if waiting || !still_cut(session, cut) => Err(superseded()),
        _ => Ok(()),
    }
}

/// Up to a fifth more than `delay`, the same for a chat each time.
fn staggered(delay: u64, session_id: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    session_id.hash(&mut h);
    delay.saturating_add(h.finish() % (delay / 5 + 1))
}

/// `autoResumeDelaysMs` as the config gives it, checked: see the module doc.
pub(crate) fn delays_from_config<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<Vec<u64>>, D::Error> {
    use serde::Deserialize;
    Ok(Option::<Value>::deserialize(d)?.and_then(|v| checked_delays(&v)))
}

fn checked_delays(v: &Value) -> Option<Vec<u64>> {
    let refuse = |why: String| -> Option<Vec<u64>> {
        tracing::warn!("autoResumeDelaysMs: {why}; using the default waits");
        None
    };
    let Some(items) = v.as_array() else {
        return refuse(format!("{v} is not a list of milliseconds"));
    };
    let mut delays = Vec::with_capacity(items.len());
    for item in items {
        let Some(ms) = item.as_u64() else {
            return refuse(format!("{item} is not a whole number of milliseconds of 0 or more"));
        };
        delays.push(ms.clamp(MIN_DELAY_MS, MAX_DELAY_MS));
    }
    if delays.len() > MAX_ATTEMPTS || delays.iter().zip(items).any(|(d, i)| i.as_u64() != Some(*d))
    {
        delays.truncate(MAX_ATTEMPTS);
        tracing::warn!(
            "autoResumeDelaysMs: kept to {MAX_ATTEMPTS} attempts of 1 s to 1 h each: {delays:?}"
        );
    }
    Some(delays)
}

impl Hub {
    /// Schedules the next continuation of a turn that failed with a transport error. Nothing
    /// for any other failure, or once the configured attempts are used.
    pub(super) fn schedule_auto_resume(self: &Arc<Self>, session: &Arc<Session>, cut: CutTurn<'_>) {
        if !super::turn_errors::is_transport_error(cut.error) {
            return;
        }
        let (root, done) = split_attempt(cut.prompt_id);
        let (root, turn_id, error) =
            (root.to_owned(), cut.turn_id.to_owned(), cut.error.to_owned());
        let (control, trust_gate) = (cut.control, cut.trust_gate);
        self.auto_resumes.lock().insert(session.id.clone(), Mark::Waiting(turn_id.clone()));
        let (hub, session) = (self.clone(), session.clone());
        // Off the turn's path: the turn lock is still held here.
        tokio::spawn(async move {
            let delays = {
                let cfg = hub.config.read().await;
                cfg.auto_resume_delays_ms.clone().unwrap_or_else(|| DEFAULT_DELAYS_MS.to_vec())
            };
            let Some(&delay) = delays.get(done) else {
                hub.take_pending(&session, &turn_id);
                if done > 0 {
                    let msg = json!({"promptId": root, "attempts": done, "turnId": turn_id});
                    hub.append(&session, "mux", "auto_resume_exhausted", msg);
                }
                return;
            };
            let attempt = done + 1;
            let delay = staggered(delay, &session.id);
            let msg =
                json!({"promptId": root, "attempt": attempt, "turnId": turn_id, "delayMs": delay});
            hub.append(&session, "mux", "auto_resume_scheduled", msg);
            tokio::time::sleep(Duration::from_millis(delay)).await;
            let cut =
                CutTurn { prompt_id: &root, turn_id: &turn_id, control, trust_gate, error: &error };
            hub.auto_resume(&session, cut, attempt).await;
        });
    }

    /// Stop or close: the chat's waiting continuation does not fire, and the turn running
    /// now gets none, however it ends.
    pub(super) fn stop_auto_resume(&self, session: &Session) {
        let mut pending = self.auto_resumes.lock();
        match session.turn() {
            Some(t) => pending.insert(session.id.clone(), Mark::Stopped(t.turn_id)),
            None => pending.remove(&session.id),
        };
    }

    /// Whether Stop or close came while `turn_id` ran. Clears that mark.
    pub(super) fn take_stopped(&self, session: &Session, turn_id: &str) -> bool {
        let mut pending = self.auto_resumes.lock();
        let stopped = matches!(pending.get(&session.id), Some(Mark::Stopped(t)) if t == turn_id);
        if stopped {
            pending.remove(&session.id);
        }
        stopped
    }

    /// Takes the chat's waiting continuation when it still answers for `cut_turn`.
    fn take_pending(&self, session: &Session, cut_turn: &str) -> bool {
        let mut pending = self.auto_resumes.lock();
        let ours = matches!(pending.get(&session.id), Some(Mark::Waiting(t)) if t == cut_turn);
        if ours {
            pending.remove(&session.id);
        }
        ours
    }

    /// Sends attempt `attempt` (`cut.prompt_id` is the root prompt) when the chat still ends
    /// on the cut turn.
    async fn auto_resume(
        self: &Arc<Self>,
        session: &Arc<Session>,
        cut: CutTurn<'_>,
        attempt: usize,
    ) {
        let (root, cut_turn) = (cut.prompt_id, cut.turn_id);
        let skipped = |why: &str| json!({"promptId": root, "attempt": attempt, "turnId": cut_turn, "skipped": why});
        if !self.take_pending(session, cut_turn) {
            self.append(session, "mux", "auto_resume_skipped", skipped("stopped"));
            return;
        }
        if session.status() == SessionStatus::Closed || session.moving().is_some() {
            self.append(session, "mux", "auto_resume_skipped", skipped("closed"));
            return;
        }
        if !still_cut(session, cut_turn) {
            self.append(session, "mux", "auto_resume_skipped", skipped("superseded"));
            return;
        }
        let held = self.held_by(session, cut_turn);
        let provenance = json!({"kind": "auto_resume", "promptId": root, "attempt": attempt, "turnId": cut_turn});
        let opts = PromptOptions {
            prompt_id: Some(format!("{root}{SUFFIX}{attempt}")),
            resend: true,
            control: cut.control,
            trust_gate: cut.trust_gate,
            provenance: Some(provenance),
            after_turn: Some(cut_turn.to_owned()),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": continue_text(cut.error)})];
        match self.prompt_with(session, blocks, "acpmux", false, opts).await {
            Ok(v) if v.get("stopReason").and_then(Value::as_str) != Some("cancelled") => {
                self.resume_held(session, &held);
            }
            Ok(_) => {}
            Err(e)
                if e.data.as_ref().and_then(|d| d.get("reason"))
                    == Some(&json!("auto_resume.superseded")) =>
            {
                self.append(session, "mux", "auto_resume_skipped", skipped("superseded"));
            }
            // A failure that is itself a transport error scheduled the next attempt.
            Err(e) => tracing::warn!(session = %session.id, attempt, "auto resume: {}", e.message),
        }
    }

    /// The prompts `cut_turn` held (its `queue_paused` record).
    fn held_by(&self, session: &Session, cut_turn: &str) -> Vec<String> {
        let mut held = Vec::new();
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            if e.kind == "queue_paused"
                && e.msg.get("turnId").and_then(Value::as_str) == Some(cut_turn)
            {
                held = e
                    .msg
                    .get("held")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect();
            }
            true
        });
        held
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attempts_are_counted_from_the_prompt_id() {
        assert_eq!(split_attempt("p1"), ("p1", 0));
        assert_eq!(split_attempt("p1~resume-1"), ("p1", 1));
        assert_eq!(split_attempt("p1~resume-3"), ("p1", 3));
        assert_eq!(split_attempt("~resume-2"), ("~resume-2", 0));
        assert_eq!(split_attempt("p1~resume-x"), ("p1~resume-x", 0));
    }

    #[test]
    fn configured_waits_are_checked() {
        assert_eq!(checked_delays(&json!([])), Some(vec![]));
        assert_eq!(checked_delays(&json!([5000, 60000])), Some(vec![5000, 60000]));
        assert_eq!(checked_delays(&json!([0, 99_999_999])), Some(vec![1_000, 3_600_000]));
        assert_eq!(checked_delays(&json!([1000, 1000, 1000, 1000, 1000])).unwrap().len(), 4);
        assert_eq!(checked_delays(&json!([1000, -5])), None);
        assert_eq!(checked_delays(&json!([1.5])), None);
        assert_eq!(checked_delays(&json!("10s")), None);
        assert_eq!(staggered(u64::MAX, "s"), u64::MAX);
    }
}
