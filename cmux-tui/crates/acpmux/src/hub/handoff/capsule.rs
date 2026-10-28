//! The first message a handoff target receives: the source's recent user
//! and assistant messages, newest kept first within `MAX_CAPSULE_BYTES`,
//! and what that message carries per item (coverage). A source that
//! compacted leads with its latest compaction summary, followed by the
//! messages since; the messages before it are what the summary covers.

use super::{Context, Coverage, MAX_CAPSULE_BYTES};
use crate::hub::Hub;
use crate::rpc::RpcError;
use crate::store::{EventRecord, SessionMeta};
use serde_json::Value;

pub(super) struct Built {
    pub(super) text: String,
    pub(super) context: Context,
    pub(super) coverage: Vec<Coverage>,
}

/// One message of the source transcript and the record it starts at.
struct Entry {
    from_seq: u64,
    text: String,
}

const ASSISTANT: &str = "Assistant: ";
const SUMMARY_OPEN: &str = "<summary>\n";
const SUMMARY_CLOSE: &str = "\n</summary>\n\n";
const SEPARATOR: &str = "\n\n";
const CLOSING: &str = "\n</transcript>\n";

/// The last `max` bytes of `s`, starting on a character boundary.
pub(in crate::hub) fn tail(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let cut = s.len() - max;
    // Drop every character that starts before `cut`.
    let mut skipped = 0;
    s.trim_start_matches(|c: char| {
        let before = skipped < cut;
        skipped += c.len_utf8();
        before
    })
}

fn kb(bytes: usize) -> String {
    format!("{:.1} KB", bytes as f64 / 1024.0)
}

impl Hub {
    /// The capsule for `source` covering its records up to `to_seq`. Prepare
    /// never produces text that draft or start would refuse.
    pub(super) fn build_capsule(
        &self,
        source: &SessionMeta,
        to_seq: u64,
    ) -> Result<Built, RpcError> {
        let mut entries: Vec<Entry> = Vec::new();
        let mut assistant: Option<Entry> = None;
        let mut tool_calls = 0usize;
        let mut plan = false;
        // The latest compaction summary, and the record it came from.
        let mut summary: Option<(u64, String)> = None;
        let flush = |assistant: &mut Option<Entry>, entries: &mut Vec<Entry>| {
            if let Some(a) = assistant.take()
                && !a.text.strip_prefix(ASSISTANT).unwrap_or(&a.text).trim().is_empty()
            {
                entries.push(a);
            }
        };
        self.store
            .scan(&source.id, 0, &mut |rec: EventRecord| {
                if rec.seq > to_seq {
                    return false;
                }
                if rec.kind == "compaction_summary"
                    && let Some(t) = rec.msg.pointer("/params/update/text").and_then(Value::as_str)
                {
                    // What came before is in the summary.
                    assistant = None;
                    entries.clear();
                    tool_calls = 0;
                    plan = false;
                    summary = Some((rec.seq, t.to_owned()));
                    return true;
                }
                if !crate::hub::paging::is_transcript(&rec) {
                    return true;
                }
                match rec.kind.as_str() {
                    "user_message" => {
                        flush(&mut assistant, &mut entries);
                        if let Some(t) = rec.msg.get("text").and_then(Value::as_str) {
                            entries.push(Entry { from_seq: rec.seq, text: format!("User: {t}") });
                        }
                    }
                    "agent_message_chunk" => {
                        if let Some(t) = rec
                            .msg
                            .get("params")
                            .filter(|p| !crate::subagents::is_subagents(p))
                            .and_then(|p| p.pointer("/update/content/text"))
                            .and_then(Value::as_str)
                        {
                            assistant
                                .get_or_insert_with(|| Entry {
                                    from_seq: rec.seq,
                                    text: ASSISTANT.to_owned(),
                                })
                                .text
                                .push_str(t);
                        }
                    }
                    "tool_call" => tool_calls += 1,
                    "plan" => plan = true,
                    _ => {}
                }
                true
            })
            .map_err(|e| RpcError::internal(format!("read the source transcript: {e}")))?;
        flush(&mut assistant, &mut entries);

        let lead = format!(
            "Continuing from {} session {} ({}) in {}.",
            source.harness,
            source.name,
            source.id,
            source.cwd.display()
        );
        let total_bytes = entries.iter().map(|e| e.text.len()).sum::<usize>()
            + SEPARATOR.len() * entries.len().saturating_sub(1);
        if let Some((seq, summary)) = &summary {
            let (text, context, transcript) =
                summary_capsule(&lead, *seq, summary, &entries, to_seq, total_bytes);
            let mut coverage = vec![transcript];
            coverage.extend(other_coverage(source, tool_calls, plan));
            return Ok(Built { text, context, coverage });
        }
        let (mut text, context, kept) = if entries.is_empty() {
            let text = format!("{lead} The source session has no conversation yet.\n");
            let context =
                Context { from_seq: 0, to_seq, truncated: false, bytes: 0, total_bytes: 0 };
            (text, context, 0)
        } else {
            let open_all = format!(
                "{lead} The conversation so far is below; carry on from where it ended.\n\n<transcript>\n"
            );
            let open_cut = format!(
                "{lead} The most recent part of the conversation is below (older messages were cut to fit); carry on from where it ended.\n\n<transcript>\n"
            );
            let budget = MAX_CAPSULE_BYTES.saturating_sub(open_cut.len() + CLOSING.len());
            // Newest first until the budget is spent; the oldest are cut.
            let mut kept: Vec<&str> = Vec::new();
            let mut used = 0usize;
            let mut from_seq = to_seq;
            for e in entries.iter().rev() {
                let need = e.text.len() + if kept.is_empty() { 0 } else { SEPARATOR.len() };
                if used + need > budget {
                    break;
                }
                used += need;
                kept.push(&e.text);
                from_seq = e.from_seq;
            }
            if kept.is_empty()
                && let Some(last) = entries.last()
            {
                // Even the newest message is over budget: keep its end.
                let cut = tail(&last.text, budget);
                used = cut.len();
                kept.push(cut);
                from_seq = last.from_seq;
            }
            let truncated = used < total_bytes;
            kept.reverse();
            let open = if truncated { &open_cut } else { &open_all };
            let text = format!("{open}{}{CLOSING}", kept.join(SEPARATOR));
            let context = Context { from_seq, to_seq, truncated, bytes: used, total_bytes };
            (text, context, kept.len())
        };
        if text.len() > MAX_CAPSULE_BYTES {
            text = tail(&text, MAX_CAPSULE_BYTES).to_owned();
        }

        let transcript = if entries.is_empty() {
            Coverage::new("transcript", "omitted", Some("the source has no messages yet".into()))
        } else if context.truncated {
            Coverage::new(
                "transcript",
                "summarized",
                Some(format!(
                    "last {kept} of {} messages, {} of {}",
                    entries.len(),
                    kb(context.bytes),
                    kb(total_bytes)
                )),
            )
        } else {
            Coverage::new(
                "transcript",
                "included",
                Some(format!("{kept} messages, {}", kb(context.bytes))),
            )
        };
        let mut coverage = vec![transcript];
        coverage.extend(other_coverage(source, tool_calls, plan));
        Ok(Built { text, context, coverage })
    }
}

/// The text, context and transcript coverage of a source that compacted:
/// its latest summary, then the messages since, newest kept first in what
/// the summary leaves of the budget.
fn summary_capsule(
    lead: &str,
    summary_seq: u64,
    summary: &str,
    entries: &[Entry],
    to_seq: u64,
    total_bytes: usize,
) -> (String, Context, Coverage) {
    let summary = tail(summary, MAX_CAPSULE_BYTES / 2);
    let open = format!(
        "{lead} The conversation was compacted; its summary is below, then the messages since. Carry on from where it ended.\n\n{SUMMARY_OPEN}{summary}{SUMMARY_CLOSE}<transcript>\n"
    );
    let budget = MAX_CAPSULE_BYTES.saturating_sub(open.len() + CLOSING.len());
    let mut kept: Vec<&str> = Vec::new();
    let mut used = 0usize;
    let mut from_seq = summary_seq;
    for e in entries.iter().rev() {
        let need = e.text.len() + if kept.is_empty() { 0 } else { SEPARATOR.len() };
        if used + need > budget {
            break;
        }
        used += need;
        kept.push(&e.text);
        from_seq = e.from_seq;
    }
    if kept.is_empty()
        && let Some(last) = entries.last()
    {
        // Even the newest message is over budget: keep its end.
        let cut = tail(&last.text, budget);
        used = cut.len();
        kept.push(cut);
        from_seq = last.from_seq;
    }
    kept.reverse();
    let mut text = format!("{open}{}{CLOSING}", kept.join(SEPARATOR));
    if text.len() > MAX_CAPSULE_BYTES {
        text = tail(&text, MAX_CAPSULE_BYTES).to_owned();
    }
    let truncated = used < total_bytes;
    let context = Context {
        from_seq,
        to_seq,
        truncated,
        bytes: used + summary.len(),
        total_bytes: total_bytes + summary.len(),
    };
    let since = if truncated {
        format!("the last {} of the {} messages since", kept.len(), entries.len())
    } else {
        format!("the {} messages since", kept.len())
    };
    let transcript = Coverage::new(
        "transcript",
        "summarized",
        Some(format!("compaction summary ({}) and {since}", kb(summary.len()))),
    );
    (text, context, transcript)
}

/// Coverage of everything a capsule leaves out besides the transcript.
fn other_coverage(source: &SessionMeta, tool_calls: usize, plan: bool) -> Vec<Coverage> {
    let tool_output = if tool_calls > 0 {
        Coverage::new(
            "tool_output",
            "omitted",
            Some(format!("{tool_calls} tool calls; their output is not carried")),
        )
    } else {
        Coverage::new("tool_output", "omitted", Some("no tool calls".into()))
    };
    let plan = if plan {
        Coverage::new("plan", "omitted", Some("the source's plan updates are not carried".into()))
    } else {
        Coverage::new("plan", "unavailable", Some("the source reported no plan".into()))
    };
    let files = Coverage::new(
        "files",
        "omitted",
        Some("the target works in the same cwd; no file contents are copied".into()),
    );
    let model = match crate::hub::current_model(source) {
        Some(m) => Coverage::new(
            "model",
            "omitted",
            Some(format!("the source ran {m}; the target uses its own model")),
        ),
        None => Coverage::new("model", "unavailable", None),
    };
    vec![tool_output, plan, files, model]
}
