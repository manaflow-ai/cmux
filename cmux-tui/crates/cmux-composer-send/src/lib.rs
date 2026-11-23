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

use std::collections::VecDeque;
use std::time::{Duration, Instant};

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
    /// `send-key-v1` only: `{text: text + "\r", key}`, one write.
    TextReturn,
}

impl Form {
    /// The form a daemon with these capabilities takes; `None` when it takes no keys (a resend
    /// there could type the text twice, so the outbox does not serve it).
    pub fn from_caps<'a>(caps: impl IntoIterator<Item = &'a str>) -> Option<Form> {
        let (mut key, mut submit) = (false, false);
        for cap in caps {
            key |= cap == "send-key-v1";
            submit |= cap == "send-expect-agent-v1";
        }
        match (key, submit) {
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
    text: String,
    submit: bool,
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
        nonce.truncate(MAX_KEY_LEN - 21);
        Outbox { nonce, next_seq: 1, hold: hold.min(DAEMON_KEY_TTL / 2), entries: VecDeque::new() }
    }

    pub fn hold(&self) -> Duration {
        self.hold
    }

    /// A tap on Send: `text` and, with `submit`, its Return. Returns the Send's number.
    pub fn push(&mut self, text: impl Into<String>, submit: bool, now: Instant) -> u64 {
        let seq = self.next_seq;
        self.next_seq += 1;
        self.entries.push_back(Entry {
            seq,
            key: format!("{}-{seq}", self.nonce),
            text: text.into(),
            submit,
            queued: now,
            tried: false,
            in_flight: false,
        });
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
        let params = match (form, entry.submit) {
            (Form::PasteSubmit, submit) => {
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
        let outcome = match answer {
            Answer::Applied => Outcome::Sent,
            // Nothing written: the text goes back.
            Answer::Refused => Outcome::NotSent { text: self.entries[index].text.clone() },
            Answer::Uncertain => Outcome::MaybeSent { text: self.entries[index].text.clone() },
            Answer::Lost => {
                if self.entries[index].in_flight {
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
        self.entries.front().map(|e| e.queued + self.hold)
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
    }
}
