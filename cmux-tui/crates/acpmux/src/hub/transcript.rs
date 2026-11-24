//! The bounded plain-text transcript a fresh agent session is seeded with.

use super::bounded::{BoundedSuffix, Chars, TrimmedText};
use super::*;

const KINDS: &[&str] = &["user_message", "agent_message_chunk", "compaction_summary"];

/// The most characters a replay into an agent session carries (a refused resume's whole
/// transcript, an older agent session's missed turns).
pub(super) const REPLAY_CHARS: usize = 24_000;

impl Hub {
    /// Build a plain-text transcript from the log for rehydration. After a
    /// compaction it is the latest compaction summary and the messages since,
    /// and only those messages are cut to fit `max_chars`.
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

struct TranscriptBuilder {
    max_chars: usize,
    summary: Option<BoundedSuffix<Chars>>,
    lines: BoundedSuffix<Chars>,
    agent: TrimmedText<Chars>,
}

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
            lines: BoundedSuffix::new(max_chars),
            agent: TrimmedText::new(max_chars),
        }
    }

    fn user(&mut self, text: Option<&str>) {
        self.flush_agent();
        if let Some(text) = text {
            self.line_prefix("user: ");
            self.lines.push_str(text);
        }
    }

    fn agent_chunk(&mut self, text: &str) {
        self.agent.push_str(text);
    }

    fn compaction_summary(&mut self, text: &str) {
        self.agent = TrimmedText::new(self.max_chars);
        self.lines.clear();
        let mut summary = BoundedSuffix::new(self.max_chars / 2);
        summary.push_str(text);
        self.summary = Some(summary);
    }

    fn finish(mut self) -> Option<String> {
        self.flush_agent();
        if self.lines.is_empty() && self.summary.is_none() {
            return None;
        }

        // The summary keeps at most half the room (its end, where Claude
        // writes the current work and next step); the messages since get the rest.
        let head = self.summary.map(|summary| {
            let text = summary.string();
            format!("<compaction_summary>\n{text}\n</compaction_summary>")
        });
        let room =
            self.max_chars.saturating_sub(head.as_ref().map_or(0, |head| head.chars().count()));
        let text = if self.lines.total() > room {
            let skip = self.lines.total() - room;
            format!("[… {skip} earlier characters omitted …]\n{}", self.lines.tail_string(room))
        } else {
            self.lines.string()
        };
        Some(match head {
            Some(head) if text.is_empty() => head,
            Some(head) => format!("{head}\n\n{text}"),
            None => text,
        })
    }

    fn flush_agent(&mut self) {
        self.agent.finish();
        if self.agent.is_empty() {
            return;
        }
        self.line_prefix("assistant: ");
        // `agent` retains only a suffix, but `push_str` accounts for its full
        // logical length, preserving the old omission count.
        let text = self.agent.string();
        self.lines.push_str(&text);
        let logical = self.agent.total();
        let retained = text.chars().count();
        if logical > retained {
            // The retained suffix was appended above. Adjust the logical total
            // without retaining the omitted prefix.
            self.lines.add_total(logical - retained);
        }
        self.agent = TrimmedText::new(self.max_chars);
    }

    fn line_prefix(&mut self, prefix: &str) {
        if !self.lines.is_empty() {
            self.lines.push_str("\n\n");
        }
        self.lines.push_str(prefix);
    }
}

#[cfg(test)]
#[path = "transcript_tests.rs"]
mod tests;
