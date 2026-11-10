//! An agent's last reply read back from its harness transcript (W6-A, bench
//! round 5 row 4). The daemon keeps each terminal's last reply in memory only
//! (`mux/agent_prompts.rs`), and the journal keeps the transcript's path that
//! the agent's hooks name (`transcript_path`). A restarted daemon reads the
//! last assistant text from that file, which the harness owns: cmux persists
//! no reply text itself.
//!
//! Two transcript formats are read, one JSON object per line:
//!
//! - Claude Code: `{"type":"assistant","message":{"role":"assistant",
//!   "content":[{"type":"text","text":…}]}}`.
//! - Codex: `{"type":"response_item","payload":{"type":"message",
//!   "role":"assistant","content":[{"type":"output_text","text":…}]}}`.

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

/// How much of a transcript's end is read: the last reply is near the end,
/// and a long session's transcript can hold many megabytes.
const TAIL_BYTES: u64 = 512 * 1024;

/// The last assistant text of the transcript at `path`, and the file's
/// modification time in Unix milliseconds (when the reply was written, near
/// enough). `None` for a path that is not an absolute `.jsonl` file, a file
/// that cannot be read, or a tail with no assistant text.
pub(crate) fn last_assistant_text(path: &Path) -> Option<(String, u64)> {
    if !path.is_absolute()
        || path.extension().and_then(|extension| extension.to_str()) != Some("jsonl")
    {
        return None;
    }
    let mut file = std::fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    let start = metadata.len().saturating_sub(TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut tail = Vec::new();
    file.take(TAIL_BYTES).read_to_end(&mut tail).ok()?;
    let tail = String::from_utf8_lossy(&tail);
    let lines: Vec<&str> = tail.lines().collect();
    // A tail that starts inside the file starts inside a line.
    let whole_lines = lines.get(usize::from(start > 0)..)?;
    let text = whole_lines.iter().rev().find_map(|line| assistant_text(line))?;
    let at_ms = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
        .and_then(|elapsed| u64::try_from(elapsed.as_millis()).ok())
        .unwrap_or_default();
    Some((text, at_ms))
}

/// The assistant text of one transcript line, when it is an assistant
/// message with text (a tool call or a thinking block alone has none).
fn assistant_text(line: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line).ok()?;
    let message = match value.get("type").and_then(Value::as_str) {
        Some("assistant") => value.get("message")?,
        Some("response_item") => value
            .get("payload")
            .filter(|payload| payload.get("type").and_then(Value::as_str) == Some("message"))?,
        _ => return None,
    };
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return None;
    }
    let text = match message.get("content")? {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter(|block| {
                matches!(block.get("type").and_then(Value::as_str), Some("text" | "output_text"))
            })
            .filter_map(|block| block.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return None,
    };
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

#[cfg(test)]
mod tests {
    use super::last_assistant_text;

    fn transcript(name: &str, lines: &[&str]) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("cmux-w6a-transcript-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        std::fs::write(&path, lines.join("\n") + "\n").unwrap();
        path
    }

    #[test]
    fn w6a_reads_the_last_claude_code_text_past_a_tool_call() {
        let path = transcript(
            "claude.jsonl",
            &[
                r#"{"type":"user","message":{"role":"user","content":"hi"}}"#,
                r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}"#,
                r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":" BETA_BACK "}]}}"#,
                r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
                "not json",
            ],
        );
        let (text, at_ms) = last_assistant_text(&path).unwrap();
        assert_eq!(text, "BETA_BACK");
        assert!(at_ms > 0);
    }

    #[test]
    fn w6a_reads_the_last_codex_output_text() {
        let path = transcript(
            "rollout.jsonl",
            &[
                r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"q"}]}}"#,
                r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Canberra"}]}}"#,
                r#"{"type":"event_msg","payload":{"type":"token_count"}}"#,
            ],
        );
        assert_eq!(last_assistant_text(&path).map(|(text, _)| text).as_deref(), Some("Canberra"));
    }

    #[test]
    fn w6a_reads_only_absolute_jsonl_files_with_a_reply() {
        let path = transcript(
            "notes.txt",
            &[r#"{"type":"assistant","message":{"role":"assistant","content":"x"}}"#],
        );
        assert!(last_assistant_text(&path).is_none(), "not a .jsonl file");
        assert!(last_assistant_text(std::path::Path::new("relative.jsonl")).is_none());
        let empty = transcript("empty.jsonl", &[r#"{"type":"user","message":{}}"#]);
        assert!(last_assistant_text(&empty).is_none());
    }
}
