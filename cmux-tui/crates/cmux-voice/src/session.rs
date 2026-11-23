//! The streaming dictation session as a pure reducer: events in, effects out.
//!
//! A streaming provider hears the audio as it is spoken and answers with a rolling hypothesis
//! for each utterance (a *partial*) that it later commits (a *final*). This reducer is the one
//! lifecycle every surface draws (the macOS composer, Home, the terminal; later the iPhone and
//! the web page): it orders the provider's utterances, turns their deltas into the two events
//! the app shows ([`Shown::Partial`] replaces the hypothesis, [`Shown::Final`] commits a
//! segment), decides when a stopped session is done, and keeps every word heard before a failure.
//! It does no I/O and reads no clock: the wire ([`crate::stream`]) feeds it and carries out its
//! [`Effect`]s, and the deadline is an event like any other.
//!
//! Phases (the design's lifecycle table, dictation half): `Connecting` (the socket and the
//! session are being opened; audio is held by the wire), `Listening`, `Finalizing` (the person
//! stopped: the last audio is committed and the last words are awaited), then `Done` or
//! `Failed`. A cancel goes straight to `Done` and shows nothing more.

use crate::error::{ErrorCode, VoiceError};

/// Where the session stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Connecting,
    Listening,
    Finalizing,
    Done,
    Failed,
}

/// What happened, from the wire or the person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The provider accepted the session; audio flows.
    Ready,
    /// The provider committed a stretch of audio as utterance `item` (in speaking order).
    Committed { item: String },
    /// More words of utterance `item`'s hypothesis.
    Delta { item: String, text: String },
    /// Utterance `item`'s final words (they replace its deltas).
    Completed { item: String, text: String },
    /// The provider could not transcribe utterance `item`; its hypothesis is kept as final.
    ItemFailed { item: String },
    /// The person stopped: commit what is left, wait for the last words.
    Stop,
    /// The provider said the last commit had no audio (nothing was spoken since the last
    /// utterance): nothing more is coming for it.
    CommitEmpty,
    /// The person cancelled (Esc): show nothing more, send nothing more.
    Cancel,
    /// The provider refused or failed.
    Failed(VoiceError),
    /// The socket closed.
    Closed,
    /// The finalizing deadline passed.
    Deadline,
}

/// What the person sees: the two events of `DictationTranscriptionEvent` in the app.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Shown {
    /// Replaces the hypothesis being spoken (empty clears it).
    Partial(String),
    /// Commits a segment; the hypothesis is discarded.
    Final(String),
}

/// What the wire does next.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    Show(Shown),
    /// Commit the audio sent since the last utterance.
    Commit,
    /// Start the finalizing deadline.
    StartDeadline,
    /// Close the socket; the session is over with this outcome.
    End(Result<(), VoiceError>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Utterance {
    item: String,
    text: String,
    done: bool,
}

/// One streaming dictation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    phase: Phase,
    /// Utterances not yet shown as final, in speaking order.
    open: Vec<Utterance>,
    /// The last partial shown, so an unchanged one is not shown again.
    shown_partial: String,
    /// A stop's commit is unanswered.
    awaiting_commit: bool,
    /// Every final shown, joined: the session's text.
    text: String,
}

impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}

impl Session {
    pub fn new() -> Self {
        Self {
            phase: Phase::Connecting,
            open: Vec::new(),
            shown_partial: String::new(),
            awaiting_commit: false,
            text: String::new(),
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    /// Every final shown so far, joined with spaces.
    pub fn text(&self) -> &str {
        &self.text
    }

    fn over(&self) -> bool {
        matches!(self.phase, Phase::Done | Phase::Failed)
    }

    fn utterance(&mut self, item: &str) -> &mut Utterance {
        let at = match self.open.iter().position(|u| u.item == item) {
            Some(at) => at,
            None => {
                // A delta before its commit (some providers send them in that order).
                self.open.push(Utterance {
                    item: item.to_owned(),
                    text: String::new(),
                    done: false,
                });
                self.open.len() - 1
            }
        };
        &mut self.open[at]
    }

    /// Shows the leading finished utterances as finals, then the rest as the partial.
    fn flush(&mut self, out: &mut Vec<Effect>) {
        while self.open.first().is_some_and(|u| u.done) {
            let u = self.open.remove(0);
            let words = u.text.trim();
            if !words.is_empty() {
                if !self.text.is_empty() {
                    self.text.push(' ');
                }
                self.text.push_str(words);
                out.push(Effect::Show(Shown::Final(words.to_owned())));
                // A final discards the partial in the app.
                self.shown_partial.clear();
            }
        }
        let partial = self
            .open
            .iter()
            .map(|u| u.text.trim())
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if partial != self.shown_partial {
            self.shown_partial = partial.clone();
            out.push(Effect::Show(Shown::Partial(partial)));
        }
    }

    /// Every open utterance's words as final: what was heard is kept.
    fn keep_everything(&mut self, out: &mut Vec<Effect>) {
        for u in &mut self.open {
            u.done = true;
        }
        self.flush(out);
    }

    fn finish_if_settled(&mut self, out: &mut Vec<Effect>) {
        if self.phase == Phase::Finalizing
            && !self.awaiting_commit
            && self.open.iter().all(|u| u.done)
        {
            self.flush(out);
            self.phase = Phase::Done;
            out.push(Effect::End(Ok(())));
        }
    }

    /// Applies `event`; the effects to carry out, in order. An event after the end does nothing.
    pub fn apply(&mut self, event: Event) -> Vec<Effect> {
        let mut out = Vec::new();
        if self.over() {
            return out;
        }
        match event {
            Event::Ready => {
                if self.phase == Phase::Connecting {
                    self.phase = Phase::Listening;
                }
            }
            Event::Committed { item } => {
                self.utterance(&item);
                self.awaiting_commit = false;
                self.finish_if_settled(&mut out);
            }
            Event::Delta { item, text } => {
                let u = self.utterance(&item);
                if !u.done {
                    u.text.push_str(&text);
                }
                self.flush(&mut out);
            }
            Event::Completed { item, text } => {
                let u = self.utterance(&item);
                u.text = text;
                u.done = true;
                self.flush(&mut out);
                self.finish_if_settled(&mut out);
            }
            Event::ItemFailed { item } => {
                self.utterance(&item).done = true;
                self.flush(&mut out);
                self.finish_if_settled(&mut out);
            }
            Event::Stop => match self.phase {
                Phase::Connecting => {
                    // Nothing reached the provider: done with nothing.
                    self.phase = Phase::Done;
                    out.push(Effect::End(Ok(())));
                }
                Phase::Listening => {
                    self.phase = Phase::Finalizing;
                    self.awaiting_commit = true;
                    out.push(Effect::Commit);
                    out.push(Effect::StartDeadline);
                }
                Phase::Finalizing | Phase::Done | Phase::Failed => {}
            },
            Event::CommitEmpty => {
                self.awaiting_commit = false;
                self.finish_if_settled(&mut out);
            }
            Event::Cancel => {
                self.phase = Phase::Done;
                self.open.clear();
                out.push(Effect::End(Ok(())));
            }
            Event::Deadline => {
                if self.phase == Phase::Finalizing {
                    self.keep_everything(&mut out);
                    self.phase = Phase::Done;
                    out.push(Effect::End(Ok(())));
                }
            }
            Event::Closed => {
                self.keep_everything(&mut out);
                if self.phase == Phase::Finalizing {
                    self.phase = Phase::Done;
                    out.push(Effect::End(Ok(())));
                } else {
                    self.phase = Phase::Failed;
                    out.push(Effect::End(Err(VoiceError::new(
                        ErrorCode::Offline,
                        "the dictation service closed the connection",
                        None,
                    ))));
                }
            }
            Event::Failed(error) => {
                self.keep_everything(&mut out);
                self.phase = Phase::Failed;
                out.push(Effect::End(Err(error)));
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn committed(item: &str) -> Event {
        Event::Committed { item: item.into() }
    }
    fn delta(item: &str, text: &str) -> Event {
        Event::Delta { item: item.into(), text: text.into() }
    }
    fn completed(item: &str, text: &str) -> Event {
        Event::Completed { item: item.into(), text: text.into() }
    }
    fn partial(text: &str) -> Effect {
        Effect::Show(Shown::Partial(text.into()))
    }
    fn final_(text: &str) -> Effect {
        Effect::Show(Shown::Final(text.into()))
    }

    fn listening() -> Session {
        let mut s = Session::new();
        assert!(s.apply(Event::Ready).is_empty());
        assert_eq!(s.phase(), Phase::Listening);
        s
    }

    #[test]
    fn words_appear_while_speaking_then_commit() {
        let mut s = listening();
        assert_eq!(s.apply(committed("a")), vec![]);
        assert_eq!(s.apply(delta("a", "Hello")), vec![partial("Hello")]);
        assert_eq!(s.apply(delta("a", " there")), vec![partial("Hello there")]);
        assert_eq!(s.apply(completed("a", "Hello there.")), vec![final_("Hello there.")]);
        assert_eq!(s.text(), "Hello there.");
        assert_eq!(s.phase(), Phase::Listening);
    }

    #[test]
    fn utterances_show_in_speaking_order_even_when_a_later_one_finishes_first() {
        let mut s = listening();
        s.apply(committed("a"));
        s.apply(committed("b"));
        assert_eq!(s.apply(delta("a", "one")), vec![partial("one")]);
        assert_eq!(s.apply(delta("b", "two")), vec![partial("one two")]);
        // b finishes first: it waits behind a, and the partial is unchanged.
        assert_eq!(s.apply(completed("b", "Two.")), vec![partial("one Two.")]);
        assert_eq!(
            s.apply(completed("a", "One.")),
            vec![final_("One."), final_("Two."), partial("")]
        );
        assert_eq!(s.text(), "One. Two.");
    }

    #[test]
    fn stop_commits_waits_for_the_last_words_then_ends() {
        let mut s = listening();
        s.apply(delta("a", "almost"));
        assert_eq!(s.apply(Event::Stop), vec![Effect::Commit, Effect::StartDeadline]);
        assert_eq!(s.phase(), Phase::Finalizing);
        // The commit names the utterance already speaking: not done until it completes.
        assert_eq!(s.apply(committed("a")), vec![]);
        assert_eq!(
            s.apply(completed("a", "Almost done.")),
            vec![final_("Almost done."), Effect::End(Ok(()))]
        );
        assert_eq!(s.phase(), Phase::Done);
        assert!(s.apply(delta("a", "late")).is_empty());
    }

    #[test]
    fn stop_with_nothing_new_ends_on_the_empty_commit() {
        let mut s = listening();
        s.apply(committed("a"));
        s.apply(completed("a", "Said."));
        s.apply(Event::Stop);
        assert_eq!(s.apply(Event::CommitEmpty), vec![Effect::End(Ok(()))]);
    }

    #[test]
    fn stop_before_the_provider_answers_ends_with_nothing() {
        let mut s = Session::new();
        assert_eq!(s.apply(Event::Stop), vec![Effect::End(Ok(()))]);
        assert_eq!(s.phase(), Phase::Done);
    }

    #[test]
    fn the_deadline_keeps_the_hypothesis_as_final() {
        let mut s = listening();
        s.apply(delta("a", "kept words"));
        s.apply(Event::Stop);
        assert_eq!(s.apply(Event::Deadline), vec![final_("kept words"), Effect::End(Ok(()))]);
        assert_eq!(s.text(), "kept words");
    }

    #[test]
    fn a_failure_keeps_every_word_heard() {
        let mut s = listening();
        s.apply(completed("a", "First."));
        s.apply(delta("b", "second"));
        let err = VoiceError::bare(ErrorCode::RateLimited);
        assert_eq!(
            s.apply(Event::Failed(err.clone())),
            vec![final_("second"), Effect::End(Err(err))]
        );
        assert_eq!(s.phase(), Phase::Failed);
        assert_eq!(s.text(), "First. second");
    }

    #[test]
    fn a_close_while_listening_is_offline_and_while_finalizing_is_the_end() {
        let mut s = listening();
        s.apply(delta("a", "x"));
        let out = s.apply(Event::Closed);
        assert_eq!(out[0], final_("x"));
        assert!(matches!(&out[1], Effect::End(Err(e)) if e.code == ErrorCode::Offline));

        let mut s = listening();
        s.apply(Event::Stop);
        assert_eq!(s.apply(Event::Closed), vec![Effect::End(Ok(()))]);
    }

    #[test]
    fn cancel_shows_nothing_more() {
        let mut s = listening();
        s.apply(delta("a", "dropped"));
        assert_eq!(s.apply(Event::Cancel), vec![Effect::End(Ok(()))]);
        assert!(s.apply(completed("a", "dropped")).is_empty());
        assert_eq!(s.text(), "");
    }

    #[test]
    fn a_failed_item_keeps_its_hypothesis_and_blank_ones_show_nothing() {
        let mut s = listening();
        s.apply(delta("a", "  "));
        assert_eq!(s.apply(Event::ItemFailed { item: "a".into() }), vec![]);
        s.apply(delta("b", "heard"));
        assert_eq!(
            s.apply(Event::ItemFailed { item: "b".into() }),
            vec![final_("heard"), partial("")]
        );
    }
}
