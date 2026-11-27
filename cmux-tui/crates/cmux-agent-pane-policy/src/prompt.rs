//! The presentation and answer rules for an acpmux permission prompt.
//!
//! These are deliberately kept beside the pane policy so every host shows and
//! answers the same request. The input is untrusted JSON from a daemon; a
//! malformed or missing value returns `None` and the FFI caller reports an
//! invalid request rather than widening what can be answered.

use regex::Regex;
use serde_json::{Map, Value, json};
use std::sync::LazyLock;
use unicode_segmentation::UnicodeSegmentation;

pub const REDACTED: &str = "[redacted]";
const SCRUB_WINDOW: usize = 16 * 1024;

static WHOLE: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)",
        r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
        r"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}",
        r"\b(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{20,}",
        r"\bgithub_pat_[A-Za-z0-9_]{20,}",
        r"\bglpat-[A-Za-z0-9_-]{16,}",
        r"\bxox[abposr]-[A-Za-z0-9-]{10,}",
        r"\b(AKIA|ASIA)[0-9A-Z]{16}\b",
        r"\bAIza[0-9A-Za-z_-]{30,}",
        r"\bnpm_[A-Za-z0-9]{30,}",
        r"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@",
    ]
    .into_iter()
    .map(|pattern| Regex::new(pattern).expect("prompt scrub regex"))
    .collect()
});

static BEARER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)(\b(?:bearer|basic)\s+)([^\s"',;]{4,})"#).unwrap());
static VALUED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r##"(?i)(\b[a-z0-9_.-]*(?:api[_-]?key|token|secret|passw(?:or)?d|pwd|credential|auth(?:orization)?)[a-z0-9_.-]*["']?\s*[:=]\s*["']?)([^\s"',;]{4,})"##,
    )
    .unwrap()
});

pub fn scrub(text: &str, prefix: bool) -> String {
    let mut out: String =
        if prefix { text.graphemes(true).take(SCRUB_WINDOW).collect() } else { text.to_owned() };
    if out.is_empty() {
        return out;
    }
    for pattern in WHOLE.iter() {
        out = pattern.replace_all(&out, REDACTED).into_owned();
    }
    out = BEARER.replace_all(&out, "${1}[redacted]").into_owned();
    VALUED.replace_all(&out, "${1}[redacted]").into_owned()
}

pub fn visible(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        let n = u32::from(c);
        if matches!(
            n,
            0x061c | 0x180e | 0x200b..=0x200f | 0x202a..=0x202e | 0x2060..=0x2064
                | 0x2066..=0x2069 | 0xfeff
        ) {
            use std::fmt::Write;
            let _ = write!(out, "<U+{n:04X}>");
        } else {
            out.push(c);
        }
    }
    out
}

fn compact_json(value: &Value) -> String {
    // serde_json's default map representation is ordered in this crate, as is
    // Foundation's `.sortedKeys` serialization used by the Swift host.
    serde_json::to_string(value).unwrap_or_default()
}

fn shell_quoted(word: &str) -> String {
    let plain = !word.is_empty()
        && word.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:,+@%".contains(c));
    if plain { word.to_owned() } else { format!("'{}'", word.replace('\'', "'\\''")) }
}

pub fn shown_command(value: Option<&Value>) -> Option<String> {
    let value = value?;
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Array(parts) if parts.iter().all(Value::is_string) => Some(
            parts
                .iter()
                .map(|part| shell_quoted(part.as_str().unwrap_or_default()))
                .collect::<Vec<_>>()
                .join(" "),
        ),
        _ => Some(compact_json(value)),
    }
}

pub fn cut(text: &str, limit: usize) -> String {
    if text.graphemes(true).count() <= limit {
        return text.to_owned();
    }
    if limit == 0 {
        return String::new();
    }
    let mut out: String = text.graphemes(true).take(limit - 1).collect();
    out.push('…');
    out
}

pub fn input_summary(input: &Map<String, Value>) -> Option<Value> {
    let env = input.iter().find(|(key, _)| key.eq_ignore_ascii_case("env"));
    let mut truncated = env.is_some_and(|(_, value)| !value.as_object().is_some_and(Map::is_empty));
    let mut shown: Vec<(&String, &Value)> = input
        .iter()
        .filter(|(key, _)| !key.eq_ignore_ascii_case("env") && key.as_str() != "command")
        .collect();
    shown.sort_by(|(a, _), (b, _)| {
        (a.as_str() != "cwd", a.as_str()).cmp(&(b.as_str() != "cwd", b.as_str()))
    });
    if shown.len() > 8 {
        truncated = true;
    }

    let mut fields = Map::new();
    for (key, value) in shown.iter().take(8) {
        let raw = value.as_str().map(str::to_owned).unwrap_or_else(|| compact_json(value));
        let scrubbed = scrub(&raw, false);
        if scrubbed != raw {
            truncated = true;
        }
        let text = visible(&scrubbed);
        if key.graphemes(true).count() > 40 || text.graphemes(true).count() > 200 {
            truncated = true;
        }
        fields.insert(cut(&visible(key), 40), Value::String(cut(&text, 200)));
    }
    if fields.len() < shown.len().min(8) {
        truncated = true;
    }
    if fields.is_empty() && !truncated {
        None
    } else {
        Some(json!({"fields": fields, "truncated": truncated}))
    }
}

fn option_id(offered: &[Value], kinds: &[&str]) -> Option<String> {
    // Swift's [[String: Any]] cast rejects the entire list when any entry
    // is not an object. Never recover an allow from a malformed list.
    if !offered.iter().all(Value::is_object) {
        return None;
    }
    for kind in kinds {
        let matches: Vec<&Map<String, Value>> = offered
            .iter()
            .filter_map(Value::as_object)
            .filter(|option| option.get("kind").and_then(Value::as_str) == Some(kind))
            .collect();
        if matches.len() == 1 {
            if let Some(id) = matches[0].get("optionId").and_then(Value::as_str) {
                return Some(id.to_owned());
            }
        }
    }
    None
}

pub fn once_option(allow: bool, offered: &[Value]) -> Option<String> {
    option_id(offered, &[if allow { "allow_once" } else { "reject_once" }])
}

pub fn always_option(offered: &[Value]) -> Option<String> {
    option_id(offered, &["allow_always"])
}

pub fn option(allow: bool, offered: &[Value]) -> Option<String> {
    if allow {
        option_id(offered, &["allow_once"])
    } else {
        option_id(offered, &["reject_once", "reject_always"])
    }
}

fn request_tool(request: &Map<String, Value>) -> Option<&Map<String, Value>> {
    request.get("toolCall").and_then(Value::as_object)
}

pub fn question(request: &Map<String, Value>) -> Option<&Map<String, Value>> {
    request_tool(request)
        .and_then(|tool| tool.get("_meta"))
        .and_then(Value::as_object)
        .and_then(|meta| meta.get("acpmux"))
        .and_then(Value::as_object)
        .and_then(|acpmux| acpmux.get("question"))
        .and_then(Value::as_object)
}

pub fn is_question(request: &Map<String, Value>) -> bool {
    let Some(tool) = request_tool(request) else { return false };
    let Some(meta) = tool.get("_meta").and_then(Value::as_object) else { return false };
    meta.get("acpmux")
        .and_then(Value::as_object)
        .and_then(|acpmux| acpmux.get("question"))
        .is_some()
        || meta
            .get("claude")
            .and_then(Value::as_object)
            .and_then(|claude| claude.get("tool"))
            .and_then(Value::as_str)
            == Some("AskUserQuestion")
}

pub fn is_tool_permission(request: &Map<String, Value>) -> bool {
    let offered =
        request.get("options").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
    !is_question(request) && option(true, offered).is_some() && option(false, offered).is_some()
}

pub fn summary(request: &Map<String, Value>) -> String {
    let Some(call) = request_tool(request) else { return String::new() };
    let input = call.get("rawInput").and_then(Value::as_object);
    let mut lines = Vec::new();
    if let Some(title) = call.get("title").and_then(Value::as_str) {
        let line = visible(&scrub(title, false)).trim().to_owned();
        if !line.is_empty() {
            lines.push(line);
        }
    }
    if let Some(command) = input.and_then(|input| shown_command(input.get("command"))) {
        let line = visible(&scrub(&command, false)).trim().to_owned();
        if !line.is_empty() {
            lines.push(line);
        }
    }
    if lines.len() == 2 && lines[0] == lines[1] {
        lines.truncate(1);
    }
    cut(&lines.join("\n"), 300)
}

pub fn read(request: &Value) -> Option<Value> {
    let request = request.as_object()?;
    let question = question(request).cloned().map(Value::Object);
    Some(json!({
        "question": question,
        "is_question": is_question(request),
        "is_tool_permission": is_tool_permission(request),
        "summary": summary(request),
    }))
}

#[cfg(test)]
#[path = "prompt_tests.rs"]
mod tests;
