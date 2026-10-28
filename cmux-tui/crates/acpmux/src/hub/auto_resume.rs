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
//!   ends: an agent stopped mid-stream may still answer with a connection error. The turn's
//!   end and Stop's check share one lock, so a Stop after the turn ended but before its
//!   continuation is scheduled counts too, and so does one after the continuation fired but
//!   before its turn started. Each chat staggers its waits a little, so chats an
//!   outage cut off together do not all come back at the same moment.
//! - Its `user_message` carries `_meta.provenance = {kind: "auto_resume", promptId, attempt,
//!   turnId}` so a client can show it as acpmux's, not the person's.
//! - A continuation that completes resumes the prompts the cut turn held (`pause_queue`), and
//!   only those: they waited only because of the connection. A failed attempt holds nothing
//!   new (the cut turn already holds them), so attempt `n` follows the attempts before it back
//!   to the turn the connection first cut, and resumes what each of those held.
//! - Usage limits and sign-in failures are not transport errors: the fallback profile handles
//!   those (`turns.rs`). A daemon restart mid-turn stays `outcome_unknown` (`mod.rs`).
//! - A wait in progress is not persisted: a daemon restart during it drops the attempt.

use super::{
    Control, Fatal, Hub, PromptOptions, Session, SessionStatus, ShutdownBehavior, TurnInfo,
};
use crate::rpc::RpcError;
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
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
    let cause = if error.starts_with("agent process closed") {
        "an agent process exit"
    } else {
        "a connection error"
    };
    format!(
        "Your previous turn was cut off by {cause} ({error}). Check what already \
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
    /// The continuation of this cut turn fired and has not started its turn yet; Stop or
    /// close now still counts for it.
    Firing(String),
    /// This turn has ended and whether it is continued is not settled yet; Stop or close now
    /// still counts for it.
    Ending(String),
    /// Stop or close came while this turn ran or was ending: it gets no continuation.
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

/// The refusal of a continuation Stop or close overtook after it fired.
fn stopped() -> RpcError {
    RpcError::invalid_params("auto_resume.stopped: Stop or close came before the continuation ran")
        .with_data(json!({"reason": "auto_resume.stopped"}))
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

impl TurnInfo {
    /// The turn a prompt starts (`run_prompt`), before its `turn_started` record gives its seq.
    pub(super) fn prompted(
        client: &str,
        text: &str,
        turn_id: &str,
        prompt_id: &str,
        control: Control,
    ) -> Self {
        TurnInfo {
            started_at: super::now_ms(),
            client: client.to_owned(),
            prompt_preview: super::short_text(text, 200),
            masked_preview: super::session::masked_preview(text, 200),
            turn_id: turn_id.to_owned(),
            prompt_id: prompt_id.to_owned(),
            turn_seq: 0,
            control,
            doing: Default::default(),
        }
    }
}

impl Hub {
    /// Ends the chat's turn (`finish_turn`): takes it, and marks `turn_id` as ending, in one
    /// step with Stop's check, so a Stop between the turn's end and its scheduling counts.
    pub(super) fn take_turn(&self, session: &Session, turn_id: &str) -> Option<super::TurnInfo> {
        let mut pending = self.auto_resumes.lock();
        let turn = session.turn.lock().unwrap_or_else(|e| e.into_inner()).take();
        let stopped = matches!(pending.get(&session.id), Some(Mark::Stopped(t)) if t == turn_id);
        if turn.as_ref().is_some_and(|t| t.turn_id == turn_id) && !stopped {
            pending.insert(session.id.clone(), Mark::Ending(turn_id.to_owned()));
        }
        turn
    }

    /// Settles whether the ended turn `turn_id` is continued: it is when `cut` is a transport
    /// error or agent death and no Stop or close came since it began. Nothing for any other failure, or once
    /// the configured attempts are used.
    pub(super) fn schedule_auto_resume(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn_id: &str,
        cut: Option<CutTurn<'_>>,
    ) {
        let mut pending = self.auto_resumes.lock();
        let ending = match pending.get(&session.id) {
            Some(Mark::Ending(t)) if t == turn_id => Some(true),
            Some(Mark::Stopped(t)) if t == turn_id => Some(false),
            _ => None,
        };
        let Some(cut) = cut.filter(|c| {
            ending == Some(true) && super::turn_errors::resume_cause(c.error, c.error).is_some()
        }) else {
            if ending.is_some() {
                pending.remove(&session.id);
            }
            return;
        };
        pending.insert(session.id.clone(), Mark::Waiting(turn_id.to_owned()));
        drop(pending);
        let (root, done) = split_attempt(cut.prompt_id);
        let (root, turn_id, error) =
            (root.to_owned(), cut.turn_id.to_owned(), cut.error.to_owned());
        let (control, trust_gate) = (cut.control, cut.trust_gate);
        let (hub, session) = (self.clone(), session.clone());
        // Off the turn's path: the turn lock is still held here.
        self.supervise("hub.auto-resume", Fatal, ShutdownBehavior::Skip, async move {
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

    /// Whether a continuation may still answer for the chat's cut turn: it releases what that
    /// turn held, so a held agent message's own retry waits for it (`digest.rs`).
    pub(super) fn continuation_pending(&self, session: &Session) -> bool {
        matches!(
            self.auto_resumes.lock().get(&session.id),
            Some(Mark::Waiting(_) | Mark::Firing(_) | Mark::Ending(_))
        )
    }

    /// Stop or close: the chat's waiting continuation does not fire, and the turn running or
    /// ending now gets none, however it ends.
    pub(super) fn stop_auto_resume(&self, session: &Session) {
        let mut pending = self.auto_resumes.lock();
        let ending = match pending.get(&session.id) {
            Some(Mark::Ending(t) | Mark::Firing(t)) => Some(t.clone()),
            _ => None,
        };
        match session.turn().map(|t| t.turn_id).or(ending) {
            Some(t) => pending.insert(session.id.clone(), Mark::Stopped(t)),
            None => pending.remove(&session.id),
        };
    }

    /// Starts the chat's turn (`run_prompt`). A continuation (`after` its cut turn) that Stop
    /// or close overtook since it fired is refused instead, in one step with Stop's check.
    pub(super) fn start_turn(
        &self,
        session: &Session,
        after: Option<&str>,
        turn: super::TurnInfo,
    ) -> Result<(), RpcError> {
        let mut pending = self.auto_resumes.lock();
        if let Some(cut) = after {
            let mark = match pending.get(&session.id) {
                Some(Mark::Firing(t)) if t == cut => Some(true),
                Some(Mark::Stopped(t)) if t == cut => Some(false),
                _ => None,
            };
            if mark.is_some() {
                pending.remove(&session.id);
            }
            if mark == Some(false) {
                return Err(stopped());
            }
        }
        *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = Some(turn);
        Ok(())
    }

    /// Fires the chat's waiting continuation when it still answers for `cut_turn`: its mark
    /// stays, as firing, until its turn starts.
    fn fire_pending(&self, session: &Session, cut_turn: &str) -> bool {
        let mut pending = self.auto_resumes.lock();
        let ours = matches!(pending.get(&session.id), Some(Mark::Waiting(t)) if t == cut_turn);
        if ours {
            pending.insert(session.id.clone(), Mark::Firing(cut_turn.to_owned()));
        }
        ours
    }

    /// Drops what is left of a continuation of `cut_turn` that did not start its turn.
    fn clear_fired(&self, session: &Session, cut_turn: &str) {
        let mut pending = self.auto_resumes.lock();
        if matches!(pending.get(&session.id), Some(Mark::Firing(t) | Mark::Stopped(t)) if t == cut_turn)
        {
            pending.remove(&session.id);
        }
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
        if !self.fire_pending(session, cut_turn) {
            // Stop or close took it, or a newer turn replaced it.
            let why = if still_cut(session, cut_turn) { "stopped" } else { "superseded" };
            self.append(session, "mux", "auto_resume_skipped", skipped(why));
            return;
        }
        if session.status() == SessionStatus::Closed || session.moving().is_some() {
            self.clear_fired(session, cut_turn);
            self.append(session, "mux", "auto_resume_skipped", skipped("closed"));
            return;
        }
        if !still_cut(session, cut_turn) {
            self.clear_fired(session, cut_turn);
            self.append(session, "mux", "auto_resume_skipped", skipped("superseded"));
            return;
        }
        let held = self.held_by(session, root, cut_turn);
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
        let result = self.prompt_with(session, blocks, "acpmux", false, opts).await;
        self.clear_fired(session, cut_turn);
        match result {
            Ok(v) if v.get("stopReason").and_then(Value::as_str) != Some("cancelled") => {
                self.resume_held(session, &held);
            }
            Ok(_) => {}
            Err(e) => match e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str) {
                Some(why @ ("auto_resume.superseded" | "auto_resume.stopped")) => {
                    let why = why.trim_start_matches("auto_resume.");
                    self.append(session, "mux", "auto_resume_skipped", skipped(why));
                }
                // A failure that is itself a transport error scheduled the next attempt.
                _ => tracing::warn!(session = %session.id, attempt, "auto resume: {}", e.message),
            },
        }
    }

    /// The prompts `cut_turn` held (its `queue_paused` record), and those the turns it
    /// continues held: back through the earlier attempts at `root` to the turn the connection
    /// first cut. A failed attempt writes no record of its own when the prompts behind it were
    /// already held, so its continuation finds them on the turn before.
    fn held_by(&self, session: &Session, root: &str, cut_turn: &str) -> Vec<String> {
        let mut paused: HashMap<String, Vec<String>> = HashMap::new();
        // An attempt's turn, and the turn it continues.
        let mut continues: HashMap<String, String> = HashMap::new();
        let _ = self.store.scan(&session.id, 0, &mut |e: EventRecord| {
            let Some(turn) = e.msg.get("turnId").and_then(Value::as_str) else { return true };
            match e.kind.as_str() {
                "queue_paused" => {
                    let ids = e.msg.get("held").and_then(Value::as_array).into_iter().flatten();
                    let ids = ids.filter_map(|v| v.as_str().map(str::to_owned)).collect();
                    paused.insert(turn.to_owned(), ids);
                }
                "user_message" => {
                    let p = e.msg.pointer("/_meta/provenance");
                    let field = |k: &str| p.and_then(|p| p.get(k)).and_then(Value::as_str);
                    if field("kind") == Some("auto_resume")
                        && field("promptId") == Some(root)
                        && let Some(cut) = field("turnId")
                    {
                        continues.insert(turn.to_owned(), cut.to_owned());
                    }
                }
                _ => {}
            }
            true
        });
        let (mut held, mut seen) = (Vec::new(), HashSet::new());
        let mut turn = Some(cut_turn);
        while let Some(t) = turn.filter(|t| seen.insert(*t)) {
            for id in paused.get(t).into_iter().flatten() {
                if !held.contains(id) {
                    held.push(id.clone());
                }
            }
            turn = continues.get(t).map(String::as_str);
        }
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
