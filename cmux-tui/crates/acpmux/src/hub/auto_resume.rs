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
//! - Without `autoResumeDelaysMs`, the person's Settings set the loop (`agents.autoRetry.*`:
//!   on or off, the seconds before each attempt, how many attempts; [`settings`]), read at each
//!   retry; their defaults are the default waits.
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
//!   is the provider's whatever account asks, so the session waits where it is. After
//!   `capacityFallbackAfter` capacity failures of one prompt (default 0: never), its attempts run on a
//!   smaller model of the same harness until a turn there ends well ([`capacity_failover`]).
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
//! - A turn that failed because the chat outgrew its model's context window (`context`) is
//!   compacted first, at once and once, where its harness can compact ([`compact_first`]).
//! - An agent started on an earlier daemon's vault egress proxy (its `HTTPS_PROXY` port closed,
//!   its CA gone: `vault/egress.rs`) is restarted before the attempt, between turns, so the
//!   attempt runs in a process that can reach the model (2026-11-21: 20 chats on one machine
//!   spent every attempt on `ECONNREFUSED` in the same stale process; 2026-11-22: ~30 Freestyle
//!   chats failed on `UNABLE_TO_VERIFY_LEAF_SIGNATURE`, the new proxy's CA, and were not
//!   continued until TLS-verification errors counted as `transport`).

use cmux_json::JsonSet as _;

// A turn a daemon restart cut off is continued from the restored queue.
pub(super) mod reset_hint;
#[path = "restart_resume.rs"]
mod restart_resume;
pub(in crate::hub) use restart_resume::{Cut, silent};
mod restore;

use super::{Control, Hub, PromptOptions, Session, SessionStatus, TurnInfo};
use crate::rpc::RpcError;
use crate::store::EventRecord;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
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

/// A chat past its context window: `/compact`, then the continuation.
mod compact_first;
// A chat a full disk cut waits for free space (`disk_wait.rs`).
mod disk_wait;

/// A dead agent's unread steers go into its continuation.
mod unread_steers;

/// A turn the agent failed on its model goes again once, under the model's catalog id.
mod model_reroute;

/// A sustained overload goes on on a smaller model, and back once a turn there ends well.
mod capacity_failover;

/// A host's background capacity waiters go back one probe at a time during an outage, then in
/// a doubling stream once the model answers (`capacity_gate.rs`).
mod capacity_gate;
pub(crate) use capacity_gate::CapacityGate;

/// The loop as Settings > Agents > Retry After Errors sets it (`agents.autoRetry.*`).
mod settings;
pub(in crate::hub) use settings::effective_delays;

/// Whether a failed turn's `error` is one acpmux may retry by itself: a transient one
/// ([`super::turn_errors::resume_cause`]), or a revoked token, which a chat's first send retries
/// ([`first_send`]). A row shows such a turn's retry being decided until that is settled.
fn retry_decided_on(error: &str) -> bool {
    super::turn_errors::resume_cause(error, error).is_some()
        || first_send::retried_error(error)
        || crate::model_catalog::is_model_error(error)
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
    delays.map_or_else(|| effective_delays(None).len(), Vec::len)
}

/// The longest a capacity continuation waits between attempts, unless the error's own
/// `retry-after` says longer (Leo, 2026-11-23: "I can't even talk to the GUI chats right now
/// because of alleged overload"). A capacity outage (HTTP 529, the SR2 gateway's 503 "no
/// non-exhausted accounts" or 502 "at its call limit") ends when capacity comes back, so its
/// continuation never runs out of attempts: past the configured waits it waits this long.
pub const CAPACITY_MAX_WAIT_MS: u64 = 300_000;

/// Whether a continuation for `reason` never runs out of attempts: a capacity outage (the
/// provider's 529, the SR2 gateway's 503 "no non-exhausted accounts ... next account frees up in
/// Nm") and an account's rate limit (HTTP 429) both end by themselves, so the chat waits them out
/// (Leo, 2026-11-24: "didn't we build auto retries for this? why do they fail instead of waiting
/// it out?"). On 2026-11-23 18 lanes on one machine sat failed for 18 h: the 503s ran out of
/// their four attempts (before #53115), and the 429s ran out at their fifth strike, one short of
/// parking. A rate limit's waits are its chat's backoff (`rate_hold.rs`), whose park now
/// lifts itself; a capacity wait is [`capacity_wait`]. A refused connection (`error` says
/// `ECONNREFUSED`: the inference gateway is down, [`super::turn_errors::is_refused_connection`])
/// is a transport error waited out the same way, with capacity's capped waits: its outage ends
/// when the gateway listens again, which four attempts over 26 minutes may not see. Every other
/// transport error keeps its configured attempts. Off (`[]`) stays off.
pub(in crate::hub) fn waits_it_out(reason: RetryReason, error: &str, delays: &[u64]) -> bool {
    let outage = match reason {
        RetryReason::Capacity | RetryReason::RateLimit | RetryReason::Disk => true,
        RetryReason::Transport => super::turn_errors::is_refused_connection(error),
        RetryReason::AgentExited | RetryReason::Context => false,
    };
    outage && !delays.is_empty()
}

/// The wait before capacity attempt `index` (from 0): the configured wait, at most
/// [`CAPACITY_MAX_WAIT_MS`] (a longer configured wait would hold a chat past capacity's return);
/// past the configured waits the last one doubling per attempt, at most the same. Jittered per
/// chat and attempt so chats an outage cut together spread out.
pub(super) fn capacity_wait(index: usize, delays: &[u64], session_id: &str) -> u64 {
    let last = delays.last().copied().unwrap_or(MIN_DELAY_MS).max(1);
    let wait = delays.get(index).copied().unwrap_or_else(|| {
        let past = u32::try_from(index + 1 - delays.len()).unwrap_or(u32::MAX).min(20);
        last.saturating_mul(1u64 << past)
    });
    let wait = wait.min(CAPACITY_MAX_WAIT_MS);
    staggered(wait, &format!("{session_id}#{index}"))
}

/// The deadline a capacity error's own `retry after Ss` names, jittered per chat and attempt:
/// up to a fifth later, never earlier. Every chat the SR2 pool turned away at once is told the
/// same `retry after`, so without the jitter they all came back at the moment the next account
/// freed and emptied it again (2026-11-24: one lane's continuations were scheduled at exactly
/// `delayMs: 203000` for `retry after 203s`). Any other reason's deadline is kept as it is.
pub(super) fn jittered_reset(
    reason: RetryReason,
    reset: Option<u64>,
    now: u64,
    key: &str,
) -> Option<u64> {
    match (reason, reset) {
        (RetryReason::Capacity, Some(at)) if at > now => {
            Some(now.saturating_add(staggered(at - now, key)))
        }
        _ => reset,
    }
}

/// The `lastTurn` a session row shows. A turn a capacity error cut, whose continuation acpmux
/// waits for or is deciding or running, reads `status: "capacity"` (with `heldUntil`, the
/// continuation's time, while it waits), not `failed`: acpmux holds it and goes on by itself
/// once the pool frees, so a census of failed turns (HQ NOW's `failed_turns`) does not count it
/// (Leo, 2026-11-24: "21 turns just died on '503 no non-exhausted claude accounts available'.
/// why are we out of accounts, and why isn't anything falling back?"). The log keeps the
/// turn's `failed` result; with no continuation coming (auto-resume off, Stop) the row says
/// `failed` as before.
pub(in crate::hub) fn row_last_turn(
    last: Option<&Value>,
    retry: Option<&RetrySummary>,
    deciding: bool,
) -> Option<Value> {
    let last = last?;
    let error = last.get("errorText").and_then(Value::as_str).unwrap_or_default();
    // An account's spent limit is a capacity cause too (`capacity_wait.rs`): never red while held.
    let capacity = last.get("status").and_then(Value::as_str) == Some("failed")
        && super::turn_errors::resume_cause(error, error)
            .and_then(RetryReason::from_cause)
            .is_some_and(super::capacity_wait::is_capacity);
    let waits = retry.filter(|r| super::capacity_wait::is_capacity(r.reason));
    if !capacity || (waits.is_none() && !deciding) {
        return Some(last.clone());
    }
    let mut held = last.clone();
    held.set("status", json!("capacity"));
    if let Some(retry) = waits {
        held.set("heldUntil", json!(retry.next_at));
    }
    Some(held)
}

/// The slash command a cut prompt was, when its continuation must send it again rather than
/// ask the agent to go on: `/compact` (with or without instructions). Asking a chat whose
/// compaction failed to "continue" sends its whole context again and the compaction is lost.
pub(in crate::hub) fn resent_command(text: &str) -> Option<&str> {
    let t = text.trim();
    (t == "/compact" || t.starts_with("/compact ")).then_some(t)
}

/// Shortest and longest configured wait, in milliseconds.
const MIN_DELAY_MS: u64 = 1_000;
const MAX_DELAY_MS: u64 = 3_600_000;

/// The prompt-id suffix of an automatic continuation, before its attempt number.
const SUFFIX: &str = "~resume-";

/// Longest error text quoted to the agent, in characters.
const MAX_ERROR_CHARS: usize = 300;

/// The prompt a continuation (or an attempt's compaction, `compact_first::SUFFIX`) answers
/// for, and the attempt it is (0 for a prompt of its own).
fn split_attempt(prompt_id: &str) -> (&str, usize) {
    for suffix in [SUFFIX, compact_first::SUFFIX] {
        if let Some((root, n)) = prompt_id.rsplit_once(suffix)
            && let Ok(n) = n.parse::<usize>()
            && !root.is_empty()
        {
            return (root, n);
        }
    }
    (prompt_id, 0)
}

/// The text the agent gets for `session`'s cut turn; `reason` is the failure's
/// [`super::turn_errors::resume_cause`]. It says when it was cut (its `lastTurn.endedAt`)
/// and that the chat was paused until now: "You were paused because X at T; continue".
pub(super) fn continue_text_for(session: &Session, error: &str, reason: &str) -> String {
    let cut_at = session.meta().last_turn.as_ref().and_then(|t| t.get("endedAt")?.as_u64());
    continue_text_at(error, reason, cut_at, super::now_ms())
}

/// [`continue_text_for`]'s words, with the cut's time and the resume's when `cut_at` (epoch ms)
/// is known.
fn continue_text_at(error: &str, reason: &str, cut_at: Option<u64>, now: u64) -> String {
    let error: String = error.chars().take(MAX_ERROR_CHARS).collect();
    let cause = match reason {
        "agent_exited" => "an agent process exit",
        "capacity" => "a capacity error upstream (the provider or the gateway was full)",
        "rate_limit" => {
            "the account's rate limit (HTTP 429); the chat held every turn until its reset"
        }
        "transport" => "a connection error",
        "context" => "the chat's context filling up; it was compacted",
        "disk" => "the machine's disk filling up; acpmux waited until space was free again",
        _ => "an error",
    };
    let when = cut_at.map_or_else(String::new, |at| {
        let line = super::pause_state::resumes_line;
        format!(" at {}; acpmux paused the chat until now ({})", line(Some(at)), line(Some(now)))
    });
    format!(
        "Your previous turn was cut off by {cause} ({error}){when}. Check what already \
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
    /// The cut prompt's own slash command ([`resent_command`]): its continuation sends it again
    /// instead of the continuation's words, so a `/compact` an overload cut is compacted, not
    /// dropped.
    pub slash: Option<&'a str>,
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
    /// close now still counts for it. Its generation is its task's token ([`Pending::generation`]).
    Firing(String, u64),
    /// This turn has ended and whether it is continued is not settled yet; Stop or close now
    /// still counts for it.
    Ending(String),
    /// Stop or close came while this turn ran or was ending: it gets no continuation.
    Stopped(String),
    /// Stop or close came after a continuation or retry of this cut turn fired and before its
    /// turn started: its turn never starts, and its task clears this (`clear_fired`), so the
    /// chat's retry (`retry_turn.rs`) waits for that task to end, at most until `bound`: a task
    /// that never ends then no longer holds the chat ([`Pending::lock`] lets the mark go). The
    /// Stop moved [`Pending::generation`] past `fired_gen`, so that task's turn still never starts.
    Stopping { turn: String, fired_gen: u64, bound: cmux_deadline::Deadline },
}

/// The longest a Stopping mark waits for its fired task to end (#54378). That task is bounded
/// by its prompt's own start bounds; one that died without clearing its mark would otherwise
/// refuse the chat's Retry (`retry.busy`) until the daemon restarts.
const STOPPING_BOUND: std::time::Duration = std::time::Duration::from_secs(120);

impl Mark {
    /// A Stop overtook the continuation of `turn` that fired as generation `fired_gen`.
    fn stopping(turn: String, fired_gen: u64) -> Self {
        Mark::Stopping { turn, fired_gen, bound: cmux_deadline::Deadline::after(stopping_bound()) }
    }
}

#[cfg(not(test))]
fn stopping_bound() -> std::time::Duration {
    STOPPING_BOUND
}

#[cfg(test)]
thread_local! {
    static STOPPING_BOUND_FOR_TEST: std::cell::Cell<Option<std::time::Duration>> =
        const { std::cell::Cell::new(None) };
}

#[cfg(test)]
fn stopping_bound() -> std::time::Duration {
    STOPPING_BOUND_FOR_TEST.with(std::cell::Cell::get).unwrap_or(STOPPING_BOUND)
}

/// The retry state of one session instance; returning imports have their own mark.
pub(crate) struct Pending {
    mark: Mutex<Option<Mark>>,
    /// Moves on, under `mark`, at each fire and at each Stop of a fired continuation. A fired
    /// task carries the value its fire set (`PromptOptions::fired`), and its turn starts only
    /// while that is still the current one (`start_turn`): a Stop, or a later fire, fences it
    /// even once its mark is gone.
    generation: std::sync::atomic::AtomicU64,
    /// Loaded once from the journal; checked under `mark` before a prompt gets a turn.
    stopped_prompts: Mutex<Option<HashSet<String>>>,
    /// The compaction an attempt runs before its continuation ([`compact_first`]). Taken
    /// after `mark` when both are, never before it.
    compacting: Mutex<Option<compact_first::Compaction>>,
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
            generation: std::sync::atomic::AtomicU64::new(0),
            stopped_prompts: Mutex::default(),
            compacting: Mutex::default(),
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
    matches!(mark, Some(Mark::Waiting { .. } | Mark::Firing(..) | Mark::Ending(_)))
}

impl Pending {
    fn lock(&self) -> PendingGuard<'_> {
        let mut mark = self.mark.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // A Stopping mark past its bound: its task never cleared it (#54378). The Stop already
        // fenced that task's turn (`generation`), so the chat is free again.
        if let Some(Mark::Stopping { turn, fired_gen, bound }) = mark.as_ref()
            && bound.expired()
        {
            tracing::warn!(
                "a stopped continuation of turn {turn} (generation {fired_gen}) did not end within \
                 {:?}; its mark is let go",
                stopping_bound()
            );
            mark.take();
        }
        let was = is_pending(mark.as_ref());
        PendingGuard { mark, was, released: &self.released }
    }

    /// A fire: the generation its task carries (`Mark::Firing`, `PromptOptions::fired`).
    fn next_generation(&self) -> u64 {
        self.generation.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1
    }

    /// A Stop of a fired continuation: the generation its task carries is no longer current.
    fn fence_fired(&self) {
        self.generation.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }

    /// Whether a fired task's generation `fired_gen` is still the current one.
    fn current(&self, fired_gen: u64) -> bool {
        self.generation.load(std::sync::atomic::Ordering::SeqCst) == fired_gen
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
    still_cut_by(session, cut_turn, false)
}

/// [`still_cut`], where with `rate_held` what waits in the queue does not count: the account's
/// rate limit held it there, and the continuation folds into it at the reset (`rate_hold.rs`).
pub(super) fn still_cut_by(session: &Session, cut_turn: &str, rate_held: bool) -> bool {
    session.turn().is_none()
        && (rate_held || session.queue().iter().all(|q| q.aside()))
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
    provenance: Option<&Value>,
) -> Result<(), RpcError> {
    // A rate limit's compaction runs ahead of what the hold queued, as `compact_first` decided;
    // a cold batch's compaction ahead of the batch (`cold_wake.rs`).
    let rate_held = rate_compaction_runs(session)
        || (after.is_some() && super::cold_wake::goes_ahead_of_batch(session, provenance));
    match after {
        Some(cut) if waiting || !still_cut_by(session, cut, rate_held) => Err(superseded()),
        _ => Ok(()),
    }
}

pub(super) fn check_capacity_cut(session: &Session, cut: &str) -> Result<(), RpcError> {
    let pending = session.auto_resume.lock();
    let was_stopped = matches!(
        pending.as_ref(),
        Some(Mark::Stopping { turn, .. } | Mark::Stopped(turn)) if turn == cut
    );
    if was_stopped {
        return Err(stopped());
    }
    check_cut(session, Some(cut), false, None)
}

/// Whether `session`'s account rate limit holds it while its compaction runs (`rate_hold.rs`):
/// that one prompt goes ahead of what the hold queued, which goes in after it with the
/// continuation.
pub(super) fn rate_compaction_runs(session: &Session) -> bool {
    Hub::rate_held(session)
        && session.auto_resume.compacting.lock().unwrap_or_else(|e| e.into_inner()).is_some()
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
            accepted: true,
            device: None,
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
        let compaction = Self::take_compaction(session, turn_id);
        let mut pending = session.auto_resume.lock();
        let ending = match pending.as_ref() {
            Some(Mark::Ending(t)) if t == turn_id => Some(true),
            Some(Mark::Stopped(t)) if t == turn_id => Some(false),
            _ => None,
        };
        // An attempt's compaction ended: its continuation follows, or the attempt settles.
        if let Some(step) = compaction {
            self.compaction_ended(session, pending, turn_id, ending, cut.is_some(), step);
            return;
        }
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
        // A turn the agent failed on its model: sent again once under the model's catalog id,
        // its wait this mark's; with no such id the mark goes as an unretried failure.
        if let (Some(cut), None, Some(true)) = (cut.as_ref(), reason, ending)
            && model_reroute::may_reroute(cut)
        {
            let wake = Arc::new(Notify::new());
            let mark =
                Mark::Waiting { turn: turn_id.to_owned(), retry: None, _wake: Wake(wake.clone()) };
            pending.replace(mark);
            drop(pending);
            self.reroute_model_turn(session, cut, wake);
            return;
        }
        // The account's limit holds the whole chat from now on, a continuation or none: what comes
        // in meanwhile queues for the reset (`rate_hold.rs`).
        // Its strikes grow its backoff; enough of them park it (no timer, one line to the
        // session it reports to); its continuation then waits for a retry.
        if let (Some(cut), Some(RetryReason::RateLimit), Some(true)) =
            (cut.as_ref(), reason, ending)
        {
            let _parked = self.hold_at_failure(session, turn_id, cut.error, cut.not_before);
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
        // A background chat cut on capacity tells the host's gate the pool is out.
        self.capacity_gate_cut(session, Some(reason));
        let (root, done) = split_attempt(cut.prompt_id);
        let (root, turn_id, error) =
            (root.to_owned(), cut.turn_id.to_owned(), cut.error.to_owned());
        let (control, trust_gate, not_before) = (cut.control, cut.trust_gate, cut.not_before);
        let from = cut.from.map(str::to_owned);
        let slash = cut.slash.map(str::to_owned);
        let (hub, session) = (self.clone(), session.clone());
        // Off the turn's path: the turn lock is still held here.
        tokio::spawn(async move {
            let configured = hub.config.read().await.auto_resume_delays_ms.clone();
            let delays = effective_delays(configured);
            // A chat past its context window goes on only once compacted, and at once.
            let context = reason == RetryReason::Context;
            if context && !hub.can_compact(&session).await {
                if hub.take_pending(&session, &turn_id) {
                    hub.settled_unretried(&session, &turn_id, "not_retried");
                    hub.lane_stranded(&session);
                }
                return;
            }
            let delays = if context { compact_first::waits(&delays) } else { delays };
            // A move's continuation is no failed attempt and uses up no wait (`restart_resume.rs`).
            let moves = if done == 0 { 0 } else { hub.moves_behind(&session, &root) };
            // A capacity outage, an account's rate limit or a refused connection is waited
            // out, however long it lasts: never used up ([`waits_it_out`]).
            let index = done.saturating_sub(moves);
            let unbounded = waits_it_out(reason, &error, &delays);
            let delay = if unbounded {
                Some(capacity_wait(index, &delays, &session.id))
            } else {
                delays.get(index).map(|&d| staggered(d, &session.id))
            };
            let Some(delay) = delay else {
                let ours = hub.take_pending(&session, &turn_id);
                if done > 0 {
                    let msg = json!({"promptId": root, "attempts": done, "turnId": turn_id, "reason": reason.as_str()});
                    hub.append_retry(&session, "auto_resume_exhausted", msg);
                    hub.lane_stranded(&session);
                } else if ours {
                    hub.settled_unretried(&session, &turn_id, "off");
                }
                return;
            };
            let attempt = done + 1;
            let now = super::now_ms();
            let limits = session.meta().usage_limits;
            let reset = reset_hint::reset_at(&error, limits.as_ref(), now);
            let reset = jittered_reset(reason, reset, now, &format!("{}#{index}", session.id))
                .max(not_before);
            let mut next_at = now.saturating_add(delay).max(reset.unwrap_or(now));
            // A rate limit's continuation waits out the chat's backoff, which grows with its
            // strikes, however early its own attempt would come; a parked chat's waits for a
            // retry (`rate_hold.rs`).
            let parked = reason == RetryReason::RateLimit && session.rate_hold.parked().is_some();
            if reason == RetryReason::RateLimit {
                let base = super::rate_hold::backoff_base(&delays);
                let backoff = super::rate_hold::backoff_ms(session.rate_hold.strikes(), base);
                next_at = next_at.max(now.saturating_add(staggered(backoff, &session.id)));
            }
            let delay = next_at.saturating_sub(now);
            let retry = RetrySummary {
                attempt: attempt as u64,
                // An unbounded wait counts on with its attempts (a restore drops a wait past
                // its `of`); `untilCapacity` says it never runs out.
                of: if unbounded { delays.len().max(attempt) } else { delays.len() } as u64,
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
            if parked {
                msg.set("parked", json!(true));
            }
            if unbounded {
                msg.set("untilCapacity", json!(true));
            }
            // The next daemon resends the same command (`restore.rs`).
            if let Some(slash) = &slash {
                msg.set("slash", json!(slash));
            }
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
                // Its wait may shorten the chat's idle period: the reaper takes the new deadline.
                hub.idle_wake.notify_one();
            }
            if set && !hub.retry_waits_for_capacity(&session, &error).await {
                hub.wait_retry(&session, &turn_id, reason, next_at, &wake).await;
                // Its wait over, a background capacity continuation waits its turn at the
                // host's gate; the permit lives as long as its attempt.
                let _permit = hub.capacity_gate_admit(&session, &turn_id, reason, &wake).await;
                let cut = CutTurn {
                    from: from.as_deref(),
                    prompt_id: &root,
                    turn_id: &turn_id,
                    control,
                    trust_gate,
                    error: &error,
                    not_before: None,
                    slash: slash.as_deref(),
                };
                hub.resume_or_compact(&session, cut, attempt).await;
                return;
            }
            let cut = CutTurn {
                from: from.as_deref(),
                prompt_id: &root,
                turn_id: &turn_id,
                control,
                trust_gate,
                error: &error,
                not_before: None,
                slash: slash.as_deref(),
            };
            hub.resume_or_compact(&session, cut, attempt).await;
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

    /// Whether the chat's continuation waits for a deadline later than `beyond` from now, for a
    /// reason its prompt alone answers (not the rate-limit hold, `rate_hold.rs` owns that, nor a
    /// context compaction, which needs the harness): the chat may sleep meanwhile, its
    /// continuation's prompt starts it again when due (`idle_governor.rs`).
    pub(super) fn continuation_waits_far(
        &self,
        session: &Session,
        beyond: std::time::Duration,
    ) -> bool {
        match session.auto_resume.lock().as_ref() {
            Some(Mark::Waiting { retry: Some(r), .. }) => {
                !matches!(r.reason, RetryReason::RateLimit | RetryReason::Context)
                    && r.next_at != u64::MAX
                    && r.next_at > super::now_ms().saturating_add(beyond.as_millis() as u64)
            }
            _ => false,
        }
    }

    /// Whether no continuation is pending but one whose wait is the chat's rate-limit hold
    /// (`rate_hold.rs` `wait_rate_hold`): a chat held past its idle period may then hibernate
    /// (`sleeps_through_hold`). One deciding, firing or waiting for any other reason keeps it.
    pub(super) fn continuation_waits_on_hold(&self, session: &Session) -> bool {
        match session.auto_resume.lock().as_ref() {
            Some(Mark::Waiting { retry: Some(r), .. }) => r.reason == RetryReason::RateLimit,
            mark => !is_pending(mark),
        }
    }

    /// Whether the chat's continuation is only a rate-limit retry waiting for the reset of a chat
    /// the limit has, with no turn running: a stop parks or closes such a chat and starts
    /// nothing (`stop_auto_resume`), so a conditional stop counts it idle (`stop_if_idle.rs`). A
    /// lane out of usage is not busy (Leo: "lanes dont count if they are idle and out of usage").
    pub(super) fn only_rate_limit_waits(&self, session: &Session) -> bool {
        session.rate_hold.limited()
            && session.turn().is_none()
            && !session.closing.load(std::sync::atomic::Ordering::SeqCst)
            && matches!(
                session.auto_resume.lock().as_ref(),
                Some(Mark::Waiting { retry: Some(r), .. }) if r.reason == RetryReason::RateLimit
            )
    }

    /// Puts a continuation for the cut turn `turn` waiting until `until`, for `reason`. A
    /// `RateLimit` one also holds the chat, as a Codex chat at its usage cap is held.
    #[cfg(test)]
    pub(super) fn wait_to_continue_for_test(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn: &str,
        until: u64,
        reason: RetryReason,
    ) {
        if reason == RetryReason::RateLimit {
            self.hold_for_rate_limit(session, turn, until, true);
        }
        session.auto_resume.lock().replace(Mark::Waiting {
            turn: turn.into(),
            retry: Some(RetrySummary {
                attempt: 1,
                of: 4,
                reason,
                next_at: until,
                prompt_id: "p".into(),
                turn_id: turn.into(),
            }),
            _wake: Wake(Arc::new(Notify::new())),
        });
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
                Some(Mark::Ending(_) | Mark::Stopping { .. })
            );
        if !cut {
            self.stop_auto_resume_by(session, Some(by));
        }
    }

    /// Stop or close: the chat's waiting continuation does not fire, and the turn running or
    /// ending now gets none, however it ends. A chat the rate limit has parks instead
    /// (`rate_hold.rs` `park_at_stop`).
    pub(super) fn stop_auto_resume(&self, session: &Session) {
        // A chat the account's rate limit has (held, parked, or with a strike) is parked by a
        // Stop, not released: it starts nothing by itself until a retry or the person's own
        // prompt (`rate_hold.rs`). Its rate-limit continuation that waits stays, and goes on
        // with that retry; one a turn now running would get, or a closed chat's, does not.
        if session.rate_hold.limited() {
            let keeps = !session.closing.load(std::sync::atomic::Ordering::SeqCst)
                && session.turn().is_none()
                && matches!(
                    session.auto_resume.lock().as_ref(),
                    Some(Mark::Waiting { retry: Some(r), .. }) if r.reason == RetryReason::RateLimit
                );
            // Parked first: the continuation the stop below wakes finds it so, and lifts nothing.
            self.park_at_stop(session, keeps);
            if !keeps {
                self.stop_auto_resume_by(session, None);
            }
            return;
        }
        self.stop_auto_resume_by(session, None);
    }

    /// A plain log load's read of the chat's stop records (`log_load.rs`): those the restore
    /// point carries (`point_stops`, through `after`), and the ones past it. The first prompt
    /// after a restart then finds the set read, not a scan of every segment's kind copy under
    /// its turn's start (goal infinite-chats: `start_turn` 63 ms of a 1 GB chat's 68 ms first
    /// send, 0.2 ms at 1 MB). A load that cannot read them leaves the set to the first prompt.
    pub(super) fn seed_prompt_stops(
        &self,
        session: &Session,
        after: u64,
        point_stops: Option<&[String]>,
    ) {
        // The load holds the chat's `log_load` lock here: never wait on the set under it. A set
        // someone holds is theirs to read (`prompt_stop_set`); this read is only a head start.
        let mut stopped = match session.auto_resume.stopped_prompts.try_lock() {
            Ok(stopped) => stopped,
            Err(std::sync::TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return,
        };
        if stopped.is_some() {
            return;
        }
        // A point that carries none (one saved before this) is read past: the whole log.
        let (after, mut roots) = match point_stops {
            Some(stops) => (after, stops.iter().cloned().collect::<HashSet<_>>()),
            None => (0, HashSet::new()),
        };
        let read = self.store.scan_kinds_after(
            &session.id,
            after,
            &["prompt_stop_requested"],
            &mut |event| {
                if event.dir == "mux"
                    && event.kind == "prompt_stop_requested"
                    && let Some(prompt) = event.msg.get("promptId").and_then(Value::as_str)
                {
                    roots.insert(prompt.to_owned());
                }
                true
            },
        );
        if read.is_ok() {
            *stopped = Some(roots);
        }
    }

    /// The chat's stop records as a restore point carries them, sorted; none while unread.
    pub(super) fn prompt_stops_carry(&self, session: &Session) -> Option<Vec<String>> {
        let stopped = session
            .auto_resume
            .stopped_prompts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut roots: Vec<String> = stopped.as_ref()?.iter().cloned().collect();
        roots.sort();
        Some(roots)
    }

    /// Read durable exact-prompt tombstones once per restored session. Callers hold
    /// the retry mark lock, serializing cancellation with turn admission.
    fn prompt_stop_set<'a>(
        &self,
        session: &'a Session,
    ) -> Result<std::sync::MutexGuard<'a, Option<HashSet<String>>>, RpcError> {
        let mut stopped = session
            .auto_resume
            .stopped_prompts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if stopped.is_none() {
            let mut roots = HashSet::new();
            self.scan_for_rebuild(session, &["prompt_stop_requested"], &mut |event| {
                if event.dir == "mux"
                    && event.kind == "prompt_stop_requested"
                    && let Some(prompt) = event.msg.get("promptId").and_then(Value::as_str)
                {
                    roots.insert(prompt.to_owned());
                }
                true
            })
            .map_err(|error| {
                RpcError::internal(format!("cannot read prompt stop boundaries: {error}"))
            })?;
            *stopped = Some(roots);
        }
        Ok(stopped)
    }

    fn prompt_stop_recorded(&self, session: &Session, root: &str) -> Result<bool, RpcError> {
        let mut found = false;
        self.store
            .scan_kinds(&session.id, &["prompt_stop_requested"], &mut |event| {
                found = event.dir == "mux"
                    && event.msg.get("promptId").and_then(Value::as_str) == Some(root);
                !found
            })
            .map_err(|error| {
                RpcError::internal(format!("cannot read back prompt stop boundary: {error}"))
            })?;
        Ok(found)
    }

    /// Fence only the automatic continuation chain belonging to this accepted prompt.
    /// Lock order matches retry admission: retry state, append, then turn identity. An
    /// unrelated person's next turn and its retry mark are never replaced or stopped.
    /// Returns the exact running descendant, when the original already auto-resumed.
    pub(super) fn stop_prompt_retry(
        &self,
        session: &Session,
        prompt_id: &str,
    ) -> Result<Option<String>, RpcError> {
        let root = split_attempt(prompt_id).0;
        let mut pending = session.auto_resume.lock();
        {
            let mut stopped = self.prompt_stop_set(session)?;
            if !stopped.as_ref().is_some_and(|roots| roots.contains(root)) {
                let mut recorded = false;
                for _ in 0..2 {
                    if !self.append_stored(
                        session,
                        "mux",
                        "prompt_stop_requested",
                        json!({"promptId":root}),
                    ) {
                        return Err(RpcError::internal("cannot persist prompt stop boundary"));
                    }
                    self.store.flush_session(&session.id).map_err(|error| {
                        RpcError::internal(format!("cannot flush prompt stop boundary: {error}"))
                    })?;
                    if self.prompt_stop_recorded(session, root)? {
                        recorded = true;
                        break;
                    }
                    // A pre-existing unterminated line can swallow the first record.
                    // That append ends the line; one more marker is independently readable.
                    // Never alter history or acknowledge an unverified cancellation.
                }
                if !recorded {
                    return Err(RpcError::internal("prompt stop boundary is not readable"));
                }
                // Never cache or acknowledge a boundary until it is on stable storage:
                // a failed write must be retried, including by this same daemon.
                stopped.get_or_insert_with(HashSet::new).insert(root.to_owned());
            }
        }
        let mut turns = std::collections::BTreeSet::new();
        let mut latest = None;
        let scanned = self.store.scan_kinds(
            &session.id,
            &["queued", "user_message", "turn_started", "turn_result", "auto_resume_scheduled"],
            &mut |event| {
                if event.dir == "mux"
                    && matches!(
                        event.kind.as_str(),
                        "queued"
                            | "user_message"
                            | "turn_started"
                            | "turn_result"
                            | "auto_resume_scheduled"
                    )
                    && event
                        .msg
                        .get("promptId")
                        .and_then(Value::as_str)
                        .is_some_and(|id| split_attempt(id).0 == root)
                    && let Some(turn) = event.msg.get("turnId").and_then(Value::as_str)
                {
                    turns.insert(turn.to_owned());
                    latest = Some(turn.to_owned());
                }
                true
            },
        );
        scanned
            .map_err(|error| RpcError::internal(format!("cannot fence prompt retry: {error}")))?;
        let active = session.turn().filter(|turn| split_attempt(&turn.prompt_id).0 == root);
        if let Some(active) = &active {
            turns.insert(active.turn_id.clone());
            latest = Some(active.turn_id.clone());
        }
        let marked = match pending.as_ref() {
            Some(
                Mark::Waiting { turn, .. }
                | Mark::Firing(turn, _)
                | Mark::Ending(turn)
                | Mark::Stopped(turn)
                | Mark::Stopping { turn, .. },
            ) => Some(turn.clone()),
            None => None,
        };
        if let Some(turn) = marked.filter(|turn| turns.contains(turn)) {
            let fired = match pending.as_ref() {
                Some(Mark::Firing(_, fired_gen) | Mark::Stopping { fired_gen, .. }) => {
                    Some(*fired_gen)
                }
                _ => None,
            };
            pending.replace(if let Some(fired_gen) = fired {
                session.auto_resume.fence_fired();
                Mark::stopping(turn.clone(), fired_gen)
            } else {
                Mark::Stopped(turn.clone())
            });
            self.append(
                session,
                "mux",
                "auto_resume_stopped",
                json!({"turnId":turn,"promptId":root}),
            );
            self.append(
                session,
                "mux",
                "auto_resume_settled",
                json!({"turnId":turn,"promptId":root,"why":"stopped"}),
            );
        } else if let Some(turn) = latest {
            // Persist a boundary even in the crash window between terminal result and
            // schedule. Restore and a late schedule both consult this exact turn.
            self.append(
                session,
                "mux",
                "turn_stop_requested",
                json!({"turnId":turn,"promptId":root}),
            );
            if pending.is_none() {
                pending.replace(Mark::Stopped(turn));
            }
        }
        Ok(active.map(|turn| turn.prompt_id))
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
            Some(Mark::Waiting { retry: Some(_), .. } | Mark::Firing(..))
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
                    Some(Mark::Waiting { turn, .. } | Mark::Firing(turn, _)) => Some(turn.clone()),
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
            Some(Mark::Ending(t)) => (Some(t.clone()), None),
            Some(Mark::Firing(t, fired_gen) | Mark::Stopping { turn: t, fired_gen, .. }) => {
                (Some(t.clone()), Some(*fired_gen))
            }
            _ => (None, None),
        };
        if fired.is_some() {
            // The fired task's turn never starts now, even once its mark is gone.
            session.auto_resume.fence_fired();
        }
        match (session.turn().map(|t| t.turn_id), ending) {
            (Some(t), _) => pending.replace(Mark::Stopped(t)),
            (None, Some(t)) if let Some(fired_gen) = fired => {
                pending.replace(Mark::stopping(t, fired_gen))
            }
            (None, Some(t)) => pending.replace(Mark::Stopped(t)),
            (None, None) => pending.take(),
        };
        drop(pending);
        session.queue_moved.notify_waiters();
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
    pub(super) fn clear_prompt_stop_cache_for_test(&self, session: &Session) {
        session
            .auto_resume
            .stopped_prompts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
    }

    #[cfg(test)]
    pub(super) fn stopped_for_test(&self, session: &Session, turn: &str) -> bool {
        matches!(session.auto_resume.lock().as_ref(), Some(Mark::Stopped(t)) if t == turn)
    }

    /// Tests only: a continuation of `turn` waits, for `reason`'s wait.
    #[cfg(test)]
    pub(super) fn set_waiting_for_test(&self, session: &Session, turn: &str, reason: RetryReason) {
        let retry = RetrySummary {
            attempt: 1,
            of: 4,
            reason,
            next_at: u64::MAX,
            prompt_id: format!("p-{turn}"),
            turn_id: turn.to_owned(),
        };
        let wake = Wake(Arc::new(Notify::new()));
        session.auto_resume.lock().replace(Mark::Waiting {
            turn: turn.to_owned(),
            retry: Some(retry),
            _wake: wake,
        });
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
        fired: Option<u64>,
        exclusive: bool,
        subagent_retry: bool,
        turn: super::TurnInfo,
    ) -> Result<(), RpcError> {
        self.resume_before_turn();
        let mut pending = session.auto_resume.lock();
        // Transfer replacement seals the old instance before staging its store. Reject before
        // installing a TurnInfo so a fired retry cannot start against the incoming journal.
        if session.replaced.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(superseded());
        }
        if self
            .prompt_stop_set(session)?
            .as_ref()
            .is_some_and(|roots| roots.contains(split_attempt(&turn.prompt_id).0))
        {
            return Err(super::turns::stopped_before_prompt());
        }
        Self::compaction_started(session, &turn);
        let continuation = is_pending(pending.as_ref());
        if exclusive
            && (continuation || session.harness_turn.load(std::sync::atomic::Ordering::SeqCst))
        {
            return Err(retry_turn::busy());
        }
        // A fired task a Stop overtook: refused even when its mark is gone (its Stopping mark
        // past its bound) or a later fire took the chat (#54378).
        if fired.is_some_and(|fired_gen| !session.auto_resume.current(fired_gen)) {
            return Err(stopped());
        }
        if let Some(cut) = after {
            let mark = match pending.as_ref() {
                Some(Mark::Firing(t, fired_gen))
                    if t == cut && fired.is_none_or(|f| f == *fired_gen) =>
                {
                    Some(true)
                }
                Some(Mark::Stopped(t)) if t == cut => Some(false),
                // Its task clears it once it ends.
                Some(Mark::Stopping { turn: t, .. }) if t == cut => return Err(stopped()),
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
        // The person waits on their own turn until its first token (`hub/cpu_pressure.rs`).
        let waited = turn.persons && !turn.trigger;
        self.subagent_retries.start(&session.id, &prompt_id, subagent_retry, || {
            session.awaiting_reply.store(waited, std::sync::atomic::Ordering::SeqCst);
            *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = Some(turn);
            if waited {
                super::cpu_pressure::wake();
            }
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
                Some(Mark::Ending(t) | Mark::Firing(t, _)) => t == cut,
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
    /// stays, as firing, until its turn starts. Its generation, for `PromptOptions::fired` and
    /// [`Hub::clear_fired`]. Else why it does not: `superseded` when a newer turn took its mark
    /// or the chat moved on, `stopped` when Stop or close took it.
    fn fire_pending(&self, session: &Session, cut_turn: &str) -> Result<u64, &'static str> {
        let mut pending = session.auto_resume.lock();
        match pending.as_ref() {
            Some(Mark::Waiting { turn, .. }) if turn == cut_turn => {
                let fired_gen = session.auto_resume.next_generation();
                pending.replace(Mark::Firing(cut_turn.to_owned(), fired_gen));
                Ok(fired_gen)
            }
            Some(Mark::Waiting { .. } | Mark::Firing(..) | Mark::Ending(_)) => Err("superseded"),
            // The turn that ended before `still_cut` reads its result is a newer one.
            _ if !still_cut(session, cut_turn) => Err("superseded"),
            _ => Err("stopped"),
        }
    }

    /// Drops what is left of the continuation of `cut_turn` that fired as generation `fired_gen`
    /// and did not start its turn. A later fire's mark for the same turn is not its own.
    fn clear_fired(&self, session: &Session, cut_turn: &str, fired_gen: u64) {
        let mut pending = session.auto_resume.lock();
        let ours = match pending.as_ref() {
            Some(Mark::Firing(t, g) | Mark::Stopping { turn: t, fired_gen: g, .. }) => {
                t == cut_turn && *g == fired_gen
            }
            Some(Mark::Stopped(t)) => t == cut_turn,
            _ => false,
        };
        if ours {
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
        let reason = super::turn_errors::resume_cause(cut.error, cut.error).unwrap_or("transport");
        // What the account's rate limit held queued behind it; it decides below (`rate_hold.rs`).
        let rate = reason == "rate_limit" && Self::rate_held(session);
        let skip = |why: &str| {
            self.append_retry(session, "auto_resume_skipped", skipped(why));
            if reason == "rate_limit" {
                self.lift_rate_hold(session, why);
            }
        };
        let fired_gen = match self.fire_pending(session, cut_turn) {
            Ok(fired_gen) => fired_gen,
            // Stop or close took it, or a newer turn replaced it.
            Err(why) => {
                skip(why);
                return;
            }
        };
        if session.status() == SessionStatus::Closed || session.moving().is_some() {
            self.clear_fired(session, cut_turn, fired_gen);
            skip("closed");
            return;
        }
        if !still_cut_by(session, cut_turn, rate) {
            self.clear_fired(session, cut_turn, fired_gen);
            skip("superseded");
            return;
        }
        // A sustained overload: this attempt runs on a smaller model (`capacity_failover.rs`).
        if reason == "capacity" {
            self.fail_over_on_capacity(session, root, attempt).await;
        }
        let held = self.held_by(session, root, cut_turn);
        // At a rate limit's reset, what queued meanwhile goes in as the one next turn, carrying
        // this continuation's words, instead of a turn of its own before it.
        if rate
            && cut.slash.is_none()
            && self.rate_hold_due(session, &held, continue_text_for(session, cut.error, reason))
        {
            self.clear_fired(session, cut_turn, fired_gen);
            self.append_retry(session, "auto_resume_skipped", skipped("folded"));
            return;
        }
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
            fired: Some(fired_gen),
            ..PromptOptions::default()
        };
        // A cut `/compact` goes again as itself: the chat still needs compacting.
        let mut text =
            cut.slash.map_or_else(|| continue_text_for(session, cut.error, reason), str::to_owned);
        // A dead agent took the steers it had not read with it (`unread_steers.rs`). A live one
        // still holds them and runs them itself (`carried_turn.rs`).
        if reason == "agent_exited" {
            text = unread_steers::with_unread(text, &self.unread_steers(&session.id, cut_turn));
        }
        let blocks = vec![json!({"type": "text", "text": text})];
        // An agent sent through an earlier daemon's vault egress proxy cannot reach it
        // (`ECONNREFUSED`, or a CA it does not trust): retrying in that process fails the same
        // way every attempt. It ends first, and this prompt starts a fresh one on the same
        // conversation (`stale_host_respawn.rs`).
        self.end_stale_proxy_before_retry(session).await;
        let result = self.prompt_with(session, blocks, "acpmux", false, opts).await;
        self.finish_auto_resume(
            session,
            &cut,
            attempt,
            &held,
            (result, fired_gen),
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
        (result, fired_gen): (Result<Value, RpcError>, u64),
        accepted: bool,
    ) {
        let (root, cut_turn) = (cut.prompt_id, cut.turn_id);
        self.clear_fired(session, cut_turn, fired_gen);
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
    pub(super) fn held_by(&self, session: &Session, root: &str, cut_turn: &str) -> Vec<String> {
        let mut paused: HashMap<String, Vec<String>> = HashMap::new();
        // An attempt's turn, and the turn it continues.
        let mut continues: HashMap<String, String> = HashMap::new();
        // Its two kinds only, from the log's copies of them (`store/kind_index.rs`).
        let kinds = ["queue_paused", "user_message"];
        let _ = self.store.scan_kinds(&session.id, &kinds, &mut |e: EventRecord| {
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
#[path = "auto_resume/tests.rs"]
mod tests;

#[cfg(test)]
#[path = "auto_resume/turn_completion_tests.rs"]
mod turn_completion_tests;
