//! The phone composer's Send: the draft and its Return as one `send` with an id.
//!
//! Leo, 2026-11-23: "if it wasn't connected properly in time, the send doesn't go through,
//! right? Like because like the text goes through. But then the send doesn't go through."
//!
//! An [`Outbox`] holds each Send from the tap until the Mac answers it:
//!
//! - **One request.** The text and its Return go in one `send` (`paste` plus `submit` on a
//!   daemon that lists `send-expect-agent-v1`, else the text and `\r` in one write), never as
//!   two writes a link drop can split.
//! - **One key, for life.** The request carries a key made at the tap. Every attempt, on any
//!   channel, after any reconnect, carries the same key. The daemon applies a key once
//!   (daemon-wide, for [`DAEMON_KEY_TTL`]): a resend of a Send whose answer was lost writes
//!   nothing, so it can be sent again as often as the link needs.
//! - **Kept across a reconnect.** A Send whose answer did not come is not dropped: it goes again
//!   under its key once the terminal is back, until [`Outbox::hold`] after the tap.
//! - **Pipelined, in tap order.** Up to [`MAX_IN_FLIGHT`] Sends go unanswered at once on one
//!   channel, so a slow link keeps up with the person's taps; a loss sends them all again, in
//!   order, under their keys.
//! - **Honest when it gives up.** Past the hold, a Send that never left is [`Outcome::NotSent`]
//!   (its text may come back to the composer); one that may have reached the Mac is
//!   [`Outcome::MaybeSent`], whose text must not come back as unsent, or the person sends it
//!   twice.
//!
//! The outbox does no I/O. Its owner (the phone's terminal session) asks for the next request,
//! sends it and reports the answer.
//!
//! [`chat::PromptOutbox`] is its twin for the agent chat's prompts (keyed by `promptId`).

pub mod chat;
pub mod progress;

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};

/// How long the daemon remembers a key it applied (`send_once::TTL` in cmux-tui-core). A hold
/// must stay below it, or a resend after the daemon forgot the key could be applied twice.
pub const DAEMON_KEY_TTL: Duration = Duration::from_secs(600);

/// The longest key the daemon takes (`send_once::MAX_KEY_LEN`).
pub const MAX_KEY_LEN: usize = 128;

/// How long a Send waits for the terminal (the composer's own window for a held send,
/// `TerminalModel.heldComposerSendWindow`). Past it the Send is given up: a command must not run
/// whenever the Mac comes back (termfix-r13 D5).
pub const DEFAULT_HOLD: Duration = Duration::from_secs(30);

/// Sends unanswered at once, in tap order on one channel. One at a time cannot keep up with a
/// person tapping faster than the link's round trip (a 1 s link delivered fewer Sends than were
/// tapped, and the rest ran out of hold); the daemon applies a channel's requests in order and
/// each key once, so a pipeline sent again after a loss types nothing twice.
pub const MAX_IN_FLIGHT: usize = 16;

/// How the daemon takes a keyed Send, from its `identify` capabilities ([`Form::from_caps`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Form {
    /// `send-expect-agent-v1` and `send-key-v1`: `{text, paste:true, submit:true, key}`. The
    /// daemon brackets the text by the terminal's own paste mode and writes Return after it.
    PasteSubmit,
    /// [`Form::PasteSubmit`] plus `send-typed-submit-v1`: a typed Send ([`Outbox::push_typed`])
    /// goes as `{text, submit:true, key}` with no `paste`, and the daemon writes Return a
    /// paste-burst window after the typed text, in the same request.
    TypedSubmit,
    /// `send-key-v1` only: `{text: text + "\r", key}`, one write.
    TextReturn,
}

impl Form {
    /// The form a daemon with these capabilities takes; `None` when it takes no keys (a resend
    /// there could type the text twice, so the outbox does not serve it).
    pub fn from_caps<'a>(caps: impl IntoIterator<Item = &'a str>) -> Option<Form> {
        let (mut key, mut submit, mut typed) = (false, false, false);
        for cap in caps {
            key |= cap == "send-key-v1";
            submit |= cap == "send-expect-agent-v1";
            typed |= cap == "send-typed-submit-v1";
        }
        match (key, submit) {
            (true, true) if typed => Some(Form::TypedSubmit),
            (true, true) => Some(Form::PasteSubmit),
            (true, false) => Some(Form::TextReturn),
            _ => None,
        }
    }
}

/// What came of one attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Answer {
    /// The daemon answered success: applied now, or earlier under the same key.
    Applied,
    /// The daemon refused it and says nothing was written (a refused check, a bad request).
    Refused,
    /// No answer: the channel failed or timed out after the request may have been written.
    Lost,
    /// The daemon answered an error that does not say nothing was written (its
    /// `error_delivery` is not `known-not-delivered`: the text went in and its Return failed,
    /// say). The key stays applied there, so a resend would write nothing and read as sent:
    /// it ends as [`Outcome::MaybeSent`] at once.
    Uncertain,
}

/// How a Send ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The Mac has it, typed once.
    Sent,
    /// The Mac never got it: the text may go back to the composer.
    NotSent { text: String },
    /// It may have reached the Mac (an attempt went out and its answer never came), and the hold
    /// ran out: the screen says it may have been sent, and the text does not come back as unsent.
    MaybeSent { text: String },
}

/// One Send that ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Done {
    pub seq: u64,
    pub outcome: Outcome,
}

#[derive(Debug, Clone)]
struct Entry {
    seq: u64,
    key: String,
    /// What goes: the draft (with its Return when `submit`) or raw keys (`keys`).
    text: String,
    submit: bool,
    /// Raw terminal bytes (`push_keys`), sent as `{bytes, key}`; `text` then holds them lossily,
    /// for the outcome only.
    keys: Option<Vec<u8>>,
    /// Typed, not pasted (a one-line draft for a full-screen program: vim takes a bracketed
    /// paste as text even in normal mode).
    typed: bool,
    queued: Instant,
    /// An attempt went out: the Mac may have it.
    tried: bool,
    in_flight: bool,
}

/// The phone composer's Sends that the Mac has not answered yet, in tap order.
#[derive(Debug, Clone)]
pub struct Outbox {
    nonce: String,
    next_seq: u64,
    hold: Duration,
    entries: VecDeque<Entry>,
}

impl Outbox {
    /// `nonce`: unique to this outbox across the daemon's key memory (the phone's install and
    /// terminal session, say), so two outboxes never share a key. `hold` is capped below
    /// [`DAEMON_KEY_TTL`].
    pub fn new(nonce: impl Into<String>, hold: Duration) -> Outbox {
        let mut nonce: String = nonce.into();
        // Room for "-" and a u64 within the daemon's limit.
        nonce.truncate(MAX_KEY_LEN.saturating_sub(21));
        Outbox {
            nonce,
            next_seq: 1,
            hold: hold.min(Duration::from_secs(DAEMON_KEY_TTL.as_secs() / 2)),
            entries: VecDeque::new(),
        }
    }

    pub fn hold(&self) -> Duration {
        self.hold
    }

    /// A tap on Send: `text` and, with `submit`, its Return. Returns the Send's number.
    pub fn push(&mut self, text: impl Into<String>, submit: bool, now: Instant) -> u64 {
        self.push_entry(text.into(), submit, false, now)
    }

    /// A tap on Send of a one-line draft for a full-screen program: `text` typed, then Return,
    /// in one request ([`Form::TypedSubmit`]). A daemon without `send-typed-submit-v1` (one
    /// attached after the tap) gets it as a paste with Return, still one request.
    pub fn push_typed(&mut self, text: impl Into<String>, now: Instant) -> u64 {
        self.push_entry(text.into(), true, true, now)
    }

    fn push_entry(&mut self, text: String, submit: bool, typed: bool, now: Instant) -> u64 {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.saturating_add(1);
        self.entries.push_back(Entry {
            seq,
            key: format!("{}-{seq}", self.nonce),
            text,
            submit,
            keys: None,
            typed,
            queued: now,
            tried: false,
            in_flight: false,
        });
        seq
    }

    /// Typed keys: raw terminal `bytes` as one keyed `send {bytes, key}`, in the same queue, so
    /// order holds across keys and composer Sends. The same hold, resend-under-the-key and
    /// outcome rules apply; an outcome's `text` is the bytes read lossily as UTF-8 (the caller
    /// knows by `seq` that it was keys). Returns the entry's number.
    pub fn push_keys(&mut self, bytes: impl Into<Vec<u8>>, now: Instant) -> u64 {
        let bytes: Vec<u8> = bytes.into();
        let seq = self.push(String::from_utf8_lossy(&bytes).into_owned(), false, now);
        if let Some(entry) = self.entries.back_mut() {
            entry.keys = Some(bytes);
        }
        seq
    }

    /// The next Send to go out, in tap order behind the ones in flight, while fewer than
    /// [`MAX_IN_FLIGHT`] are unanswered: its seq and `send` params without `surface`.
    pub fn next_request(&mut self, form: Form) -> Option<(u64, Value)> {
        if self.entries.iter().filter(|e| e.in_flight).count() >= MAX_IN_FLIGHT {
            return None;
        }
        let entry = self.entries.iter_mut().find(|e| !e.in_flight)?;
        entry.in_flight = true;
        entry.tried = true;
        if let Some(keys) = &entry.keys {
            let params = json!({"bytes": STANDARD.encode(keys), "key": entry.key});
            return Some((entry.seq, params));
        }
        let params = match (form, entry.submit) {
            (Form::TypedSubmit, true) if entry.typed => {
                json!({"text": entry.text, "submit": true, "key": entry.key})
            }
            (Form::PasteSubmit | Form::TypedSubmit, submit) => {
                json!({"text": entry.text, "paste": true, "submit": submit, "key": entry.key})
            }
            (Form::TextReturn, true) => {
                json!({"text": format!("{}\r", entry.text), "key": entry.key})
            }
            (Form::TextReturn, false) => json!({"text": entry.text, "key": entry.key}),
        };
        Some((entry.seq, params))
    }

    /// The answer to an attempt at `seq`. A lost one sends every unanswered Send again, in tap
    /// order under its key (one behind it may have been typed already; its key makes the repeat
    /// write nothing). An answer that comes after that still settles the Send.
    pub fn answer(&mut self, seq: u64, answer: Answer) -> Option<Done> {
        let index = self.entries.iter().position(|e| e.seq == seq && e.tried)?;
        let entry = self.entries.get(index)?;
        let outcome = match answer {
            Answer::Applied => Outcome::Sent,
            // Nothing written: the text goes back.
            Answer::Refused => Outcome::NotSent { text: entry.text.clone() },
            Answer::Uncertain => Outcome::MaybeSent { text: entry.text.clone() },
            Answer::Lost => {
                if entry.in_flight {
                    self.link_lost();
                }
                return None;
            }
        };
        self.entries.remove(index);
        Some(Done { seq, outcome })
    }

    /// The channel dropped: the attempt in flight has no answer coming, and goes again under its
    /// key on the next channel.
    pub fn link_lost(&mut self) {
        for entry in &mut self.entries {
            entry.in_flight = false;
        }
    }

    /// Sends older than the hold, given up (in tap order). One in flight waits for its answer.
    pub fn expire(&mut self, now: Instant) -> Vec<Done> {
        let mut done = Vec::new();
        while self.entries.front().is_some_and(|entry| {
            !entry.in_flight && now.saturating_duration_since(entry.queued) >= self.hold
        }) {
            let Some(entry) = self.entries.pop_front() else { break };
            let outcome = if entry.tried {
                Outcome::MaybeSent { text: entry.text }
            } else {
                Outcome::NotSent { text: entry.text }
            };
            done.push(Done { seq: entry.seq, outcome });
        }
        done
    }

    /// One Send, given up now (its owner dropped it: keys before it were lost, say), if it is
    /// not in flight: [`Outcome::MaybeSent`] when an attempt went out, else [`Outcome::NotSent`].
    pub fn give_up_send(&mut self, seq: u64) -> Option<Done> {
        let index = self.entries.iter().position(|e| e.seq == seq && !e.in_flight)?;
        let entry = self.entries.remove(index)?;
        let outcome = if entry.tried {
            Outcome::MaybeSent { text: entry.text }
        } else {
            Outcome::NotSent { text: entry.text }
        };
        Some(Done { seq, outcome })
    }

    /// Every Send, given up now (the attached daemon takes no keys, so none may go): in tap
    /// order, [`Outcome::MaybeSent`] for one an attempt went out for, else
    /// [`Outcome::NotSent`].
    pub fn give_up(&mut self) -> Vec<Done> {
        self.entries
            .drain(..)
            .map(|entry| Done {
                seq: entry.seq,
                outcome: if entry.tried {
                    Outcome::MaybeSent { text: entry.text }
                } else {
                    Outcome::NotSent { text: entry.text }
                },
            })
            .collect()
    }

    /// Sends not answered yet.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// When the oldest Send runs out of hold (for a timer).
    pub fn next_deadline(&self) -> Option<Instant> {
        self.entries.front().and_then(|e| e.queued.checked_add(self.hold))
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
