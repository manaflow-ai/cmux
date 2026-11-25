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
mod tests {
    use super::*;

    fn key(params: &Value) -> &str {
        params["key"].as_str().unwrap()
    }

    #[test]
    fn text_and_return_go_in_one_request() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        let now = Instant::now();
        outbox.push("ls -la", true, now);
        let (_, params) = outbox.next_request(Form::PasteSubmit).unwrap();
        assert_eq!(params["text"], "ls -la");
        assert_eq!(params["paste"], true);
        assert_eq!(params["submit"], true);

        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        outbox.push("ls -la", true, now);
        let (_, params) = outbox.next_request(Form::TextReturn).unwrap();
        assert_eq!(params["text"], "ls -la\r");
        assert!(params.get("submit").is_none());
    }

    #[test]
    fn a_lost_answer_goes_again_under_the_same_key() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        let now = Instant::now();
        let seq = outbox.push("make", true, now);
        let (_, first) = outbox.next_request(Form::PasteSubmit).unwrap();
        assert_eq!(outbox.answer(seq, Answer::Lost), None);
        let (_, second) = outbox.next_request(Form::PasteSubmit).unwrap();
        outbox.link_lost();
        let (_, third) = outbox.next_request(Form::PasteSubmit).unwrap();
        assert_eq!(key(&first), key(&second));
        assert_eq!(key(&first), key(&third));
        assert_eq!(outbox.answer(seq, Answer::Applied), Some(Done { seq, outcome: Outcome::Sent }));
        assert!(outbox.is_empty());
    }

    #[test]
    fn sends_pipeline_in_tap_order_up_to_the_window() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        let now = Instant::now();
        let seqs: Vec<u64> =
            (0..MAX_IN_FLIGHT + 1).map(|i| outbox.push(format!("m{i}"), true, now)).collect();
        let sent: Vec<u64> =
            std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit).map(|(seq, _)| seq))
                .collect();
        assert_eq!(sent, seqs[..MAX_IN_FLIGHT], "in tap order, a window at a time");
        outbox.answer(seqs[0], Answer::Applied);
        let (next, params) = outbox.next_request(Form::PasteSubmit).unwrap();
        assert_eq!(next, seqs[MAX_IN_FLIGHT]);
        assert_eq!(key(&params), format!("phone-{next}"));
    }

    #[test]
    fn a_lost_answer_sends_the_whole_pipeline_again_in_order_and_late_answers_still_settle() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        let now = Instant::now();
        let a = outbox.push("a", true, now);
        let b = outbox.push("b", true, now);
        let first: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit)).collect();
        assert_eq!(outbox.answer(a, Answer::Lost), None);
        let again: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit)).collect();
        assert_eq!(first, again, "the same requests, same keys, same order");
        assert_eq!(
            outbox.answer(b, Answer::Applied),
            Some(Done { seq: b, outcome: Outcome::Sent })
        );
        assert_eq!(
            outbox.answer(a, Answer::Applied),
            Some(Done { seq: a, outcome: Outcome::Sent })
        );
        assert!(outbox.is_empty());
    }

    #[test]
    fn past_the_hold_a_tried_send_may_have_been_sent_and_an_untried_one_was_not() {
        let mut outbox = Outbox::new("phone", Duration::from_secs(10));
        let now = Instant::now();
        let tried = outbox.push("tried", true, now);
        let untried = outbox.push("untried", true, now);
        outbox.next_request(Form::PasteSubmit);
        outbox.link_lost();
        assert!(outbox.expire(now + Duration::from_secs(9)).is_empty());
        let done = outbox.expire(now + Duration::from_secs(10));
        assert_eq!(
            done,
            vec![
                Done { seq: tried, outcome: Outcome::MaybeSent { text: "tried".into() } },
                Done { seq: untried, outcome: Outcome::NotSent { text: "untried".into() } },
            ]
        );
    }

    #[test]
    fn an_uncertain_error_is_maybe_sent_and_never_resent() {
        let t0 = Instant::now();
        let mut outbox = Outbox::new("n", DEFAULT_HOLD);
        let seq = outbox.push("make deploy", true, t0);
        outbox.next_request(Form::PasteSubmit).unwrap();
        assert_eq!(
            outbox.answer(seq, Answer::Uncertain),
            Some(Done { seq, outcome: Outcome::MaybeSent { text: "make deploy".into() } })
        );
        assert!(outbox.next_request(Form::PasteSubmit).is_none());
    }

    #[test]
    fn giving_up_says_which_sends_may_have_left() {
        let t0 = Instant::now();
        let mut outbox = Outbox::new("n", DEFAULT_HOLD);
        let tried = outbox.push("a", true, t0);
        let untried = outbox.push("b", true, t0);
        outbox.next_request(Form::PasteSubmit).unwrap();
        outbox.link_lost();
        assert_eq!(
            outbox.give_up(),
            vec![
                Done { seq: tried, outcome: Outcome::MaybeSent { text: "a".into() } },
                Done { seq: untried, outcome: Outcome::NotSent { text: "b".into() } },
            ]
        );
        assert!(outbox.is_empty());
    }

    #[test]
    fn one_send_given_up_says_whether_it_may_have_left() {
        let t0 = Instant::now();
        let mut outbox = Outbox::new("n", DEFAULT_HOLD);
        let a = outbox.push("a", true, t0);
        let b = outbox.push("b", true, t0);
        outbox.next_request(Form::PasteSubmit).unwrap();
        assert_eq!(outbox.give_up_send(a), None, "in flight: its answer decides");
        assert_eq!(
            outbox.give_up_send(b),
            Some(Done { seq: b, outcome: Outcome::NotSent { text: "b".into() } })
        );
        outbox.answer(a, Answer::Lost);
        assert_eq!(
            outbox.give_up_send(a),
            Some(Done { seq: a, outcome: Outcome::MaybeSent { text: "a".into() } })
        );
        assert!(outbox.is_empty());
    }

    #[test]
    fn typed_keys_go_as_bytes_under_a_key_in_order_with_composer_sends() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        let now = Instant::now();
        let a = outbox.push_keys(b"\x1b[A".to_vec(), now);
        let b = outbox.push("ls", true, now);
        let c = outbox.push_keys(b"y".to_vec(), now);
        let sent: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::TextReturn)).collect();
        assert_eq!(sent.iter().map(|(s, _)| *s).collect::<Vec<_>>(), vec![a, b, c]);
        assert_eq!(sent[0].1["bytes"], STANDARD.encode(b"\x1b[A"));
        assert!(sent[0].1.get("text").is_none());
        assert_eq!(sent[1].1["text"], "ls\r");
        assert_eq!(sent[2].1["bytes"], STANDARD.encode(b"y"));
    }

    #[test]
    fn keys_held_across_a_lost_link_go_again_in_order_under_the_same_keys_once_answered() {
        let mut outbox = Outbox::new("phone", Duration::from_secs(10));
        let now = Instant::now();
        let a = outbox.push_keys(b"a".to_vec(), now);
        let b = outbox.push_keys(b"b".to_vec(), now);
        let first: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit)).collect();
        outbox.link_lost();
        assert!(outbox.expire(now + Duration::from_secs(5)).is_empty());
        let again: Vec<_> = std::iter::from_fn(|| outbox.next_request(Form::PasteSubmit)).collect();
        assert_eq!(first, again, "same bytes, same keys, same order: the daemon applies each once");
        assert_eq!(key(&again[0].1), format!("phone-{a}"));
        assert_eq!(
            outbox.answer(a, Answer::Applied),
            Some(Done { seq: a, outcome: Outcome::Sent })
        );
        assert_eq!(
            outbox.answer(b, Answer::Applied),
            Some(Done { seq: b, outcome: Outcome::Sent })
        );
        assert!(outbox.is_empty());
    }

    #[test]
    fn keys_past_the_hold_are_not_sent_or_maybe_sent_never_dropped() {
        let mut outbox = Outbox::new("phone", Duration::from_secs(10));
        let now = Instant::now();
        let tried = outbox.push_keys(b"x".to_vec(), now);
        let untried = outbox.push_keys(b"z".to_vec(), now);
        outbox.next_request(Form::PasteSubmit);
        outbox.link_lost();
        assert_eq!(
            outbox.expire(now + Duration::from_secs(10)),
            vec![
                Done { seq: tried, outcome: Outcome::MaybeSent { text: "x".into() } },
                Done { seq: untried, outcome: Outcome::NotSent { text: "z".into() } },
            ]
        );
        assert!(outbox.is_empty());
    }

    #[test]
    fn a_refused_key_is_not_sent_and_not_resent() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        let seq = outbox.push_keys(b"y".to_vec(), Instant::now());
        outbox.next_request(Form::PasteSubmit);
        assert_eq!(
            outbox.answer(seq, Answer::Refused),
            Some(Done { seq, outcome: Outcome::NotSent { text: "y".into() } })
        );
        assert!(outbox.next_request(Form::PasteSubmit).is_none());
    }

    #[test]
    fn a_refusal_gives_the_text_back() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        let seq = outbox.push("y", true, Instant::now());
        outbox.next_request(Form::PasteSubmit);
        assert_eq!(
            outbox.answer(seq, Answer::Refused),
            Some(Done { seq, outcome: Outcome::NotSent { text: "y".into() } })
        );
    }

    #[test]
    fn the_hold_stays_below_the_daemons_key_memory_and_keys_fit() {
        let outbox = Outbox::new("x".repeat(500), Duration::from_secs(3600));
        assert!(outbox.hold() < DAEMON_KEY_TTL);
        let mut outbox = outbox;
        outbox.push("t", true, Instant::now());
        let (_, params) = outbox.next_request(Form::PasteSubmit).unwrap();
        assert!(key(&params).len() <= MAX_KEY_LEN);
    }

    #[test]
    fn a_daemon_without_keys_is_not_served() {
        assert_eq!(Form::from_caps(["send-expect-agent-v1"]), None);
        assert_eq!(Form::from_caps(["send-key-v1"]), Some(Form::TextReturn));
        assert_eq!(
            Form::from_caps(["send-key-v1", "send-expect-agent-v1"]),
            Some(Form::PasteSubmit)
        );
        assert_eq!(
            Form::from_caps(["send-key-v1", "send-expect-agent-v1", "send-typed-submit-v1"]),
            Some(Form::TypedSubmit)
        );
    }

    /// A one-line draft for a full-screen program: typed text and its Return in one keyed
    /// request, no `paste` (Leo, 2026-11-21: "the text goes through. But then the send doesn't
    /// go through"). Pasted Sends keep the paste on the same daemon.
    #[test]
    fn a_typed_send_is_one_request_without_paste() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        let now = Instant::now();
        outbox.push_typed("/status", now);
        outbox.push("ls -la", true, now);
        let (_, typed) = outbox.next_request(Form::TypedSubmit).unwrap();
        assert_eq!(typed["text"], "/status");
        assert_eq!(typed["submit"], true);
        assert!(typed.get("paste").is_none());
        assert!(!key(&typed).is_empty());
        let (_, pasted) = outbox.next_request(Form::TypedSubmit).unwrap();
        assert_eq!(pasted["paste"], true);
        assert_eq!(pasted["submit"], true);
    }

    /// Attached after the tap to a daemon without `send-typed-submit-v1`: still one request,
    /// as a paste with Return, never the text and a separate Return.
    #[test]
    fn a_typed_send_to_an_older_daemon_is_a_paste_with_submit() {
        let mut outbox = Outbox::new("phone", DEFAULT_HOLD);
        outbox.push_typed("/status", Instant::now());
        let (_, params) = outbox.next_request(Form::PasteSubmit).unwrap();
        assert_eq!(params["text"], "/status");
        assert_eq!(params["paste"], true);
        assert_eq!(params["submit"], true);
    }
}
