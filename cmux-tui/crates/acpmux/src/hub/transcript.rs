//! The plain-text transcript a fresh agent session is seeded with when a
//! chat moves to it (failover to the fallback harness). Part of `Hub`; see
//! `hub/mod.rs`.

use super::*;

impl Hub {
    /// Build a plain-text transcript from the log for rehydration. After a
    /// compaction it is the latest compaction summary and the messages
    /// since, and only those messages are cut to fit `max_chars`.
    pub(super) fn transcript(&self, session: &Session, max_chars: usize) -> Option<String> {
        // Only the three kinds it reads, parsed one at a time (never the whole log in memory).
        const KINDS: &[&str] = &["user_message", "agent_message_chunk", "compaction_summary"];
        let mut summary: Option<String> = None;
        let mut lines: Vec<String> = Vec::new();
        let mut agent_buf = String::new();
        let flush = |agent_buf: &mut String, lines: &mut Vec<String>| {
            if !agent_buf.trim().is_empty() {
                lines.push(format!("assistant: {}", agent_buf.trim()));
            }
            agent_buf.clear();
        };
        self.store
            .scan_kinds(&session.id, KINDS, &mut |e: EventRecord| {
                match e.kind.as_str() {
                    "user_message" => {
                        flush(&mut agent_buf, &mut lines);
                        if let Some(t) = e.msg.get("text").and_then(Value::as_str) {
                            lines.push(format!("user: {t}"));
                        }
                    }
                    "agent_message_chunk" => {
                        if let Some(t) = e
                            .msg
                            .get("params")
                            .filter(|p| !crate::subagents::is_subagents(p))
                            .and_then(|p| p.pointer("/update/content/text"))
                            .and_then(Value::as_str)
                        {
                            agent_buf.push_str(t);
                        }
                    }
                    // What came before is in the summary.
                    "compaction_summary" => {
                        if let Some(t) =
                            e.msg.pointer("/params/update/text").and_then(Value::as_str)
                        {
                            agent_buf.clear();
                            lines.clear();
                            summary = Some(t.to_owned());
                        }
                    }
                    _ => {}
                }
                true
            })
            .ok()?;
        flush(&mut agent_buf, &mut lines);
        if lines.is_empty() && summary.is_none() {
            return None;
        }
        // The summary keeps at most half the room (its end, where Claude
        // writes the current work and next step); the messages since get the rest.
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
}
