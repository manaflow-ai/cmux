//! The bounded plain-text transcript a fresh agent session is seeded with.

use super::bounded::{BoundedSuffix, Chars, TrimmedText};
use super::*;

const KINDS: &[&str] = &["user_message", "agent_message_chunk", "compaction_summary"];

/// The most characters a replay into an agent session carries (a fork's or a refused resume's
/// whole transcript, an older agent session's missed turns): a long chat whole, about 50K tokens.
/// A longer one keeps its first prompt and newest messages word for word and shortens the ones
/// between (`TranscriptBuilder`): the agent holds every turn the chat shows, and is told which it
/// holds only in part (#50094).
pub(super) const REPLAY_CHARS: usize = 200_000;

impl Hub {
    /// Build a plain-text transcript from the log for rehydration: the chat's first prompt, and
    /// after a compaction the latest compaction summary and the messages since, fit to
    /// `max_chars` as [`TranscriptBuilder`] says.
    ///
    /// `prompt_id` is the turn the transcript is sent with. Its prompt is logged before the
    /// transcript is built and goes to the agent right after it, so the transcript leaves it
    /// out: sent in both, a restored chat's prompt reached the agent twice.
    pub(super) fn transcript(
        &self,
        session: &Session,
        max_chars: usize,
        prompt_id: &str,
    ) -> Option<String> {
        let mut transcript = TranscriptBuilder::new(max_chars);
        // Unindexed kinds: the whole log, off the runtime's workers (`qos::off_worker`).
        crate::qos::off_worker(|| {
            self.store.scan_kinds(&session.id, KINDS, &mut |e: EventRecord| {
                // The turn's own prompt goes to the agent right after the transcript.
                if e.kind == "user_message"
                    && e.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id)
                {
                    return true;
                }
                transcript.read(&e)
            })
        })
        .ok()?;
        transcript.finish()
    }

    /// The turns the agent's own session lacks (`SessionMeta::agent_behind_seq`), as the block
    /// its next prompt starts with, and the mark goes: the transcript of the records past that
    /// seq, within `max_chars` as [`Self::transcript`]. None when there is no mark, or nothing
    /// past it to tell.
    pub(super) fn missed_turns(&self, session: &Session, max_chars: usize) -> Option<Value> {
        let after =
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).agent_behind_seq.take()?;
        self.save_meta(session);
        let mut transcript = TranscriptBuilder::new(max_chars);
        // Only the records past the mark, and of those only the transcript's kinds are parsed:
        // the agent output's tool updates and the mux's own records are passed on their heads.
        // Off the runtime's workers (`qos::off_worker`).
        let read = crate::qos::off_worker(|| {
            self.store.scan_kinds_after(&session.id, after, KINDS, &mut |e| {
                transcript.read(&e);
                true
            })
        });
        read.ok()?;
        let text = transcript.finish()?;
        Some(
            json!({"type": "text", "text": format!("<restored_transcript note=\"acpmux restored the turns this agent session did not see (it resumed from an older copy of itself); tool state was not restored\">\n{text}\n</restored_transcript>\n")}),
        )
    }
}

/// One message of the transcript: its role, its text as kept, and its whole length in chars.
struct Message {
    user: bool,
    text: String,
    chars: usize,
}

impl Message {
    fn line(&self) -> String {
        format!("{}{}", if self.user { "user: " } else { "assistant: " }, self.text)
    }

    fn kept(&self) -> usize {
        self.text.chars().count() + if self.user { 6 } else { 11 } + SEPARATOR_CHARS
    }

    /// The message as its opening words, one line.
    fn excerpt(&self) -> Message {
        let flat: String = self.text.split_whitespace().collect::<Vec<_>>().join(" ");
        let mut text: String = flat.chars().take(EXCERPT_CHARS).collect();
        if text.chars().count() < flat.chars().count() {
            text.push('…');
        }
        Message { user: self.user, text, chars: self.chars }
    }
}

const SEPARATOR_CHARS: usize = 2;

/// The first `max` chars of `text`, and whether that cut it.
fn head(text: &str, max: usize) -> (String, bool) {
    match text.char_indices().nth(max) {
        Some((at, _)) => (text.get(..at).unwrap_or(text).to_owned(), true),
        None => (text.to_owned(), false),
    }
}

/// The transcript a fresh agent session reads, built as the log streams by (`read`), within
/// `max_chars`. Small enough, it is every message word for word. Past that it keeps what the fork
/// or restore must not lose: the chat's first prompt and its newest messages word for word, the
/// messages between as their opening words, and a line that says which were shortened, so the
/// agent knows what it holds of what the chat shows. The latest compaction summary stands in for
/// everything before it except the first prompt. Memory is bounded by `max_chars` however long
/// the log.
struct TranscriptBuilder {
    max_chars: usize,
    summary: Option<BoundedSuffix<Chars>>,
    /// The chat's first prompt (cut to `max_chars / 8`), kept through compactions.
    first: Option<Message>,
    /// Messages read, the first prompt included: a message's number.
    count: usize,
    /// The newest messages word for word, by number, within `max_chars`.
    recent: std::collections::VecDeque<(usize, Message)>,
    recent_chars: usize,
    /// Messages pushed out of `recent`, as their opening words, within `max_chars / 4`.
    shortened: std::collections::VecDeque<(usize, Message)>,
    shortened_chars: usize,
    /// The first and last number of the messages shortened, how many and their whole length.
    shortened_from: Option<usize>,
    shortened_to: usize,
    shortened_count: usize,
    shortened_total: usize,
    /// Shortened messages whose opening words did not fit either.
    left_out: usize,
    agent: TrimmedText<Chars>,
}

const EXCERPT_CHARS: usize = 160;

impl TranscriptBuilder {
    /// One record of the log, of [`KINDS`]; always goes on.
    fn read(&mut self, e: &EventRecord) -> bool {
        match e.kind.as_str() {
            "user_message" => self.user(e.msg.get("text").and_then(Value::as_str)),
            "agent_message_chunk" => {
                if let Some(text) = e
                    .msg
                    .get("params")
                    .filter(|p| !crate::subagents::is_subagents(p))
                    .and_then(|p| p.pointer("/update/content/text"))
                    .and_then(Value::as_str)
                {
                    self.agent_chunk(text);
                }
            }
            "compaction_summary" => {
                if let Some(text) = e.msg.pointer("/params/update/text").and_then(Value::as_str) {
                    self.compaction_summary(text);
                }
            }
            _ => {}
        }
        true
    }

    fn new(max_chars: usize) -> Self {
        Self {
            max_chars,
            summary: None,
            first: None,
            count: 0,
            recent: Default::default(),
            recent_chars: 0,
            shortened: Default::default(),
            shortened_chars: 0,
            shortened_from: None,
            shortened_to: 0,
            shortened_count: 0,
            shortened_total: 0,
            left_out: 0,
            agent: TrimmedText::new(max_chars),
        }
    }

    fn user(&mut self, text: Option<&str>) {
        self.flush_agent();
        if let Some(text) = text {
            let chars = text.chars().count();
            if self.first.is_none() {
                let (mut kept, cut) = head(text, self.max_chars / 8);
                if cut {
                    kept.push_str(&format!(
                        " [… {} more characters of this prompt cut …]",
                        chars - kept.chars().count()
                    ));
                }
                self.count += 1;
                self.first = Some(Message { user: true, text: kept, chars });
                return;
            }
            let (kept, _) = head(text, self.max_chars);
            self.push(Message { user: true, text: kept, chars });
        }
    }

    fn agent_chunk(&mut self, text: &str) {
        self.agent.push_str(text);
    }

    fn compaction_summary(&mut self, text: &str) {
        // The summary covers every message before it but the first prompt, which stays.
        self.agent = TrimmedText::new(self.max_chars);
        self.recent.clear();
        self.recent_chars = 0;
        self.shortened.clear();
        self.shortened_chars = 0;
        self.shortened_from = None;
        self.shortened_to = 0;
        self.shortened_count = 0;
        self.shortened_total = 0;
        self.left_out = 0;
        let mut summary = BoundedSuffix::new(self.max_chars / 2);
        summary.push_str(text);
        self.summary = Some(summary);
    }

    fn push(&mut self, message: Message) {
        self.count += 1;
        self.recent_chars += message.kept();
        self.recent.push_back((self.count, message));
        while self.recent_chars > self.max_chars && self.recent.len() > 1 {
            self.shorten_oldest();
        }
    }

    /// The oldest of the newest messages becomes its opening words.
    fn shorten_oldest(&mut self) {
        let Some((n, message)) = self.recent.pop_front() else { return };
        self.recent_chars -= message.kept();
        self.shortened_from.get_or_insert(n);
        self.shortened_to = n;
        self.shortened_count += 1;
        self.shortened_total += message.chars;
        let excerpt = message.excerpt();
        self.shortened_chars += excerpt.kept();
        self.shortened.push_back((n, excerpt));
        while self.shortened_chars > self.max_chars / 4 {
            let Some((_, gone)) = self.shortened.pop_front() else { break };
            self.shortened_chars -= gone.kept();
            self.left_out += 1;
        }
    }

    fn finish(mut self) -> Option<String> {
        self.flush_agent();
        if self.first.is_none() && self.recent.is_empty() && self.summary.is_none() {
            return None;
        }
        // The summary keeps at most half the room (its end, where Claude writes the current
        // work and next step), the first prompt an eighth; the messages since get the rest,
        // the newest word for word.
        let head = self.summary.as_ref().map(|summary| {
            let text = summary.string();
            format!("<compaction_summary>\n{text}\n</compaction_summary>")
        });
        let first = self.first.as_ref().map(Message::line);
        let fixed = head.as_ref().map_or(0, |h| h.chars().count())
            + first.as_ref().map_or(0, |f| f.chars().count());
        let room = self.max_chars.saturating_sub(fixed);
        while self.recent.len() > 1 && self.recent_chars + self.shortened_chars > room {
            self.shorten_oldest();
        }
        let mut parts: Vec<String> = Vec::new();
        parts.extend(first);
        parts.extend(head);
        if let Some(from) = self.shortened_from {
            let total = self.count;
            let (to, n, chars) = (self.shortened_to, self.shortened_count, self.shortened_total);
            let left_out = if self.left_out > 0 {
                format!("; the oldest {} of them are left out entirely", self.left_out)
            } else {
                String::new()
            };
            parts.push(format!(
                "[acpmux shortened messages {from} to {to} of {total} ({n} messages, {chars} characters) to their opening words to fit{left_out}; the chat itself still shows them in full]"
            ));
            parts.extend(self.shortened.iter().map(|(_, m)| m.line()));
            parts.push(format!("[the messages from {} on are word for word]", to + 1));
        }
        let budget = room.saturating_sub(self.shortened_chars);
        for (_, message) in &self.recent {
            let line = message.line();
            let len = line.chars().count();
            if len > budget && self.recent.len() == 1 {
                // One message over the whole room: its end, as the chat's newest words.
                let cut = len - budget;
                parts.push(format!(
                    "[… {cut} earlier characters omitted …]\n{}",
                    <Chars as super::bounded::SuffixMetric>::tail(&line, budget)
                ));
            } else {
                parts.push(line);
            }
        }
        Some(parts.join("\n\n"))
    }

    fn flush_agent(&mut self) {
        self.agent.finish();
        if self.agent.is_empty() {
            return;
        }
        let text = self.agent.string();
        let logical = self.agent.total();
        let retained = text.chars().count();
        let text = if logical > retained {
            format!("[… {} earlier characters of this reply omitted …]{text}", logical - retained)
        } else {
            text
        };
        self.agent = TrimmedText::new(self.max_chars);
        self.push(Message { user: false, text, chars: logical });
    }
}

#[cfg(test)]
#[path = "transcript_tests.rs"]
mod tests;
