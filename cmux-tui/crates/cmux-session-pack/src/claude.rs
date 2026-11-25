//! Claude Code transcripts (`~/.claude/projects/<project>/<session>.jsonl`): which of their
//! lines start a turn, and what such a line asked.
//!
//! A transcript is told by its lines' shape, not by a flag: a line with no acpmux head that is a
//! `{"type":"user",...}` record whose message is a person's text starts a turn. Of the user
//! records Claude Code writes, these do not:
//!
//! - a tool's result (`toolUseResult`, or a `tool_result` block in the content);
//! - a line the harness made, not the person: `isMeta` (skill bodies, system reminders, local
//!   command caveats), `isCompactSummary` and `isVisibleInTranscriptOnly` (the summary a
//!   compaction put in place of the conversation), and a background task's notification
//!   (`origin.kind` `task-notification`, `promptSource` `system`, or text that starts
//!   `<task-notification>`);
//! - a subagent's line (`isSidechain`), which is the subagent's conversation, not this one's;
//! - a slash command's output (`<local-command-stdout>`) and the marker an interrupt leaves
//!   (`[Request interrupted by user`).
//!
//! A slash command a person typed (`<command-name>`) does start one.

use serde_json::Value;

/// Starts of a person's text that the harness wrote, not the person.
const NOT_ASKED: [&str; 5] = [
    "<task-notification>",
    "<local-command-stdout>",
    "<local-command-stderr>",
    "<local-command-caveat>",
    "[Request interrupted by user",
];

/// Whether a line that is not an acpmux record starts a turn of a Claude Code transcript.
pub(crate) fn starts_turn(line: &[u8]) -> bool {
    // Most lines are not user records, and of those most are tool results: neither is parsed.
    // Inside a JSON string a quote is escaped, so these bytes are the record's own keys.
    let finder = |s: &str, line: &[u8]| memchr::memmem::find(line, s.as_bytes()).is_some();
    if !finder(r#""type":"user""#, line) || finder(r#""type":"tool_result""#, line) {
        return false;
    }
    serde_json::from_slice::<Value>(line).is_ok_and(|v| asked(&v).is_some())
}

/// What a transcript's user record asked, when it is a person's prompt (see the module's
/// rules); an image with no text is `[image]`.
pub(crate) fn asked(v: &Value) -> Option<String> {
    if v.get("type")?.as_str()? != "user" || v.get("kind").is_some() {
        return None;
    }
    let set = |k: &str| v.get(k).and_then(Value::as_bool) == Some(true);
    if ["isMeta", "isSidechain", "isCompactSummary", "isVisibleInTranscriptOnly"]
        .into_iter()
        .any(set)
        || v.get("toolUseResult").is_some()
        || v.pointer("/origin/kind").and_then(Value::as_str) == Some("task-notification")
        || v.get("promptSource").and_then(Value::as_str) == Some("system")
    {
        return None;
    }
    let message = v.get("message")?;
    if message.get("role").and_then(Value::as_str).is_some_and(|r| r != "user") {
        return None;
    }
    let text = match message.get("content")? {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => {
            let mut text = String::new();
            let mut image = false;
            for b in blocks {
                match b.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if !text.is_empty() {
                            text.push('\n');
                        }
                        text.push_str(b.get("text").and_then(Value::as_str).unwrap_or(""));
                    }
                    Some("image") => image = true,
                    Some("tool_result") => return None,
                    _ => {}
                }
            }
            if text.is_empty() && image {
                text.push_str("[image]");
            }
            if text.is_empty() && !blocks.iter().any(|b| b.get("type").is_some()) {
                return None;
            }
            text
        }
        _ => return None,
    };
    let head = text.trim_start();
    if NOT_ASKED.iter().any(|p| head.starts_with(p)) {
        return None;
    }
    Some(text)
}

/// A transcript line's `timestamp` (RFC 3339, as Claude Code writes it:
/// `2026-11-23T09:42:00.123Z`) in ms since 1970.
pub(crate) fn timestamp_ms(v: &Value) -> Option<u64> {
    parse_rfc3339(v.get("timestamp")?.as_str()?)
}

fn parse_rfc3339(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let d = b.get(r)?;
        if d.is_empty() || !d.iter().all(u8::is_ascii_digit) {
            return None;
        }
        std::str::from_utf8(d).ok()?.parse().ok()
    };
    let sep = |i: usize, c: &[u8]| b.get(i).is_some_and(|x| c.contains(x));
    if !(sep(4, b"-") && sep(7, b"-") && sep(10, b"Tt ") && sep(13, b":") && sep(16, b":")) {
        return None;
    }
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, sec) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    let mut i = 19;
    let mut ms = 0i64;
    if sep(i, b".") {
        i += 1;
        let start = i;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        let frac = b.get(start..i)?;
        for k in 0..3 {
            ms = ms * 10 + frac.get(k).map_or(0, |c| i64::from(c - b'0'));
        }
    }
    let offset_min = match b.get(i)? {
        b'Z' | b'z' if i + 1 == b.len() => 0,
        c @ (b'+' | b'-') if i + 6 == b.len() && sep(i + 3, b":") => {
            let m = num(i + 1..i + 3)? * 60 + num(i + 4..i + 6)?;
            if *c == b'+' { m } else { -m }
        }
        _ => return None,
    };
    // Days from 1970-01-01 to the date (Howard Hinnant's days_from_civil).
    let y = if mo <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = days * 86_400 + h * 3600 + mi * 60 + sec - offset_min * 60;
    u64::try_from(secs * 1000 + ms).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps() {
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339("2026-11-23T09:42:00.123Z"), Some(1_795_426_920_123));
        assert_eq!(parse_rfc3339("2026-11-23T10:42:00.123+01:00"), Some(1_795_426_920_123));
        assert_eq!(parse_rfc3339("2000-02-29T00:00:00.5Z"), Some(951_782_400_500));
        assert_eq!(parse_rfc3339("2026-11-23"), None);
        assert_eq!(parse_rfc3339("2026-13-23T09:42:00Z"), None);
    }

    #[test]
    fn what_starts_a_turn() {
        let yes = [
            r#"{"type":"user","message":{"role":"user","content":"fix the build"},"timestamp":"2026-11-23T09:42:00.000Z"}"#,
            r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix it"}]},"isSidechain":false}"#,
            r#"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{}}]}}"#,
            r#"{"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>"}}"#,
            r#"{"type":"user","message":{"role":"user","content":"say \"type\":\"tool_result\" back"}}"#,
        ];
        let no = [
            r#"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"ok"}]},"toolUseResult":{}}"#,
            r#"{"type":"user","message":{"role":"user","content":"x"},"isMeta":true}"#,
            r#"{"type":"user","message":{"role":"user","content":"x"},"isSidechain":true}"#,
            r#"{"type":"user","message":{"role":"user","content":"This session is being continued"},"isCompactSummary":true,"isVisibleInTranscriptOnly":true}"#,
            r#"{"type":"user","message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#,
            r#"{"type":"user","message":{"role":"user","content":"done"},"origin":{"kind":"task-notification"}}"#,
            r#"{"type":"user","message":{"role":"user","content":"<local-command-stdout>ok</local-command-stdout>"}}"#,
            r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            r#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
            r#"{"type":"last-prompt","lastPrompt":"fix the build"}"#,
            r#"{"type":"user","message":{"role":"user","content":[]}}"#,
            "not json \"type\":\"user\"",
        ];
        for l in yes {
            assert!(starts_turn(l.as_bytes()), "{l}");
        }
        for l in no {
            assert!(!starts_turn(l.as_bytes()), "{l}");
        }
    }
}
