//! The agent chat's prompts on their way to the Mac: the chat twin of the terminal's
//! [`Outbox`](crate::Outbox).
//!
//! Leo (relayed, 2026-11-24): "we need to absolutely slam the s\*\*\* out of our transport
//! protocols and make them bulletproof."
//!
//! A [`PromptOutbox`] holds each prompt from the tap until the Mac answers it (a prompt's answer
//! is its turn's end):
//!
//! - **One id, for life.** A prompt is keyed by its `promptId`, made at the tap. acpmux runs a
//!   `promptId` once (`hub/mod.rs`, `{duplicate:true}`), so every attempt carries the same id.
//!   Once an attempt was written, every later one is a `resend` (acpmux checks its session log
//!   too), so a prompt whose answer was lost is never run twice.
//! - **In tap order.** One prompt is written at a time, and only the first unwritten one: a later
//!   prompt never goes before an earlier one that has not gone yet, across any number of drops.
//! - **Offline, it waits.** While the link is down prompts queue; the link coming back sends them
//!   at once, in order.
//! - **Retries back off.** A write that fails, or an answer that is lost, goes again after a
//!   jittered, capped backoff ([`RETRY_FIRST`] doubling up to [`RETRY_CAP`]); a link that comes
//!   back skips the wait.
//! - **Gives up honestly.** A prompt that waited for the link longer than the hold comes back with
//!   its text: [`PromptOutcome::NotSent`] when no attempt was written, else
//!   [`PromptOutcome::MaybeSent`] (it may have run: the screen must not invite a second send).
//!   Every unwritten prompt behind it comes back with it, so none goes after an earlier one that
//!   did not.
//! - **A look per prompt** ([`PromptLook`]) for the chat to draw: sent from the tap on,
//!   retrying only after [`RETRYING_AFTER`] without the link, failed once it gave up.
//!
//! The outbox does no I/O. Its owner (the phone's chat source) asks for the next prompt to write,
//! writes it and reports what happened.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// How long a prompt waits for the link before it comes back to the composer: the chat's
/// `heldPromptWindow` (the terminal's key hold), measured from when it began to wait.
pub const DEFAULT_HOLD: Duration = Duration::from_secs(10);

/// The first retry's wait after a failed write or a lost answer (the chat's old single 500 ms
/// re-flush). Each further failure doubles it.
pub const RETRY_FIRST: Duration = Duration::from_millis(500);

/// The longest wait between retries.
pub const RETRY_CAP: Duration = Duration::from_secs(8);

/// How long a prompt goes unwritten before it looks [`PromptLook::Retrying`]: below it a blip is
/// invisible (Leo: "they dont need to know that it's updating before they KNOW it's updating").
pub const RETRYING_AFTER: Duration = Duration::from_secs(2);

/// Prompts that gave up whose [`PromptLook::Failed`] is remembered (oldest forgotten first).
pub const FAILED_MEMORY: usize = 64;

/// The wait before retry number `attempt` (1 = the first retry), jittered by `unit` in `[0, 1)`:
/// uniform in `[d/2, d]` where `d = RETRY_FIRST * 2^(attempt-1)`, capped at [`RETRY_CAP`]. The
/// jitter keeps many chats that lost one link from writing to the next one in lockstep.
pub fn retry_delay(attempt: u32, unit: f64) -> Duration {
    let doublings = attempt.saturating_sub(1).min(16);
    let full = RETRY_FIRST.saturating_mul(1u32 << doublings).min(RETRY_CAP);
    let unit = if unit.is_finite() { unit.clamp(0.0, 1.0) } else { 0.0 };
    full / 2 + (full / 2).mul_f64(unit)
}

/// How a prompt looks on screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptLook {
    /// From the tap on, while it goes or waits less than [`RETRYING_AFTER`].
    Sent,
    /// Unwritten for [`RETRYING_AFTER`] or more: the outbox keeps trying.
    Retrying,
    /// The outbox gave up on it (past the hold, or the Mac refused it).
    Failed,
}

/// How a prompt ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PromptOutcome {
    /// The Mac answered it.
    Sent,
    /// The Mac refused it: nothing ran. Its owner says why (the Mac's own words).
    Refused { text: String },
    /// No attempt was written before the hold ran out: nothing ran, the text goes back.
    NotSent { text: String },
    /// An attempt was written and its answer never came: it may have run.
    MaybeSent { text: String },
}

/// One prompt that ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptDone {
    pub id: String,
    pub outcome: PromptOutcome,
}

/// One attempt to make: write `session/prompt` with this `promptId` and `resend`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptRequest {
    pub id: String,
    /// An earlier attempt was written (or the person sent it again): acpmux checks its log.
    pub resend: bool,
    /// This attempt's number, from 1.
    pub attempt: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    /// Waiting to be written.
    Queued,
    /// Its write is under way.
    Writing,
    /// Written: its answer (the turn's end) is awaited.
    Written,
}

#[derive(Debug, Clone)]
struct Entry {
    id: String,
    text: String,
    tapped: Instant,
    /// When it began to wait for the link (its tap, a hold, the drop that lost it): its age.
    waiting_since: Instant,
    state: State,
    /// An attempt was written (or it came in as a resend): every attempt from now is a resend.
    resend: bool,
    written_once: bool,
    attempts: u32,
    /// Failures in a row since the last write that took.
    failures: u32,
    not_before: Option<Instant>,
}

/// The chat's prompts the Mac has not answered yet, in tap order.
#[derive(Debug, Clone)]
pub struct PromptOutbox {
    hold: Duration,
    link_up: bool,
    entries: VecDeque<Entry>,
    failed: VecDeque<String>,
    rng: u64,
}

impl PromptOutbox {
    /// `seed` drives the retry jitter (a test passes a fixed one).
    pub fn new(hold: Duration, seed: u64) -> PromptOutbox {
        PromptOutbox {
            hold,
            link_up: false,
            entries: VecDeque::new(),
            failed: VecDeque::new(),
            rng: seed,
        }
    }

    pub fn hold(&self) -> Duration {
        self.hold
    }

    pub fn set_hold(&mut self, hold: Duration) {
        self.hold = hold;
    }

    pub fn is_link_up(&self) -> bool {
        self.link_up
    }

    /// The link's state. Coming back, every queued prompt may go at once, in order (no backoff
    /// wait for a link that is new).
    pub fn set_link(&mut self, up: bool) {
        if up && !self.link_up {
            for entry in &mut self.entries {
                entry.not_before = None;
            }
        }
        self.link_up = up;
    }

    /// A tap on Send (after its attachments are uploaded): `id` is its `promptId`, `resend` the
    /// intent's own flag. `tapped` places it among the others; it waits from `tapped` when it can
    /// go at once, else from `now`. False when a prompt with this id is already here (a second
    /// push is never a second send).
    pub fn push(
        &mut self,
        id: impl Into<String>,
        text: impl Into<String>,
        resend: bool,
        tapped: Instant,
        now: Instant,
    ) -> bool {
        let id = id.into();
        if self.entries.iter().any(|e| e.id == id) {
            return false;
        }
        self.failed.retain(|f| *f != id);
        let waits = !self.link_up || self.entries.iter().any(|e| e.state != State::Written);
        let entry = Entry {
            id,
            text: text.into(),
            tapped,
            waiting_since: if waits { now } else { tapped },
            state: State::Queued,
            resend,
            written_once: false,
            attempts: 0,
            failures: 0,
            not_before: None,
        };
        let index =
            self.entries.iter().position(|e| e.tapped > tapped).unwrap_or(self.entries.len());
        self.entries.insert(index, entry);
        true
    }

    /// The next prompt to write: the first unwritten one, when the link is up, nothing else is
    /// being written, its retry wait is over and it is within the hold (one past it is for
    /// [`expire`](Self::expire), never sent behind the person's back).
    pub fn next_request(&mut self, now: Instant) -> Option<PromptRequest> {
        if !self.link_up || self.entries.iter().any(|e| e.state == State::Writing) {
            return None;
        }
        let hold = self.hold;
        let entry = self.entries.iter_mut().find(|e| e.state == State::Queued)?;
        if entry.not_before.is_some_and(|at| now < at)
            || now.saturating_duration_since(entry.waiting_since) >= hold
        {
            return None;
        }
        entry.state = State::Writing;
        entry.attempts = entry.attempts.saturating_add(1);
        entry.not_before = None;
        Some(PromptRequest { id: entry.id.clone(), resend: entry.resend, attempt: entry.attempts })
    }

    /// The prompt's write took: its answer is awaited. From now on every attempt is a resend.
    pub fn wrote(&mut self, id: &str) {
        if let Some(entry) = self.entry_mut(id) {
            entry.state = State::Written;
            entry.resend = true;
            entry.written_once = true;
            entry.failures = 0;
        }
    }

    /// The prompt's write failed (the link did not take it): it goes again after a backoff, its
    /// wait unchanged.
    pub fn write_failed(&mut self, id: &str, now: Instant) {
        self.requeue(id, now, false);
    }

    /// The prompt was written and its answer was lost (the link dropped first): it may have run,
    /// so it goes again as a resend, waiting from `now`.
    pub fn lost(&mut self, id: &str, now: Instant) {
        self.requeue(id, now, true);
    }

    fn requeue(&mut self, id: &str, now: Instant, from_now: bool) {
        let unit = self.next_unit();
        let Some(entry) = self.entry_mut(id) else { return };
        entry.state = State::Queued;
        if from_now {
            entry.waiting_since = now;
        }
        entry.failures = entry.failures.saturating_add(1);
        entry.not_before = Some(now + retry_delay(entry.failures, unit));
    }

    /// The Mac answered the prompt (its turn ended, or `{duplicate:true}`): sent.
    pub fn answered(&mut self, id: &str) -> Option<PromptDone> {
        let index = self.entries.iter().position(|e| e.id == id)?;
        let entry = self.entries.remove(index)?;
        Some(PromptDone { id: entry.id, outcome: PromptOutcome::Sent })
    }

    /// The Mac refused the prompt (an error answer: nothing ran). Its text goes back.
    pub fn refused(&mut self, id: &str) -> Option<PromptDone> {
        let index = self.entries.iter().position(|e| e.id == id)?;
        let entry = self.entries.remove(index)?;
        self.remember_failed(entry.id.clone());
        Some(PromptDone { id: entry.id, outcome: PromptOutcome::Refused { text: entry.text } })
    }

    /// Unwritten prompts past the hold: when any is, every unwritten one comes back, in tap
    /// order (none goes after an earlier one that did not). One being written waits for its
    /// write; written ones wait for their answers.
    pub fn expire(&mut self, now: Instant) -> Vec<PromptDone> {
        let hold = self.hold;
        let due = self.entries.iter().any(|e| {
            e.state == State::Queued && now.saturating_duration_since(e.waiting_since) >= hold
        });
        if !due {
            return Vec::new();
        }
        self.take_where(|e| e.state == State::Queued)
    }

    /// Gives up on the prompt `id` now and on every unwritten prompt after it, in tap order.
    pub fn give_up_from(&mut self, id: &str) -> Vec<PromptDone> {
        let Some(index) = self.entries.iter().position(|e| e.id == id) else { return Vec::new() };
        let mut position = 0usize;
        self.take_where(|e| {
            let here = position;
            position += 1;
            here >= index && e.state == State::Queued
        })
    }

    /// Every unwritten prompt, out of this outbox now (the chat's next source takes them over),
    /// in tap order with when each was tapped.
    pub fn drain_unwritten(&mut self) -> Vec<(String, Instant)> {
        let mut out = Vec::new();
        self.entries.retain(|e| {
            if e.state == State::Queued {
                out.push((e.id.clone(), e.tapped));
                false
            } else {
                true
            }
        });
        out
    }

    fn take_where(&mut self, mut take: impl FnMut(&Entry) -> bool) -> Vec<PromptDone> {
        let mut done = Vec::new();
        let mut kept = VecDeque::with_capacity(self.entries.len());
        for entry in self.entries.drain(..) {
            if take(&entry) {
                let outcome = if entry.written_once {
                    PromptOutcome::MaybeSent { text: entry.text }
                } else {
                    PromptOutcome::NotSent { text: entry.text }
                };
                done.push(PromptDone { id: entry.id, outcome });
            } else {
                kept.push_back(entry);
            }
        }
        self.entries = kept;
        for d in &done {
            self.remember_failed(d.id.clone());
        }
        done
    }

    /// How the prompt `id` looks at `now`. One this outbox does not hold (answered, or never
    /// here) looks sent.
    pub fn look(&self, id: &str, now: Instant) -> PromptLook {
        if let Some(entry) = self.entries.iter().find(|e| e.id == id) {
            let unwritten = entry.state != State::Written;
            if unwritten && now.saturating_duration_since(entry.waiting_since) >= RETRYING_AFTER {
                return PromptLook::Retrying;
            }
            return PromptLook::Sent;
        }
        if self.failed.iter().any(|f| f == id) { PromptLook::Failed } else { PromptLook::Sent }
    }

    /// Forgets a failed prompt's look (the person dismissed it or sent it again).
    pub fn forget(&mut self, id: &str) {
        self.failed.retain(|f| f != id);
    }

    /// When something is next due: the oldest unwritten prompt's hold, or (link up) the first
    /// one's retry. `None` when nothing waits.
    pub fn next_wake(&self, now: Instant) -> Option<Duration> {
        let mut wake: Option<Instant> = None;
        let mut first_queued = true;
        for entry in self.entries.iter().filter(|e| e.state == State::Queued) {
            let mut at = entry.waiting_since + self.hold;
            if first_queued && self.link_up {
                if let Some(retry) = entry.not_before {
                    at = at.min(retry);
                }
                first_queued = false;
            }
            wake = Some(wake.map_or(at, |w| w.min(at)));
        }
        wake.map(|at| at.saturating_duration_since(now))
    }

    /// When the next prompt turns [`PromptLook::Retrying`] (for the chat's redraw).
    pub fn next_look_change(&self, now: Instant) -> Option<Duration> {
        self.entries
            .iter()
            .filter(|e| e.state != State::Written)
            .map(|e| e.waiting_since + RETRYING_AFTER)
            .filter(|at| *at > now)
            .min()
            .map(|at| at.saturating_duration_since(now))
    }

    /// The unwritten prompts' ids, in tap order.
    pub fn unwritten(&self) -> Vec<String> {
        self.entries.iter().filter(|e| e.state == State::Queued).map(|e| e.id.clone()).collect()
    }

    /// Prompts not answered yet.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn entry_mut(&mut self, id: &str) -> Option<&mut Entry> {
        self.entries.iter_mut().find(|e| e.id == id)
    }

    fn remember_failed(&mut self, id: String) {
        self.failed.retain(|f| *f != id);
        self.failed.push_back(id);
        while self.failed.len() > FAILED_MEMORY {
            self.failed.pop_front();
        }
    }

    /// SplitMix64, as a unit in `[0, 1)`.
    fn next_unit(&mut self) -> f64 {
        self.rng = self.rng.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.rng;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64
    }
}

#[cfg(test)]
#[path = "chat_tests.rs"]
mod tests;
