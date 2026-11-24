//! The agent chat's prompts on their way to the Mac: the chat twin of the terminal's
//! [`Outbox`](crate::Outbox), and the one send queue for a prompt's text and its attachments.
//!
//! Leo (relayed, 2026-11-24): "we need to absolutely slam the s\*\*\* out of our transport
//! protocols and make them bulletproof." And: "i also couldnt cancel out of the send. i need to
//! be able to do that otherwise i cant edit or anything to retry or delete and remove."
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
//! - **Uploads first, never in the way.** A prompt's attachments upload (the owner's upload driver
//!   reports into [`PromptOutbox::uploaded`] and friends) before it is written. A push never
//!   waits for anything, so the composer is free at the tap; a prompt behind one still uploading
//!   is queued at once and goes after it.
//! - **Offline, it waits.** While the link is down prompts queue; the link coming back sends them
//!   at once, in order.
//! - **Retries back off.** A write that fails, an answer that is lost, or an upload that fails
//!   goes again after a jittered, capped backoff ([`RETRY_FIRST`] doubling up to [`RETRY_CAP`]);
//!   a link that comes back skips the wait.
//! - **Gives up honestly.** A prompt that waited for the link longer than the hold comes back with
//!   its text and attachments: [`PromptOutcome::NotSent`] when no attempt was written, else
//!   [`PromptOutcome::MaybeSent`] (it may have run: the screen must not invite a second send).
//!   Every unwritten prompt behind it comes back with it, so none goes after an earlier one that
//!   did not.
//! - **The person stays in charge.** Any pending prompt can be cancelled, edited, retried now or
//!   deleted at any point ([`PromptOutbox::cancel`], [`PromptOutbox::edit`],
//!   [`PromptOutbox::retry_now`], [`PromptOutbox::delete`]). One that never left comes back at
//!   once; one that may have reached the Mac is taken off the Mac's queue (`_acpmux/queue_remove`)
//!   and reported as [`PromptOutcome::MaybeSent`] when that is too late.
//! - **A look per prompt** ([`PromptLook`]) for the chat to draw: sent from the tap on,
//!   retrying only after [`RETRYING_AFTER`] without getting out, failed once it gave up.
//!
//! The outbox does no I/O. Its owner (the phone's chat source) asks for the next upload and the
//! next prompt to write, does them and reports what happened.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// How long a prompt waits for the link before it comes back to the composer: the chat's
/// `heldPromptWindow` (the terminal's key hold), measured from when it began to wait.
pub const DEFAULT_HOLD: Duration = Duration::from_secs(10);

/// The first retry's wait after a failed write, a lost answer or a failed upload (the chat's old
/// single 500 ms re-flush). Each further failure doubles it.
pub const RETRY_FIRST: Duration = Duration::from_millis(500);

/// The longest wait between retries.
pub const RETRY_CAP: Duration = Duration::from_secs(8);

/// How long a prompt goes unwritten before it looks [`PromptLook::Retrying`]: below it a blip is
/// invisible (Leo: "they dont need to know that it's updating before they KNOW it's updating").
pub const RETRYING_AFTER: Duration = Duration::from_secs(2);

/// Prompts that gave up whose [`PromptLook::Failed`] is remembered (oldest forgotten first).
pub const FAILED_MEMORY: usize = 64;

/// Failed uploads of one attachment before its prompt gives up ([`PromptOutcome::UploadFailed`]).
pub const UPLOAD_ATTEMPTS: u32 = 3;

/// Attachments uploading at once, across the chat's prompts, in tap order.
pub const MAX_UPLOADS: usize = 2;

/// The wait before retry number `attempt` (1 = the first retry), jittered by `unit` in `[0, 1]`:
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
    /// From the tap on, while it goes, uploads, or waits less than [`RETRYING_AFTER`].
    Sent,
    /// Unwritten for [`RETRYING_AFTER`] or more after its uploads, or an upload failed and goes
    /// again: the outbox keeps trying.
    Retrying,
    /// The outbox gave up on it (past the hold, the Mac refused it, its upload failed).
    Failed,
}

/// Where one attachment's upload is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UploadState {
    /// Not started (or going again after a failure or a drop).
    Pending,
    /// Under way: `sent` of `total` bytes (`total` 0 when not known yet).
    Uploading { sent: u64, total: u64 },
    /// On the Mac at `mac_path`.
    Uploaded { mac_path: String },
    /// The last attempt failed with `reason`; it goes again after a backoff, up to
    /// [`UPLOAD_ATTEMPTS`].
    Failed { reason: String },
}

/// One attachment of a prompt: the owner's id for it and its upload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment {
    pub id: String,
    pub state: UploadState,
}

/// How a prompt ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PromptOutcome {
    /// The Mac answered it.
    Sent,
    /// The Mac refused it: nothing ran. Its owner says why (the Mac's own words).
    Refused,
    /// No attempt was written before the hold ran out: nothing ran, the text goes back.
    NotSent,
    /// An attempt was written and its answer never came, or it could not be taken off the Mac's
    /// queue: it may have run.
    MaybeSent,
    /// An attachment failed to upload [`UPLOAD_ATTEMPTS`] times: nothing was written.
    UploadFailed { reason: String },
    /// The person cancelled it before it reached the Mac, or the Mac took it off its queue.
    Cancelled,
}

/// One prompt that ended, with what the composer may get back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptDone {
    pub id: String,
    pub outcome: PromptOutcome,
    pub text: String,
    pub attachments: Vec<Attachment>,
}

/// One attempt to make: write `session/prompt` with this `promptId` and `resend`, its
/// attachments at their Mac paths.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptRequest {
    pub id: String,
    /// An earlier attempt was written (or the person sent it again): acpmux checks its log.
    pub resend: bool,
    /// This attempt's number, from 1.
    pub attempt: u32,
    /// `(attachment id, Mac path)`, in the prompt's order.
    pub attachments: Vec<(String, String)>,
}

/// One upload to start: attachment `attachment` of prompt `prompt`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadRequest {
    pub prompt: String,
    pub attachment: String,
}

/// What a cancel (or delete, or the old half of an edit) asks of the owner.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CancelStep {
    /// It never left: here it is back ([`PromptOutcome::Cancelled`]). Any upload of it under way
    /// is moot.
    Returned(PromptDone),
    /// It may be on the Mac: send `_acpmux/queue_remove` for this `promptId` and report with
    /// [`PromptOutbox::remove_answered`]. It is never sent again.
    RemoveOnMac { id: String },
}

/// What an edit did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditStep {
    /// It never left: its text and attachments are replaced in place, same id, same place.
    Edited,
    /// It may be on the Mac: the edit goes as a new prompt (`new_id`) in its place, and the old
    /// one is to be taken off the Mac's queue (`RemoveOnMac`).
    Replaced { remove: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    /// Waiting to be written (its uploads first).
    Queued,
    /// Its write is under way.
    Writing,
    /// Written: its answer (the turn's end) is awaited.
    Written,
    /// Cancelled after it may have reached the Mac: never sent again; the Mac's queue removal is
    /// awaited.
    Cancelling,
}

#[derive(Debug, Clone)]
struct Slot {
    attachment: Attachment,
    failures: u32,
    not_before: Option<Instant>,
}

#[derive(Debug, Clone)]
struct Entry {
    id: String,
    text: String,
    slots: Vec<Slot>,
    tapped: Instant,
    /// When it began to wait for the link (its tap, a hold, its uploads ending, the drop that
    /// lost it): its age against the hold.
    waiting_since: Instant,
    state: State,
    /// Every attempt from now is a resend (one was written, or it came in as one).
    resend: bool,
    /// An attempt was written, or may have been: it may be on the Mac.
    written_once: bool,
    attempts: u32,
    /// Failures in a row since the last write that took.
    failures: u32,
    not_before: Option<Instant>,
}

impl Entry {
    fn uploaded(&self) -> bool {
        self.slots.iter().all(|s| matches!(s.attachment.state, UploadState::Uploaded { .. }))
    }

    fn may_be_on_mac(&self) -> bool {
        self.written_once || self.state == State::Writing || self.state == State::Written
    }

    fn attachments(&self) -> Vec<Attachment> {
        self.slots.iter().map(|s| s.attachment.clone()).collect()
    }

    fn done(self, outcome: PromptOutcome) -> PromptDone {
        let attachments = self.attachments();
        PromptDone { id: self.id, outcome, text: self.text, attachments }
    }

    fn slots_for(ids: Vec<String>, keep: &[Slot]) -> Vec<Slot> {
        ids.into_iter()
            .map(|id| {
                keep.iter().find(|s| s.attachment.id == id).cloned().unwrap_or(Slot {
                    attachment: Attachment { id, state: UploadState::Pending },
                    failures: 0,
                    not_before: None,
                })
            })
            .collect()
    }
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

    /// The link's state at `now`. Coming back, every queued prompt and upload may go at once, in
    /// order (no backoff wait for a link that is new). Going down, uploads under way start over
    /// on the next link, and a prompt still uploading (and every one behind it) begins to wait
    /// for the link now.
    pub fn set_link(&mut self, up: bool, now: Instant) {
        if up && !self.link_up {
            for entry in &mut self.entries {
                entry.not_before = None;
                for slot in &mut entry.slots {
                    slot.not_before = None;
                }
            }
        }
        if !up && self.link_up {
            let mut behind_upload = false;
            for entry in &mut self.entries {
                for slot in &mut entry.slots {
                    if matches!(slot.attachment.state, UploadState::Uploading { .. }) {
                        slot.attachment.state = UploadState::Pending;
                    }
                }
                if entry.state == State::Queued {
                    behind_upload |= !entry.uploaded();
                    if behind_upload && entry.waiting_since < now {
                        entry.waiting_since = now;
                    }
                }
            }
        }
        self.link_up = up;
    }

    /// A tap on Send: `id` is its `promptId`, `attachments` the owner's ids for its attachments
    /// (each to upload), `resend` the intent's own flag. `tapped` places it among the others; it
    /// waits from `tapped` when it can go at once, else from `now`. Never waits for anything.
    /// False when a prompt with this id is already here (a second push is never a second send).
    pub fn push(
        &mut self,
        id: impl Into<String>,
        text: impl Into<String>,
        attachments: Vec<String>,
        resend: bool,
        tapped: Instant,
        now: Instant,
    ) -> bool {
        let id = id.into();
        if self.entries.iter().any(|e| e.id == id) {
            return false;
        }
        self.failed.retain(|f| *f != id);
        let slots = Entry::slots_for(attachments, &[]);
        let waits = !self.link_up
            || !slots.is_empty()
            || self.entries.iter().any(|e| matches!(e.state, State::Queued | State::Writing));
        let entry = Entry {
            id,
            text: text.into(),
            slots,
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

    /// The next upload to start, in tap order, while fewer than [`MAX_UPLOADS`] are under way and
    /// the link is up.
    pub fn next_upload(&mut self, now: Instant) -> Option<UploadRequest> {
        if !self.link_up {
            return None;
        }
        let uploading = self
            .entries
            .iter()
            .flat_map(|e| &e.slots)
            .filter(|s| matches!(s.attachment.state, UploadState::Uploading { .. }))
            .count();
        if uploading >= MAX_UPLOADS {
            return None;
        }
        for entry in self.entries.iter_mut().filter(|e| e.state == State::Queued) {
            for slot in &mut entry.slots {
                let ready = matches!(
                    slot.attachment.state,
                    UploadState::Pending | UploadState::Failed { .. }
                ) && slot.not_before.is_none_or(|at| now >= at);
                if ready {
                    slot.attachment.state = UploadState::Uploading { sent: 0, total: 0 };
                    slot.not_before = None;
                    return Some(UploadRequest {
                        prompt: entry.id.clone(),
                        attachment: slot.attachment.id.clone(),
                    });
                }
            }
        }
        None
    }

    /// An upload's progress.
    pub fn upload_progress(&mut self, prompt: &str, attachment: &str, sent: u64, total: u64) {
        if let Some(slot) = self.slot_mut(prompt, attachment)
            && matches!(slot.attachment.state, UploadState::Uploading { .. } | UploadState::Pending)
        {
            slot.attachment.state = UploadState::Uploading { sent, total };
        }
    }

    /// An upload finished: the attachment is at `mac_path` on the Mac. When it was the prompt's
    /// last, the prompt (and every one queued behind it) begins to wait for the link now.
    pub fn uploaded(
        &mut self,
        prompt: &str,
        attachment: &str,
        mac_path: impl Into<String>,
        now: Instant,
    ) {
        let Some(slot) = self.slot_mut(prompt, attachment) else { return };
        slot.attachment.state = UploadState::Uploaded { mac_path: mac_path.into() };
        slot.failures = 0;
        let Some(index) = self.entries.iter().position(|e| e.id == prompt) else { return };
        if !self.entries[index].uploaded() {
            return;
        }
        for entry in self.entries.iter_mut().skip(index).filter(|e| e.state == State::Queued) {
            if entry.waiting_since < now {
                entry.waiting_since = now;
            }
        }
    }

    /// An upload failed with `reason`. It goes again after a backoff; the [`UPLOAD_ATTEMPTS`]th
    /// failure gives the prompt up ([`PromptOutcome::UploadFailed`], nothing written).
    pub fn upload_failed(
        &mut self,
        prompt: &str,
        attachment: &str,
        reason: impl Into<String>,
        now: Instant,
    ) -> Option<PromptDone> {
        let reason = reason.into();
        let unit = self.next_unit();
        let slot = self.slot_mut(prompt, attachment)?;
        if matches!(slot.attachment.state, UploadState::Uploaded { .. }) {
            return None;
        }
        slot.failures = slot.failures.saturating_add(1);
        slot.attachment.state = UploadState::Failed { reason: reason.clone() };
        if slot.failures < UPLOAD_ATTEMPTS {
            slot.not_before = Some(now + retry_delay(slot.failures, unit));
            return None;
        }
        let index = self.entries.iter().position(|e| e.id == prompt)?;
        let entry = self.entries.remove(index)?;
        self.remember_failed(entry.id.clone());
        Some(entry.done(PromptOutcome::UploadFailed { reason }))
    }

    /// The next prompt to write: the first unwritten one, when the link is up, nothing else is
    /// being written, its uploads are done, its retry wait is over and it is within the hold (one
    /// past it is for [`expire`](Self::expire), never sent behind the person's back).
    pub fn next_request(&mut self, now: Instant) -> Option<PromptRequest> {
        if !self.link_up || self.entries.iter().any(|e| e.state == State::Writing) {
            return None;
        }
        let hold = self.hold;
        let entry = self.entries.iter_mut().find(|e| e.state == State::Queued)?;
        if !entry.uploaded()
            || entry.not_before.is_some_and(|at| now < at)
            || now.saturating_duration_since(entry.waiting_since) >= hold
        {
            return None;
        }
        entry.state = State::Writing;
        entry.attempts = entry.attempts.saturating_add(1);
        entry.not_before = None;
        let attachments = entry
            .slots
            .iter()
            .filter_map(|s| match &s.attachment.state {
                UploadState::Uploaded { mac_path } => {
                    Some((s.attachment.id.clone(), mac_path.clone()))
                }
                _ => None,
            })
            .collect();
        Some(PromptRequest {
            id: entry.id.clone(),
            resend: entry.resend,
            attempt: entry.attempts,
            attachments,
        })
    }

    /// The prompt's write took: its answer is awaited. From now on every attempt is a resend.
    pub fn wrote(&mut self, id: &str) {
        if let Some(entry) = self.entry_mut(id) {
            entry.resend = true;
            entry.written_once = true;
            entry.failures = 0;
            if entry.state == State::Writing {
                entry.state = State::Written;
            }
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
        if let Some(entry) = self.entry_mut(id) {
            entry.resend = true;
            entry.written_once = true;
        }
        self.requeue(id, now, true);
    }

    fn requeue(&mut self, id: &str, now: Instant, from_now: bool) {
        let unit = self.next_unit();
        let Some(entry) = self.entry_mut(id) else { return };
        if entry.state == State::Cancelling {
            return;
        }
        entry.state = State::Queued;
        if from_now {
            entry.waiting_since = now;
        }
        entry.failures = entry.failures.saturating_add(1);
        entry.not_before = Some(now + retry_delay(entry.failures, unit));
    }

    /// The Mac answered the prompt (its turn ended, or `{duplicate:true}`): sent, even one the
    /// person cancelled too late.
    pub fn answered(&mut self, id: &str) -> Option<PromptDone> {
        let index = self.entries.iter().position(|e| e.id == id)?;
        let entry = self.entries.remove(index)?;
        Some(entry.done(PromptOutcome::Sent))
    }

    /// The Mac refused the prompt (an error answer: nothing ran). Its text goes back.
    pub fn refused(&mut self, id: &str) -> Option<PromptDone> {
        let index = self.entries.iter().position(|e| e.id == id)?;
        let entry = self.entries.remove(index)?;
        self.remember_failed(entry.id.clone());
        Some(entry.done(PromptOutcome::Refused))
    }

    /// The person cancels the prompt `id`, at any point. One that never left comes back at once
    /// ([`CancelStep::Returned`]), its uploads moot; one that may be on the Mac is never sent
    /// again and is to be taken off the Mac's queue ([`CancelStep::RemoveOnMac`]).
    pub fn cancel(&mut self, id: &str) -> Option<CancelStep> {
        let index = self.entries.iter().position(|e| e.id == id)?;
        if self.entries[index].may_be_on_mac() {
            let entry = &mut self.entries[index];
            entry.state = State::Cancelling;
            return Some(CancelStep::RemoveOnMac { id: entry.id.clone() });
        }
        let entry = self.entries.remove(index)?;
        Some(CancelStep::Returned(entry.done(PromptOutcome::Cancelled)))
    }

    /// The Mac's answer to `_acpmux/queue_remove` for a cancelled prompt: `removed` it from its
    /// queue ([`PromptOutcome::Cancelled`]), or could not (it ran or is running:
    /// [`PromptOutcome::MaybeSent`]).
    pub fn remove_answered(&mut self, id: &str, removed: bool) -> Option<PromptDone> {
        let index = self.entries.iter().position(|e| e.id == id && e.state == State::Cancelling)?;
        let entry = self.entries.remove(index)?;
        Some(entry.done(if removed { PromptOutcome::Cancelled } else { PromptOutcome::MaybeSent }))
    }

    /// Delete: a cancel whose text the owner does not hand back, and its failed look forgotten
    /// (also for one already given up).
    pub fn delete(&mut self, id: &str) -> Option<CancelStep> {
        self.forget(id);
        self.cancel(id)
    }

    /// The person edits the prompt `id`: new `text` and `attachments` (ids; ones it had keep
    /// their uploads, new ones upload). One that never left is edited in place
    /// ([`EditStep::Edited`]); one that may be on the Mac is cancelled there and the edit goes as
    /// the new prompt `new_id` in its place ([`EditStep::Replaced`]). `None` when `id` is not
    /// here.
    pub fn edit(
        &mut self,
        id: &str,
        new_id: impl Into<String>,
        text: impl Into<String>,
        attachments: Vec<String>,
        now: Instant,
    ) -> Option<EditStep> {
        let index = self.entries.iter().position(|e| e.id == id)?;
        let text = text.into();
        if !self.entries[index].may_be_on_mac() {
            let entry = &mut self.entries[index];
            entry.slots = Entry::slots_for(attachments, &entry.slots);
            entry.text = text;
            entry.waiting_since = now;
            entry.not_before = None;
            entry.failures = 0;
            return Some(EditStep::Edited);
        }
        let new_id = new_id.into();
        if new_id == id || self.entries.iter().any(|e| e.id == new_id) {
            return None;
        }
        let old = &mut self.entries[index];
        old.state = State::Cancelling;
        let replacement = Entry {
            id: new_id,
            text,
            slots: Entry::slots_for(attachments, &old.slots),
            tapped: old.tapped,
            waiting_since: now,
            state: State::Queued,
            resend: false,
            written_once: false,
            attempts: 0,
            failures: 0,
            not_before: None,
        };
        self.entries.insert(index + 1, replacement);
        Some(EditStep::Replaced { remove: id.to_owned() })
    }

    /// The person asks it to go now: its retry wait ends, its hold starts over, a failed upload
    /// goes again. False when `id` is not an unwritten prompt here.
    pub fn retry_now(&mut self, id: &str, now: Instant) -> bool {
        let Some(entry) = self.entry_mut(id) else { return false };
        if entry.state != State::Queued {
            return false;
        }
        entry.not_before = None;
        entry.failures = 0;
        entry.waiting_since = now;
        for slot in &mut entry.slots {
            slot.not_before = None;
            if matches!(slot.attachment.state, UploadState::Failed { .. }) {
                slot.attachment.state = UploadState::Pending;
                slot.failures = 0;
            }
        }
        true
    }

    /// Unwritten prompts past the hold: when any is, every unwritten one comes back, in tap
    /// order (none goes after an earlier one that did not). One being written waits for its
    /// write; written ones wait for their answers. While the link is up a prompt still uploading
    /// (and every one behind it) is not waiting for the link, so it is not due.
    pub fn expire(&mut self, now: Instant) -> Vec<PromptDone> {
        let hold = self.hold;
        let link_up = self.link_up;
        let mut due = false;
        for entry in self.entries.iter().filter(|e| e.state == State::Queued) {
            if link_up && !entry.uploaded() {
                break;
            }
            if now.saturating_duration_since(entry.waiting_since) >= hold {
                due = true;
                break;
            }
        }
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

    /// Every unwritten prompt that never left, out of this outbox now (the chat's next source
    /// takes them over), in tap order with when each was tapped.
    pub fn drain_unwritten(&mut self) -> Vec<(String, Instant)> {
        let mut out = Vec::new();
        self.entries.retain(|e| {
            if e.state == State::Queued && !e.written_once {
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
                    PromptOutcome::MaybeSent
                } else {
                    PromptOutcome::NotSent
                };
                done.push(entry.done(outcome));
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

    /// How the prompt `id` looks at `now`. One this outbox does not hold (answered, cancelled, or
    /// never here) looks sent.
    pub fn look(&self, id: &str, now: Instant) -> PromptLook {
        if let Some(entry) = self.entries.iter().find(|e| e.id == id) {
            let upload_retrying = entry.slots.iter().any(|s| s.failures > 0);
            let waiting = matches!(entry.state, State::Queued | State::Writing)
                && entry.uploaded()
                && now.saturating_duration_since(entry.waiting_since) >= RETRYING_AFTER;
            return if upload_retrying || waiting {
                PromptLook::Retrying
            } else {
                PromptLook::Sent
            };
        }
        if self.failed.iter().any(|f| f == id) { PromptLook::Failed } else { PromptLook::Sent }
    }

    /// The prompt's attachments and their uploads (for a progress ring), or `None`.
    pub fn attachments(&self, id: &str) -> Option<Vec<Attachment>> {
        self.entries.iter().find(|e| e.id == id).map(Entry::attachments)
    }

    /// Forgets a failed prompt's look (the person dismissed it or sent it again).
    pub fn forget(&mut self, id: &str) {
        self.failed.retain(|f| f != id);
    }

    /// When something is next due: an unwritten prompt's hold, or (link up) the first one's retry
    /// or an upload's retry. `None` when nothing waits.
    pub fn next_wake(&self, now: Instant) -> Option<Duration> {
        let mut wake: Option<Instant> = None;
        let mut first_queued = true;
        let mut earlier = |at: Instant| wake = Some(wake.map_or(at, |w: Instant| w.min(at)));
        for entry in self.entries.iter().filter(|e| e.state == State::Queued) {
            if !self.link_up || entry.uploaded() {
                earlier(entry.waiting_since + self.hold);
            }
            if self.link_up {
                if first_queued && let Some(retry) = entry.not_before {
                    earlier(retry);
                }
                for retry in entry.slots.iter().filter_map(|s| s.not_before) {
                    earlier(retry);
                }
            }
            first_queued = false;
        }
        wake.map(|at| at.saturating_duration_since(now))
    }

    /// When the next prompt turns [`PromptLook::Retrying`] (for the chat's redraw).
    pub fn next_look_change(&self, now: Instant) -> Option<Duration> {
        self.entries
            .iter()
            .filter(|e| matches!(e.state, State::Queued | State::Writing) && e.uploaded())
            .map(|e| e.waiting_since + RETRYING_AFTER)
            .filter(|at| *at > now)
            .min()
            .map(|at| at.saturating_duration_since(now))
    }

    /// The unwritten prompts' ids (queued, uploading or backing off), in tap order.
    pub fn unwritten(&self) -> Vec<String> {
        self.entries.iter().filter(|e| e.state == State::Queued).map(|e| e.id.clone()).collect()
    }

    /// Prompts not ended yet.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn entry_mut(&mut self, id: &str) -> Option<&mut Entry> {
        self.entries.iter_mut().find(|e| e.id == id)
    }

    fn slot_mut(&mut self, prompt: &str, attachment: &str) -> Option<&mut Slot> {
        self.entry_mut(prompt)?.slots.iter_mut().find(|s| s.attachment.id == attachment)
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
