//! A turn a connection error cut off goes on by itself (cmuxterm-hq#2503). On 2026-10-18 one
//! relay host went dark for 24 minutes and every Codex turn streaming through it failed with
//! "stream disconnected"; each chat then sat idle until a person typed "continue". A turn the
//! provider or the SR2 gateway had no capacity for goes on the same way (subsession-card,
//! 2026-10-26: five helpers died on "API Error: 503 no non-exhausted claude accounts").
//!
//! When a turn fails with a transient error ([`super::turn_errors::resume_cause`]: `capacity`,
//! `transport` or `agent_exited`), the hub waits, then sends
//! the same chat one prompt that tells the agent its last turn was cut off and to check what
//! finished before it goes on. The prompt runs through the ordinary prompt path, so the agent is
//! started or resumed as for any prompt (Claude `--resume`, Codex `thread/resume`, else the
//! restored transcript) and the turn's rules (`control`, trust gate) are checked again.
//!
//! - `autoResumeDelaysMs` in the config is the whole loop: one entry per attempt, each the wait
//!   before it, so its length says how many attempts run ([`configured_attempts`]) on every path
//!   that continues a cut turn, a chain of daemon restarts included (`restart_resume.rs`). The
//!   default [`DEFAULT_DELAYS_MS`] is four attempts spanning about 26 minutes; `[]` turns it off.
//!   At most [`MAX_CONFIGURED_ATTEMPTS`] entries, each between 1 s and 1 h; an entry that is not
//!   a whole number of milliseconds of 0 or more is refused with a warning and the default
//!   waits apply.
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
//! - While a continuation waits, the session row's `retry` says so (`{attempt, of, reason,
//!   nextAt, promptId, turnId}`, [`Hub::retry_row`]); it is null once the attempt fires, is
//!   skipped or is used up, and from Stop or close on. `auto_resume_scheduled` carries the same
//!   `of`, `reason` and `nextAt`; `auto_resume_exhausted` its `reason`. The wait's timer ends
//!   when its delay does, or at once when its mark goes (Stop, close, a turn that took the chat):
//!   it then records the skip. An attempt refused before its turn starts (its folder gone, a
//!   dispatch check) records `auto_resume_skipped` `refused` with the `error`.
//! - From the end of a turn that failed on such an error until its retry's wait is set (or it
//!   is settled that none comes), and while that retry starts and runs, the row says
//!   `retryDeciding` ([`Hub::retry_row`]): `_acpmux/wait` answers for that turn only once it
//!   is settled, so the row it answers with names the retry that waits, if one does. A
//!   decision for no retry records `auto_resume_settled` `{turnId, why}`, so a peer that keeps
//!   the row hears it too.
//! - A capacity error does not hop to the fallback profile: the SR2 pool reports it, and a 529
//!   is the provider's whatever account asks, so the session waits where it is.
//! - A continuation that completes resumes the prompts the cut turn held (`pause_queue`), and
//!   only those: they waited only because of the connection. A failed attempt holds nothing
//!   new (the cut turn already holds them), so attempt `n` follows the attempts before it back
//!   to the turn the connection first cut, and resumes what each of those held.
//! - Usage limits and sign-in failures are not transport errors: the fallback profile handles
//!   those (`turns.rs`). A daemon restart mid-turn settles the turn `outcome_unknown` (`mod.rs`)
//!   and queues its continuation first in the chat's queue (`restart_resume.rs`).
//! - A wait in progress is restored from its scheduled record at the original deadline
//!   (`restore.rs`); its stable prompt id still admits that attempt only once.
//! - `_acpmux/retry` retries a failed turn on demand, taking over a continuation that waits
//!   ([`retry_turn`]).
//! - A chat's first send that a revoked OAuth token failed is sent again once, 2 s later, through
//!   the same mark ([`first_send`]).

use cmux_json::JsonSet as _;

// A turn a daemon restart cut off is continued from the restored queue.
pub(super) mod reset_hint;
#[path = "restart_resume.rs"]
mod restart_resume;
pub(in crate::hub) use restart_resume::Cut;
mod restore;

use super::{Control, Hub, PromptOptions, Session, SessionStatus, TurnInfo};
use crate::rpc::RpcError;
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;

use crate::protocol::session::{RetryReason, RetrySummary};

#[cfg(test)]
thread_local! {
    static AFTER_FINISH_REPLACED_CHECK: std::cell::RefCell<Option<Box<dyn FnOnce()>>> = const {
        std::cell::RefCell::new(None)
    };
}

#[cfg(test)]
fn after_finish_replaced_check() {
    let hook = AFTER_FINISH_REPLACED_CHECK.with(|slot| slot.borrow_mut().take());
    if let Some(hook) = hook {
        hook();
    }
}

#[cfg(test)]
pub(super) fn set_after_finish_replaced_check(hook: Box<dyn FnOnce()>) {
    AFTER_FINISH_REPLACED_CHECK.with(|slot| *slot.borrow_mut() = Some(hook));
}

/// `_acpmux/retry`: a failed turn retried on demand.
pub(crate) mod retry_turn;

/// A first send a revoked OAuth token failed goes again once, 2 s later.
mod first_send;

/// Whether a failed turn's `error` is one acpmux may retry by itself: a transient one
/// ([`super::turn_errors::resume_cause`]), or a revoked token, which a chat's first send retries
/// ([`first_send`]). A row shows such a turn's retry being decided until that is settled.
fn retry_decided_on(error: &str) -> bool {
    super::turn_errors::resume_cause(error, error).is_some() || first_send::retried_error(error)
}

/// Waits before attempts 1, 2, 3 and 4, in milliseconds.
pub const DEFAULT_DELAYS_MS: [u64; 4] = [10_000, 60_000, 300_000, 1_200_000];

/// Most attempts `autoResumeDelaysMs` may set. The default's four span about 26 minutes, which a
/// capacity outage outlives; twelve entries of up to an hour each let a configured loop ride one
/// out, and still bound the attempt a prompt id's suffix carries and what one cut turn writes to
/// the log. Never a floor on the default, which stays four.
pub const MAX_CONFIGURED_ATTEMPTS: usize = 12;

/// How many attempts the configured waits allow, for a chain of daemon restarts as for a turn a
/// transport cut: one per wait, or the default's four when the config says nothing. 0 (`[]`)
/// turns it off.
pub(in crate::hub) fn configured_attempts(delays: Option<&Vec<u64>>) -> usize {
    delays.map_or(DEFAULT_DELAYS_MS.len(), Vec::len)
}

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

/// The text the agent gets; `reason` is the failure's [`super::turn_errors::resume_cause`].
fn continue_text(error: &str, reason: &str) -> String {
    let error: String = error.chars().take(MAX_ERROR_CHARS).collect();
    let cause = match reason {
        "agent_exited" => "an agent process exit",
        "capacity" => "a capacity error upstream (the provider or the gateway was full)",
        "transport" => "a connection error",
        _ => "an error",
    };
    format!(
        "Your previous turn was cut off by {cause} ({error}). Check what already \
         finished (files, commands, messages), then continue from where it stopped. Do not \
         redo work that completed."
    )
}

/// The cut turn whose retry decision Stop settles when it takes the chat's `mark`: one whose
/// turn ended and is not settled yet (`Ending`), or whose retry waits, its time set or not.
/// A retry that fired or a turn that runs records its own end.
fn settled_by_stop(mark: Option<&Mark>) -> Option<String> {
    match mark {
        Some(Mark::Ending(turn) | Mark::Waiting { turn, .. }) => Some(turn.clone()),
        _ => None,
    }
}

/// How many times [`settled_retry_row`] reads a chat's mark for one row.
const ROW_READS: usize = 3;

/// The row's `retry` and `retryDeciding` from `snapshot` (one read of the chat's mark: the
/// retry that waits with its cut turn, and whether it is being decided). A waiting retry counts
/// once `still_cut` holds for its cut turn, after the mark's lock is dropped. When it does not,
/// the mark may have moved on meanwhile (the retry fired and its turn started), so the mark is
/// read again, up to [`ROW_READS`] times: a row never shows neither a retry nor its decision
/// while one starts (Codex review). A retry a newer turn superseded reads as none.
fn settled_retry_row(
    mut snapshot: impl FnMut() -> (Option<(String, RetrySummary)>, bool),
    mut still_cut: impl FnMut(&str) -> bool,
) -> (Option<RetrySummary>, bool) {
    let mut deciding = false;
    for _ in 0..ROW_READS {
        let (waiting, now_deciding) = snapshot();
        deciding = now_deciding;
        match waiting {
            Some((cut_turn, retry)) if still_cut(&cut_turn) => return (Some(retry), deciding),
            Some(_) => continue,
            None => break,
        }
    }
    (None, deciding)
}

/// What a failed turn needs to be continued.
pub(super) struct CutTurn<'a> {
    /// The family sender its prompt spoke for (`subsession_guard::is_family`); its
    /// continuation speaks for it too, and is checked as its message.
    pub from: Option<&'a str>,
    pub prompt_id: &'a str,
    pub turn_id: &'a str,
    pub control: Control,
    pub trust_gate: bool,
    pub error: &'a str,
    pub not_before: Option<u64>,
}

/// A waiting continuation's timer: its mark going wakes it (`Drop`), so Stop, close or a turn
/// that took the chat end the wait at once instead of when its delay would.
struct Wake(Arc<Notify>);

impl Drop for Wake {
    fn drop(&mut self) {
        self.0.notify_one();
    }
}

/// What a chat's continuation state is.
enum Mark {
    /// A continuation waits to answer for this cut turn; `retry` once its wait is set.
    Waiting { turn: String, retry: Option<RetrySummary>, _wake: Wake },
    /// The continuation of this cut turn fired and has not started its turn yet; Stop or
    /// close now still counts for it.
    Firing(String),
    /// This turn has ended and whether it is continued is not settled yet; Stop or close now
    /// still counts for it.
    Ending(String),
    /// Stop or close came while this turn ran or was ending: it gets no continuation.
    Stopped(String),
    /// Stop or close came after a continuation or retry of this cut turn fired and before its
    /// turn started: its turn never starts, and its task alone clears this (`clear_fired`), so
    /// the chat's retry (`retry_turn.rs`) waits for that task to end.
    Stopping(String),
}

/// The retry state of one session instance; returning imports have their own mark.
pub(crate) struct Pending {
    mark: Mutex<Option<Mark>>,
    #[cfg(test)]
    stop_locked: Mutex<Option<std::sync::mpsc::Sender<()>>>,
    #[cfg(test)]
    take_entered: Mutex<Option<std::sync::mpsc::Sender<()>>>,
    /// Counts the times a continuation stopped being pending (`continuation_pending`): the
    /// inbox's timer, put off while one was, looks again then (`inbox.rs`).
    released: tokio::sync::watch::Sender<u64>,
}

impl Default for Pending {
    fn default() -> Self {
        Self {
            mark: Mutex::default(),
            released: tokio::sync::watch::channel(0).0,
            #[cfg(test)]
            stop_locked: Mutex::default(),
            #[cfg(test)]
            take_entered: Mutex::default(),
        }
    }
}

/// Whether `mark` is a continuation that may still fire (`continuation_pending`).
fn is_pending(mark: Option<&Mark>) -> bool {
    matches!(mark, Some(Mark::Waiting { .. } | Mark::Firing(_) | Mark::Ending(_)))
}

impl Pending {
    fn lock(&self) -> PendingGuard<'_> {
        let mark = self.mark.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let was = is_pending(mark.as_ref());
        PendingGuard { mark, was, released: &self.released }
    }

    /// Changes each time a pending continuation is let go, however it went: settled, stopped,
    /// exhausted, refused or started.
    pub(super) fn released(&self) -> tokio::sync::watch::Receiver<u64> {
        self.released.subscribe()
    }
}

/// The mark, locked; letting go of a pending continuation is announced as the lock is.
struct PendingGuard<'a> {
    mark: std::sync::MutexGuard<'a, Option<Mark>>,
    was: bool,
    released: &'a tokio::sync::watch::Sender<u64>,
}

impl std::ops::Deref for PendingGuard<'_> {
    type Target = Option<Mark>;
    fn deref(&self) -> &Option<Mark> {
        &self.mark
    }
}

impl std::ops::DerefMut for PendingGuard<'_> {
    fn deref_mut(&mut self) -> &mut Option<Mark> {
        &mut self.mark
    }
}

impl Drop for PendingGuard<'_> {
    fn drop(&mut self) {
        if self.was && !is_pending(self.mark.as_ref()) {
            self.released.send_modify(|n| *n = n.wrapping_add(1));
        }
    }
}

/// Whether the chat still ends on `cut_turn`: no turn runs, nothing waits that the cut turn did
/// not hold, and its last turn is that one.
pub(super) fn still_cut(session: &Session, cut_turn: &str) -> bool {
    session.turn().is_none()
        && session.queue().iter().all(|q| q.aside())
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
pub(super) fn stopped() -> RpcError {
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
pub(super) fn staggered(delay: u64, session_id: &str) -> u64 {
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
    if delays.len() > MAX_CONFIGURED_ATTEMPTS
        || delays.iter().zip(items).any(|(d, i)| i.as_u64() != Some(*d))
    {
        delays.truncate(MAX_CONFIGURED_ATTEMPTS);
        tracing::warn!(
            "autoResumeDelaysMs: kept to {MAX_CONFIGURED_ATTEMPTS} attempts of 1 s to 1 h each: {delays:?}"
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
            trigger: false,
            started_at: super::now_ms(),
            client: client.to_owned(),
            prompt_preview: super::short_text(text, 200),
            masked_preview: String::new(),
            turn_id: turn_id.to_owned(),
            prompt_id: prompt_id.to_owned(),
            turn_seq: 0,
            control,
            doing: Default::default(),
            notice: false,
            persons: false,
        }
        .shown_as(&super::prompt_line::prompt_line(text, client, None))
    }

    /// The turn, marked as one the person's own prompt started, or not ([`TurnInfo::persons`]).
    pub(super) fn by_person(mut self, persons: bool) -> Self {
        self.persons = persons;
        self
    }

    /// The turn with `line` as the line its prompt leaves on the summary (`prompt_line.rs`): a
    /// prompt's turn names it from the prompt's provenance (`turns.rs`), which `prompted` lacks.
    pub(super) fn shown_as(mut self, line: &str) -> Self {
        self.show(line);
        self
    }

    /// The turn with `notice` as whether its prompt is acpmux's notice (`TurnInfo::notice`).
    pub(super) fn noticed(mut self, notice: bool) -> Self {
        self.notice = notice;
        self
    }

    /// Sets the line its prompt leaves on the summary ([`TurnInfo::shown_as`]): masked, then cut
    /// to 200 characters. A line it gave comes back the same (`promptLine` on a restart).
    pub(super) fn show(&mut self, line: &str) {
        self.masked_preview = shown_line(line);
    }
}

/// `line` as a turn's summary shows it ([`TurnInfo::show`]): its secrets masked, then cut.
pub(super) fn shown_line(line: &str) -> String {
    super::session::masked_preview(line, 200)
}

impl Hub {
    /// Mark an outgoing session before its durable store is staged. The admission lock order is
    /// `auto_resume -> append_lock -> turn` for completion and replacement; attestation takes
    /// `append_lock -> turn` and never `auto_resume`. The replacement fence takes both locks in
    /// that order, so it cannot pass a `replaced` check and then race a terminal retry append.
    pub(super) fn seal_retry_replacement(&self, session: &Session) {
        let _retry = session.auto_resume.lock();
        let _append = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        session.replaced.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Ends the chat's turn (`finish_turn`): takes it, and marks `turn_id` as ending, in one
    /// step with Stop's check, so a Stop between the turn's end and its scheduling counts.
    /// When it took `turn_id`, the turn `next` starts in its place in the same step, so no prompt
    /// finds the chat idle between them (`carried_turn.rs`).
    pub(super) fn take_turn(
        &self,
        session: &Session,
        turn_id: &str,
        next: Option<super::TurnInfo>,
    ) -> Option<super::TurnInfo> {
        #[cfg(test)]
        if let Some(entered) =
            session.auto_resume.take_entered.lock().unwrap_or_else(|e| e.into_inner()).take()
        {
            let _ = entered.send(());
        }
        let mut pending = session.auto_resume.lock();
        // Stop and retry journal writes take auto_resume before append_lock. Keep that
        // order here too: taking append_lock in finish_turn before this retry lock
        // deadlocks against Stop. Attestation still shares the turn-clear boundary.
        let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        let turn = {
            let mut running = session.turn.lock().unwrap_or_else(|e| e.into_inner());
            let turn = running.take();
            if turn.as_ref().is_some_and(|t| t.turn_id == turn_id) {
                *running = next;
            }
            turn
        };
        let stopped = matches!(pending.as_ref(), Some(Mark::Stopped(t)) if t == turn_id);
        let took = turn.as_ref().is_some_and(|t| t.turn_id == turn_id);
        let carried_to = session
            .turn
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(|t| t.turn_id.clone());
        match carried_to.filter(|_| took) {
            // A Stop of the turn holds for the turn its agent runs on into (`carried_turn.rs`):
            // no continuation either.
            Some(next) if stopped => {
                pending.replace(Mark::Stopped(next));
            }
            _ if took && !stopped => {
                pending.replace(Mark::Ending(turn_id.to_owned()));
            }
            _ => {}
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
        // Once a shutdown began none waits here to fire: a cut it hands on is the next daemon's
        // to continue (`restart_resume.rs`), and Quit Everything continues nothing.
        let cut = cut.filter(|_| !self.shutting_down());
        let mut pending = session.auto_resume.lock();
        let ending = match pending.as_ref() {
            Some(Mark::Ending(t)) if t == turn_id => Some(true),
            Some(Mark::Stopped(t)) if t == turn_id => Some(false),
            _ => None,
        };
        let reason = cut.as_ref().and_then(|c| super::turn_errors::resume_cause(c.error, c.error));
        let reason = reason.and_then(RetryReason::from_cause);
        // A first send a revoked token failed: sent again once, its wait this mark's.
        if let (Some(cut), None, Some(true)) = (cut.as_ref(), reason, ending)
            && first_send::retries(session, cut)
        {
            let wake = Arc::new(Notify::new());
            let mark =
                Mark::Waiting { turn: turn_id.to_owned(), retry: None, _wake: Wake(wake.clone()) };
            pending.replace(mark);
            drop(pending);
            self.retry_first_send(session, cut, wake);
            return;
        }
        let (Some(cut), Some(reason), Some(true)) = (cut, reason, ending) else {
            if ending.is_some() {
                pending.take();
                drop(pending);
                // Stopped: Stop recorded it when it took the mark (`stop_auto_resume`).
                if ending == Some(true) {
                    self.settled_unretried(session, turn_id, "not_retried");
                }
            }
            return;
        };
        let wake = Arc::new(Notify::new());
        let mark =
            Mark::Waiting { turn: turn_id.to_owned(), retry: None, _wake: Wake(wake.clone()) };
        pending.replace(mark);
        drop(pending);
        let (root, done) = split_attempt(cut.prompt_id);
        let (root, turn_id, error) =
            (root.to_owned(), cut.turn_id.to_owned(), cut.error.to_owned());
        let (control, trust_gate, not_before) = (cut.control, cut.trust_gate, cut.not_before);
        let from = cut.from.map(str::to_owned);
        let (hub, session) = (self.clone(), session.clone());
        // Off the turn's path: the turn lock is still held here.
        tokio::spawn(async move {
            let delays = {
                let cfg = hub.config.read().await;
                cfg.auto_resume_delays_ms.clone().unwrap_or_else(|| DEFAULT_DELAYS_MS.to_vec())
            };
            let Some(&delay) = delays.get(done) else {
                let ours = hub.take_pending(&session, &turn_id);
                if done > 0 {
                    let msg = json!({"promptId": root, "attempts": done, "turnId": turn_id, "reason": reason.as_str()});
                    hub.append_retry(&session, "auto_resume_exhausted", msg);
                } else if ours {
                    hub.settled_unretried(&session, &turn_id, "off");
                }
                return;
            };
            let attempt = done + 1;
            let now = super::now_ms();
            let limits = session.meta().usage_limits;
            let reset = reset_hint::reset_at(&error, limits.as_ref(), now).max(not_before);
            let next_at =
                now.saturating_add(staggered(delay, &session.id)).max(reset.unwrap_or(now));
            let delay = next_at.saturating_sub(now);
            let retry = RetrySummary {
                attempt: attempt as u64,
                of: delays.len() as u64,
                reason,
                next_at,
                prompt_id: root.clone(),
                turn_id: turn_id.clone(),
            };
            let mut msg = serde_json::to_value(&retry).unwrap_or_else(|_| json!({}));
            msg.set("delayMs", json!(delay));
            msg.set("error", json!(error));
            msg.set("control", json!(control.as_str()));
            msg.set("trustGate", json!(trust_gate));
            msg.set("notBefore", json!(not_before));
            if let Some(from) = &from {
                msg.set("from", json!(from));
            }
            // Tests only: pause a retry before its wait is set.
            #[cfg(test)]
            {
                let seam = hub.retry_seam.lock().unwrap_or_else(|e| e.into_inner()).take();
                if let Some((arrived, release)) = seam {
                    let _ = arrived.send(());
                    let _ = release.await;
                }
            }
            // None once a shutdown began, whenever it began (router review of #28503): a cut it
            // hands on is the next daemon's to continue, and Quit Everything continues nothing.
            // The wait is the record the next daemon restores (`restore.rs`).
            let set = hub.before_shutdown(|| hub.set_retry(&session, &turn_id, retry, msg));
            let Some(set) = set else {
                hub.take_pending(&session, &turn_id);
                return;
            };
            if set {
                // Its delay, or its mark going (`Wake`): Stop, close, a turn that took the chat.
                tokio::select! {
                    () = tokio::time::sleep(Duration::from_millis(delay)) => {}
                    () = wake.notified() => {}
                }
            }
            let cut = CutTurn {
                from: from.as_deref(),
                prompt_id: &root,
                turn_id: &turn_id,
                control,
                trust_gate,
                error: &error,
                not_before: None,
            };
            hub.auto_resume(&session, cut, attempt).await;
        });
    }

    /// Transfer replacement takes this lock in Stop before installing its incoming log.
    /// A late retry event must either finish before that boundary or leave the new log alone.
    fn append_retry(&self, session: &Session, kind: &str, msg: Value) {
        let _pending = session.auto_resume.lock();
        if !session.replaced.load(std::sync::atomic::Ordering::SeqCst) {
            self.append(session, "mux", kind, msg);
        }
    }

    /// Records `auto_resume_settled` `{turnId, why}` when the chat's last turn `turn_id` is one a
    /// row could have shown `retryDeciding` for and it gets no retry: watchers, and peers that
    /// keep its row, hear the decision (Codex review: a peer's row kept saying deciding).
    /// `why`: `stopped`, `off` (`autoResumeDelaysMs` is `[]`) or `not_retried`.
    fn settled_unretried(&self, session: &Session, turn_id: &str, why: &str) {
        let last = session.meta().last_turn;
        let deciding = last.as_ref().is_some_and(|t| {
            let field = |key: &str| t.get(key).and_then(Value::as_str);
            let error = field("errorText").unwrap_or_default();
            field("status") == Some("failed")
                && field("turnId") == Some(turn_id)
                && retry_decided_on(error)
        });
        if deciding {
            let mut msg = json!({"turnId": turn_id, "why": why});
            if let Some(prompt_id) =
                last.as_ref().and_then(|t| t.get("promptId").and_then(Value::as_str))
            {
                msg.set("promptId", json!(prompt_id));
            }
            self.append_retry(session, "auto_resume_settled", msg);
        }
    }

    /// Whether a continuation may still answer for the chat's cut turn: it releases what that
    /// turn held, so a held agent message's own retry waits for it (`digest.rs`).
    pub(super) fn continuation_pending(&self, session: &Session) -> bool {
        is_pending(session.auto_resume.lock().as_ref())
    }

    /// Whether the chat holds any continuation mark: a shutdown stops those chats' retries first.
    pub(super) fn has_auto_resume_mark(&self, session: &Session) -> bool {
        session.auto_resume.lock().is_some()
    }

    /// An explicit (non-restart) shutdown: a retry that waits, or one only the journal holds yet,
    /// is stopped; a chat whose turn runs or is ending is left alone, so the next daemon still
    /// continues the turn the shutdown cut (`restart_resume.rs`).
    /// The journal is read only until `by` (`shutdown_sessions`' budget): a log scan past it is cut
    /// short, and a retry only that journal held then stays for the next daemon.
    pub(super) fn stop_retry_at_shutdown(&self, session: &Session, by: std::time::Instant) {
        let cut = session.turn().is_some()
            || matches!(
                session.auto_resume.lock().as_ref(),
                Some(Mark::Ending(_) | Mark::Stopping(_))
            );
        if !cut {
            self.stop_auto_resume_by(session, Some(by));
        }
    }

    /// Stop or close: the chat's waiting continuation does not fire, and the turn running or
    /// ending now gets none, however it ends.
    pub(super) fn stop_auto_resume(&self, session: &Session) {
        self.stop_auto_resume_by(session, None);
    }

    /// [`Hub::stop_auto_resume`], reading the journal only until `by`: the scan checks it on
    /// every line, so one large log cannot hold a shutdown past its deadline.
    fn stop_auto_resume_by(&self, session: &Session, by: Option<std::time::Instant>) {
        let expired = || by.is_some_and(|by| std::time::Instant::now() >= by);
        let mut pending = session.auto_resume.lock();
        #[cfg(test)]
        if let Some(locked) =
            session.auto_resume.stop_locked.lock().unwrap_or_else(|e| e.into_inner()).take()
        {
            let _ = locked.send(());
        }
        // A lazy startup may not have installed the saved retry's mark yet. Journal the
        // cancellation boundary under the same lock as recovery: only schedules before
        // this record are stopped, never a later turn after an earlier idle Stop.
        // The first close records this boundary while the chat is still open. A closed
        // chat cannot restore a retry, and stopping it again must not refresh its age.
        let waiting_mark = matches!(
            pending.as_ref(),
            Some(Mark::Waiting { retry: Some(_), .. } | Mark::Firing(_))
        );
        let mut journal_retry = None;
        let mut journal_prompt = None;
        let boundaries = [
            b"auto_resume_scheduled".as_slice(),
            b"auto_resume_stopped",
            b"auto_resume_skipped",
            b"auto_resume_settled",
            b"auto_resume_exhausted",
            b"turn_stop_requested",
            b"turn_started",
            b"turn_result",
        ];
        let _ = self.store.scan_back(
            &session.id,
            0,
            u64::MAX,
            // Past `by`, the next line goes to `visit`, which ends the scan.
            &|_, kind| !boundaries.contains(&kind) && !expired(),
            &mut |e: EventRecord| {
                if expired() {
                    return false;
                }
                // A crash can leave the failed result durable before its schedule. Stop
                // must suppress that unscheduled recovery too, even before startup loads it.
                let retryable_result = e.kind == "turn_result"
                    && e.msg.get("status").and_then(Value::as_str) == Some("failed")
                    && e.msg.get("errorText").and_then(Value::as_str).is_some_and(|error| {
                        super::turn_errors::resume_cause(error, error).is_some()
                    });
                if e.kind == "auto_resume_scheduled" || retryable_result {
                    journal_retry = e.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                    journal_prompt =
                        e.msg.get("promptId").and_then(Value::as_str).map(str::to_owned);
                }
                false
            },
        );
        let active = session.turn();
        let active_turn = active.as_ref().map(|turn| turn.turn_id.clone());
        let stopping_turn = active_turn.clone().or_else(|| match pending.as_ref() {
            Some(Mark::Ending(t) | Mark::Stopped(t)) => Some(t.clone()),
            Some(Mark::Waiting { turn, retry: None, .. }) => Some(turn.clone()),
            _ => None,
        });
        if session.status() != SessionStatus::Closed
            && !session.replaced.load(std::sync::atomic::Ordering::SeqCst)
        {
            if let Some(turn_id) = stopping_turn {
                // Ordinary Stop has no retry state or retry watcher update. Its durable
                // turn-scoped boundary still forbids recovery if the turn later fails,
                // or if restart interrupts it before a result was written.
                self.append(
                    session,
                    "mux",
                    "turn_stop_requested",
                    json!({"turnId": turn_id, "promptId": active.as_ref().map(|turn| &turn.prompt_id)}),
                );
            } else if waiting_mark || journal_retry.is_some() {
                let turn_id = match pending.as_ref() {
                    Some(Mark::Waiting { turn, .. } | Mark::Firing(turn)) => Some(turn.clone()),
                    _ => journal_retry,
                };
                let prompt_id = match pending.as_ref() {
                    Some(Mark::Waiting { retry: Some(retry), .. }) => Some(retry.prompt_id.clone()),
                    _ => journal_prompt,
                };
                self.append(
                    session,
                    "mux",
                    "auto_resume_stopped",
                    json!({"turnId": turn_id, "promptId": prompt_id}),
                );
            }
        }
        let settles = settled_by_stop(pending.as_ref());
        let (ending, fired) = match pending.as_ref() {
            Some(Mark::Ending(t)) => (Some(t.clone()), false),
            Some(Mark::Firing(t) | Mark::Stopping(t)) => (Some(t.clone()), true),
            _ => (None, false),
        };
        match (session.turn().map(|t| t.turn_id), ending) {
            (Some(t), _) => pending.replace(Mark::Stopped(t)),
            (None, Some(t)) if fired => pending.replace(Mark::Stopping(t)),
            (None, Some(t)) => pending.replace(Mark::Stopped(t)),
            (None, None) => pending.take(),
        };
        drop(pending);
        // A row may have shown this turn's retry being decided: watchers and peers hear it
        // settle, though an idle Stop records nothing else (Codex review, round 3).
        if let Some(turn) = settles {
            self.settled_unretried(session, &turn, "stopped");
        }
    }

    /// Tests: the chat's turn `turn` ends with its continuation not settled yet (`Mark::Ending`),
    /// or with `None` nothing pending.
    /// Tests: whether a Stop holds for the chat's turn `turn` (`Mark::Stopped`).
    #[cfg(test)]
    pub(super) fn stopped_for_test(&self, session: &Session, turn: &str) -> bool {
        matches!(session.auto_resume.lock().as_ref(), Some(Mark::Stopped(t)) if t == turn)
    }

    #[cfg(test)]
    pub(super) fn set_ending_for_test(&self, session: &Session, turn: Option<&str>) {
        let mut pending = session.auto_resume.lock();
        match turn {
            Some(turn) => pending.replace(Mark::Ending(turn.to_owned())),
            None => pending.take(),
        };
    }

    /// Starts the chat's turn (`run_prompt`). A continuation (`after` its cut turn) that Stop
    /// or close overtook since it fired is refused instead, in one step with Stop's check. A
    /// prompt that never waits (`exclusive`, `PromptOptions::no_queue`) is refused `retry.busy`
    /// while a continuation may still answer for the chat's cut turn (under the lock its fire
    /// takes) or Claude Code runs a turn of its own: the last check before its turn is set.
    pub(super) fn start_turn(
        &self,
        session: &Session,
        after: Option<&str>,
        exclusive: bool,
        subagent_retry: bool,
        turn: super::TurnInfo,
    ) -> Result<(), RpcError> {
        let mut pending = session.auto_resume.lock();
        // Transfer replacement seals the old instance before staging its store. Reject before
        // installing a TurnInfo so a fired retry cannot start against the incoming journal.
        if session.replaced.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(superseded());
        }
        let continuation = is_pending(pending.as_ref());
        if exclusive
            && (continuation || session.harness_turn.load(std::sync::atomic::Ordering::SeqCst))
        {
            return Err(retry_turn::busy());
        }
        if let Some(cut) = after {
            let mark = match pending.as_ref() {
                Some(Mark::Firing(t)) if t == cut => Some(true),
                Some(Mark::Stopped(t)) if t == cut => Some(false),
                // Its task clears it once it ends.
                Some(Mark::Stopping(t)) if t == cut => return Err(stopped()),
                _ => None,
            };
            if mark.is_some() {
                pending.take();
            }
            if mark == Some(false) {
                return Err(stopped());
            }
        }
        // A subagent retry skipped since its prompt went out, or that no attempt of this daemon
        // sent (one a restart or a move restored), does not start (`subagent_retry.rs`).
        let prompt_id = turn.prompt_id.clone();
        self.subagent_retries.start(&session.id, &prompt_id, subagent_retry, || {
            *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = Some(turn);
        })
    }

    /// Sets the wait of the chat's continuation of `cut_turn`, when it still waits: what the
    /// session row's `retry` shows.
    fn set_retry(&self, session: &Session, cut_turn: &str, wait: RetrySummary, msg: Value) -> bool {
        match session.auto_resume.lock().as_mut() {
            Some(Mark::Waiting { turn, retry, .. })
                if turn == cut_turn
                    && !session.replaced.load(std::sync::atomic::Ordering::SeqCst) =>
            {
                *retry = Some(wait);
                // Before Stop can clear the mark and record its terminal decision: recovery
                // must never find the schedule after the cancellation it superseded.
                self.append(session, "mux", "auto_resume_scheduled", msg);
                true
            }
            _ => false,
        }
    }

    /// The session row's `retry` and `retryDeciding`, from one read of the chat's mark, so a row
    /// never shows its failed turn settled while its retry is being set. `retry`: the wait of a
    /// continuation that may still answer for the chat's cut turn, null when none waits or the
    /// chat moved on. `retryDeciding`: `last` (the row's `lastTurn`) failed on an error a retry
    /// answers ([`super::turn_errors::resume_cause`]) and whether, and when, it is retried is not
    /// settled yet: its end is being settled, its retry's time is not set yet, or its retry is
    /// starting or runs. `_acpmux/wait` holds its answer for such a row (`server/wait.rs`).
    pub(crate) fn retry_row(
        &self,
        session: &Session,
        last: Option<&Value>,
    ) -> (Option<RetrySummary>, bool) {
        let failed = last
            .filter(|t| t.get("status").and_then(Value::as_str) == Some("failed"))
            .filter(|t| {
                retry_decided_on(t.get("errorText").and_then(Value::as_str).unwrap_or_default())
            });
        let cut = failed.and_then(|t| t.get("turnId").and_then(Value::as_str));
        let snapshot = || {
            let pending = session.auto_resume.lock();
            let mark = pending.as_ref();
            let waiting = match mark {
                Some(Mark::Waiting { turn, retry: Some(retry), .. }) => {
                    Some((turn.clone(), retry.clone()))
                }
                _ => None,
            };
            let deciding = cut.is_some_and(|cut| match mark {
                Some(Mark::Ending(t) | Mark::Firing(t)) => t == cut,
                Some(Mark::Waiting { turn, retry: None, .. }) => turn == cut,
                Some(_) => false,
                // Its retry's turn started since the row read `turn` (`start_turn` sets it
                // under this lock, as the mark goes).
                None => session.turn().is_some_and(|t| {
                    let root = failed.and_then(|f| f["promptId"].as_str()).map(split_attempt);
                    let (of, attempt) = split_attempt(&t.prompt_id);
                    attempt > 0 && root.is_some_and(|(root, _)| root == of)
                }),
            });
            (waiting, deciding)
        };
        settled_retry_row(snapshot, |cut_turn| still_cut(session, cut_turn))
    }

    /// Fires the chat's waiting continuation when it still answers for `cut_turn`: its mark
    /// stays, as firing, until its turn starts. Else why it does not: `superseded` when a newer
    /// turn took its mark or the chat moved on, `stopped` when Stop or close took it.
    fn fire_pending(&self, session: &Session, cut_turn: &str) -> Result<(), &'static str> {
        let mut pending = session.auto_resume.lock();
        match pending.as_ref() {
            Some(Mark::Waiting { turn, .. }) if turn == cut_turn => {
                pending.replace(Mark::Firing(cut_turn.to_owned()));
                Ok(())
            }
            Some(Mark::Waiting { .. } | Mark::Firing(_) | Mark::Ending(_)) => Err("superseded"),
            // The turn that ended before `still_cut` reads its result is a newer one.
            _ if !still_cut(session, cut_turn) => Err("superseded"),
            _ => Err("stopped"),
        }
    }

    /// Drops what is left of a continuation of `cut_turn` that did not start its turn.
    fn clear_fired(&self, session: &Session, cut_turn: &str) {
        let mut pending = session.auto_resume.lock();
        if matches!(pending.as_ref(), Some(Mark::Firing(t) | Mark::Stopped(t) | Mark::Stopping(t)) if t == cut_turn)
        {
            pending.take();
        }
    }

    /// Takes the chat's waiting continuation when it still answers for `cut_turn`.
    fn take_pending(&self, session: &Session, cut_turn: &str) -> bool {
        let mut pending = session.auto_resume.lock();
        let ours = matches!(pending.as_ref(), Some(Mark::Waiting { turn, .. }) if turn == cut_turn);
        if ours {
            pending.take();
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
        // Transfer replacement can leave this old task alive after the returning journal
        // takes its id. It must neither fire nor record a skip in that new journal.
        // Once a shutdown began (a restart too) it never fires either: starts are fenced, so
        // it would end as a shutdown failure that supersedes the saved schedule. Its wait
        // stays durable, and the next daemon restores it (`restore.rs`).
        if session.replaced.load(std::sync::atomic::Ordering::SeqCst) || self.shutting_down() {
            return;
        }
        let (root, cut_turn) = (cut.prompt_id, cut.turn_id);
        let skipped = |why: &str| json!({"promptId": root, "attempt": attempt, "turnId": cut_turn, "skipped": why});
        if let Err(why) = self.fire_pending(session, cut_turn) {
            // Stop or close took it, or a newer turn replaced it.
            self.append_retry(session, "auto_resume_skipped", skipped(why));
            return;
        }
        if session.status() == SessionStatus::Closed || session.moving().is_some() {
            self.clear_fired(session, cut_turn);
            self.append_retry(session, "auto_resume_skipped", skipped("closed"));
            return;
        }
        if !still_cut(session, cut_turn) {
            self.clear_fired(session, cut_turn);
            self.append_retry(session, "auto_resume_skipped", skipped("superseded"));
            return;
        }
        let held = self.held_by(session, root, cut_turn);
        let mut provenance = json!({"kind": "auto_resume", "promptId": root, "attempt": attempt, "turnId": cut_turn});
        if let Some(from) = cut.from {
            provenance.set("from", json!(from));
        }
        // Whether the attempt reached the chat (its turn started): one refused before that
        // (its folder gone, a dispatch check) leaves no record a watcher hears but this skip.
        let accepted = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let on_accepted = {
            let accepted = accepted.clone();
            Box::new(move |_: Value| accepted.store(true, std::sync::atomic::Ordering::SeqCst))
        };
        let opts = PromptOptions {
            on_accepted: Some(on_accepted),
            prompt_id: Some(format!("{root}{SUFFIX}{attempt}")),
            resend: true,
            control: cut.control,
            trust_gate: cut.trust_gate,
            provenance: Some(provenance),
            after_turn: Some(cut_turn.to_owned()),
            ..PromptOptions::default()
        };
        let reason = super::turn_errors::resume_cause(cut.error, cut.error).unwrap_or("transport");
        let blocks = vec![json!({"type": "text", "text": continue_text(cut.error, reason)})];
        let result = self.prompt_with(session, blocks, "acpmux", false, opts).await;
        self.finish_auto_resume(
            session,
            &cut,
            attempt,
            &held,
            result,
            accepted.load(std::sync::atomic::Ordering::SeqCst),
        );
    }

    /// A prompt can finish after its session was replaced. Serialize its terminal records
    /// and held-queue release with replacement's Stop, just like a waiting timer's records.
    fn finish_auto_resume(
        &self,
        session: &Arc<Session>,
        cut: &CutTurn<'_>,
        attempt: usize,
        held: &[String],
        result: Result<Value, RpcError>,
        accepted: bool,
    ) {
        let (root, cut_turn) = (cut.prompt_id, cut.turn_id);
        self.clear_fired(session, cut_turn);
        // Read before the retry lock: scheduling takes the shutdown plan, then this lock
        // (`before_shutdown`, `set_retry`), so never the other way round.
        let fenced = self.shutting_down()
            && !self.restart_requested.load(std::sync::atomic::Ordering::SeqCst);
        let _pending = session.auto_resume.lock();
        if session.replaced.load(std::sync::atomic::Ordering::SeqCst) || fenced {
            return;
        }
        #[cfg(test)]
        after_finish_replaced_check();
        let skipped = |why: &str| json!({"promptId": root, "attempt": attempt, "turnId": cut_turn, "skipped": why});
        match result {
            Ok(v) if v.get("stopReason").and_then(Value::as_str) != Some("cancelled") => {
                self.resume_held(session, held);
            }
            Ok(_) => {}
            Err(e) => match e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str) {
                Some(why @ ("auto_resume.superseded" | "auto_resume.stopped")) => {
                    let why = why.trim_start_matches("auto_resume.");
                    self.append(session, "mux", "auto_resume_skipped", skipped(why));
                }
                // Refused before its turn: the row's retry went when it fired.
                _ if !accepted => {
                    tracing::warn!(session = %session.id, attempt, "auto resume refused: {}", e.message);
                    let mut msg = skipped("refused");
                    msg.set("error", json!(e.message));
                    self.append(session, "mux", "auto_resume_skipped", msg);
                }
                // A failure that is itself a transient error scheduled the next attempt.
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

    fn retry(turn: &str) -> RetrySummary {
        RetrySummary {
            attempt: 1,
            of: 4,
            reason: RetryReason::Capacity,
            next_at: 9,
            prompt_id: "p".into(),
            turn_id: turn.into(),
        }
    }

    /// Stop settles a turn whose retry is being decided or waits, with or without its time:
    /// with retries off, nothing else records that decision (Codex review, round 3).
    #[test]
    fn stop_settles_an_ending_or_waiting_turn() {
        let wake = || Wake(Arc::new(Notify::new()));
        let unset = Mark::Waiting { turn: "t1".into(), retry: None, _wake: wake() };
        assert_eq!(settled_by_stop(Some(&unset)).as_deref(), Some("t1"));
        let set = Mark::Waiting { turn: "t1".into(), retry: Some(retry("t1")), _wake: wake() };
        assert_eq!(settled_by_stop(Some(&set)).as_deref(), Some("t1"));
        assert_eq!(settled_by_stop(Some(&Mark::Ending("t1".into()))).as_deref(), Some("t1"));
        for mark in
            [Mark::Firing("t1".into()), Mark::Stopped("t1".into()), Mark::Stopping("t1".into())]
        {
            assert_eq!(settled_by_stop(Some(&mark)), None);
        }
        assert_eq!(settled_by_stop(None), None);
    }

    /// A row reads its chat's mark again when the retry it read is gone by the time it checks
    /// it (the retry fired and its turn started meanwhile), so it shows that retry's decision,
    /// never neither (Codex review, round 2).
    #[test]
    fn a_row_reads_the_mark_again_when_its_retry_moved_on() {
        let mut reads = vec![(None, true), (Some(("t1".to_owned(), retry("t1"))), false)];
        let row = settled_retry_row(|| reads.pop().unwrap(), |_| false);
        assert_eq!(row, (None, true), "the retry started: it is being decided");
        let row =
            settled_retry_row(|| (Some(("t1".to_owned(), retry("t1"))), false), |t| t == "t1");
        assert_eq!(row, (Some(retry("t1")), false));
        // Superseded every time (a person's prompt took the chat): no retry, nothing deciding.
        let mut count = 0;
        let row = settled_retry_row(
            || {
                count += 1;
                (Some(("t1".to_owned(), retry("t1"))), false)
            },
            |_| false,
        );
        assert_eq!((row, count), ((None, false), ROW_READS));
        assert_eq!(settled_retry_row(|| (None, true), |_| unreachable!()), (None, true));
    }

    #[test]
    fn the_configured_waits_say_how_many_attempts_run() {
        assert_eq!(configured_attempts(None), DEFAULT_DELAYS_MS.len());
        assert_eq!(configured_attempts(Some(&vec![])), 0);
        assert_eq!(configured_attempts(Some(&vec![1_000])), 1);
        assert_eq!(configured_attempts(Some(&vec![1_000; 9])), 9);
        // The ceiling bounds what a configured loop may set, never the default.
        assert!(DEFAULT_DELAYS_MS.len() <= MAX_CONFIGURED_ATTEMPTS);
        assert_eq!(
            checked_delays(&json!(vec![1000; MAX_CONFIGURED_ATTEMPTS + 1])).unwrap().len(),
            MAX_CONFIGURED_ATTEMPTS
        );
    }

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
        // A loop longer than the default's four is kept: the key configures the whole loop.
        assert_eq!(checked_delays(&json!(vec![1000; 5])).unwrap().len(), 5);
        assert_eq!(checked_delays(&json!(vec![1000; 12])).unwrap().len(), 12);
        assert_eq!(checked_delays(&json!([1000, -5])), None);
        assert_eq!(checked_delays(&json!([1.5])), None);
        assert_eq!(checked_delays(&json!("10s")), None);
        assert_eq!(staggered(u64::MAX, "s"), u64::MAX);
    }
}

#[cfg(test)]
#[path = "auto_resume/turn_completion_tests.rs"]
mod turn_completion_tests;
