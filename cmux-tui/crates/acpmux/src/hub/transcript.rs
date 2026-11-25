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
mod tests {
    use super::*;

    #[derive(Clone, Copy)]
    enum Event<'a> {
        User(&'a str),
        UserMissing,
        Agent(&'a str),
        Summary(&'a str),
    }

    fn old(events: &[Event<'_>], max_chars: usize) -> Option<String> {
        let mut summary: Option<String> = None;
        let mut lines: Vec<String> = Vec::new();
        let mut agent_buf = String::new();
        let flush = |agent_buf: &mut String, lines: &mut Vec<String>| {
            if !agent_buf.trim().is_empty() {
                lines.push(format!("assistant: {}", agent_buf.trim()));
            }
            agent_buf.clear();
        };
        for event in events {
            match event {
                Event::User(text) => {
                    flush(&mut agent_buf, &mut lines);
                    lines.push(format!("user: {text}"));
                }
                Event::UserMissing => flush(&mut agent_buf, &mut lines),
                Event::Agent(text) => agent_buf.push_str(text),
                Event::Summary(text) => {
                    agent_buf.clear();
                    lines.clear();
                    summary = Some((*text).to_owned());
                }
            }
        }
        flush(&mut agent_buf, &mut lines);
        if lines.is_empty() && summary.is_none() {
            return None;
        }
        let head = summary.map(|s| {
            let skip = s.chars().count().saturating_sub(max_chars / 2);
            let s: String = s.chars().skip(skip).collect();
            format!("<compaction_summary>\n{s}\n</compaction_summary>")
        });
        let room = max_chars.saturating_sub(head.as_ref().map_or(0, |h| h.chars().count()));
        let mut text = lines.join("\n\n");
        if text.chars().count() > room {
            let skip = text.chars().count() - room;
            text = format!(
                "[… {skip} earlier characters omitted …]\n{}",
                text.chars().skip(skip).collect::<String>()
            );
        }
        Some(match head {
            Some(head) if text.is_empty() => head,
            Some(head) => format!("{head}\n\n{text}"),
            None => text,
        })
    }

    fn new(events: &[Event<'_>], max_chars: usize) -> Option<String> {
        let mut builder = TranscriptBuilder::new(max_chars);
        for event in events {
            match event {
                Event::User(text) => builder.user(Some(text)),
                Event::UserMissing => builder.user(None),
                Event::Agent(text) => builder.agent_chunk(text),
                Event::Summary(text) => builder.compaction_summary(text),
            }
        }
        builder.finish()
    }

    #[test]
    fn bounded_builder_matches_the_original_table() {
        let long = "🙂漢字".repeat(10_000);
        let cases = [
            (vec![], 0),
            (vec![Event::User("hello")], 100),
            (vec![Event::Agent("  a "), Event::Agent("b  ")], 100),
            (vec![Event::Agent("answer"), Event::UserMissing], 100),
            (vec![Event::Agent(&long), Event::User("next")], 37),
            (
                vec![
                    Event::User("before"),
                    Event::Agent("ignored"),
                    Event::Summary("summary \u{1f600}"),
                    Event::User("after"),
                    Event::Agent("  answer  "),
                ],
                24,
            ),
            (vec![Event::User(&long), Event::Agent(&long), Event::Summary(&long)], 37),
        ];
        for (events, max) in cases {
            assert_eq!(new(&events, max), old(&events, max), "max={max}");
        }
    }

    #[test]
    fn bounded_builder_matches_original_across_stream_boundaries() {
        let long = " \t\n\u{2003}".repeat(5000);
        let alphabet = ["", "x", "漢🙂", " ", "\n", "\t", "\u{2003}", &long];
        let mut seed = 0x9367_4271_u64;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed as usize
        };
        for case in 0..512 {
            let events: Vec<_> = (0..32)
                .map(|_| {
                    let text = alphabet[next() % alphabet.len()];
                    match next() % 8 {
                        0 => Event::UserMissing,
                        1 => Event::User(text),
                        2 => Event::Summary(text),
                        _ => Event::Agent(text),
                    }
                })
                .collect();
            for max in [0, 1, 7, 37, 128, 24_000] {
                assert_eq!(new(&events, max), old(&events, max), "case={case}, max={max}");
            }
        }
    }

    /// [`Hub::missed_turns`] reads the copies of its kinds past the mark only; what it tells is
    /// what a scan of the whole log past the mark, keeping its kinds, told, for every mark, on
    /// a log on disk of many segments with tool updates and the mux's records between.
    #[tokio::test]
    async fn the_missed_turns_read_past_the_mark_tell_what_the_whole_scan_did() {
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Local;
        cfg.store.segment_bytes = 64 * 1024;
        let store = crate::store::open(&cfg.store, dir.path()).unwrap();
        let meta = json!({"schema": crate::store::META_SCHEMA, "id": "behind", "name": "behind",
            "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
            "createdAt": 1, "updatedAt": 2});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        hub.begin_startup(false);
        let session = hub.resolve("behind").unwrap();
        let chunk = |text: String| {
            json!({"params": {"update": {"sessionUpdate": "agent_message_chunk",
                                         "content": {"type": "text", "text": text}}}})
        };
        for n in 0..240 {
            hub.append(&session, "mux", "user_message", json!({"text": format!("ask {n}")}));
            hub.append(
                &session,
                "agent",
                "tool_call_update",
                json!({"params": {"n": n, "pad": "x".repeat(800)}}),
            );
            hub.append(&session, "agent", "agent_message_chunk", chunk(format!("reply {n} ")));
            hub.append(&session, "mux", "turn_result", json!({"turnSeq": n}));
            if n == 60 {
                let summary = json!({"params": {"update": {"text": "the first sixty"}}});
                hub.append(&session, "agent", "compaction_summary", summary);
            }
        }
        assert!(hub.store.wait_durable(std::time::Duration::from_secs(20)).unwrap());
        let end = session.seq.load(std::sync::atomic::Ordering::SeqCst);
        for after in [1, 2, 3, 17, 200, 243, 244, 300, end / 2, end - 5, end - 1, end] {
            for max_chars in [40, REPLAY_CHARS] {
                let mut want = TranscriptBuilder::new(max_chars);
                hub.store
                    .scan(&session.id, after, &mut |e| {
                        if KINDS.contains(&e.kind.as_str()) {
                            want.read(&e);
                        }
                        true
                    })
                    .unwrap();
                let want = want.finish().map(|text| {
                    json!({"type": "text", "text": format!("<restored_transcript note=\"acpmux restored the turns this agent session did not see (it resumed from an older copy of itself); tool state was not restored\">\n{text}\n</restored_transcript>\n")})
                });
                session.meta.lock().unwrap().agent_behind_seq = Some(after);
                assert_eq!(
                    hub.missed_turns(&session, max_chars),
                    want,
                    "past {after}, {max_chars}"
                );
            }
        }
    }
}
