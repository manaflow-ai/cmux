use serde_json::Value;

const TITLE_MAX: usize = 120;

/// `text` up to the first client context element (`<cmux-…-context>`, such as the hidden
/// workspace context of a Cmd-I chat, cx-ihyx2): a harness may store it right after the
/// person's text with no break (Codex), and it is never the person's words.
pub fn without_client_context(text: &str) -> &str {
    let mut from = 0;
    while let Some(at) = text[from..].find("<cmux-").map(|i| i + from) {
        let name = &text[at + 1..];
        if let Some(end) = name.find('>')
            && name[..end].ends_with("-context")
            && !name[..end].contains(char::is_whitespace)
        {
            return &text[..at];
        }
        from = at + 1;
    }
    text
}

/// The first non-empty line of `text` without its client context, trimmed, at most 120
/// characters.
pub fn title_line(text: &str) -> Option<String> {
    let line = without_client_context(text).lines().map(str::trim).find(|line| !line.is_empty())?;
    if line.chars().count() <= TITLE_MAX {
        return Some(line.to_owned());
    }
    let mut cut: String = line.chars().take(TITLE_MAX - 1).collect();
    cut.push('…');
    Some(cut)
}

/// A non-empty string field as a title line.
pub(crate) fn title_field(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).and_then(title_line)
}

/// The typed text of a prompt: a string, or the text parts of a content list.
/// None for tool results and for context a harness injects in `<tags>`.
pub(crate) fn prompt_text(content: &Value) -> Option<String> {
    let text = match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => {
            if parts
                .iter()
                .any(|part| part.get("type").and_then(Value::as_str) == Some("tool_result"))
            {
                return None;
            }
            let texts: Vec<&str> = parts
                .iter()
                .filter(|part| {
                    matches!(
                        part.get("type").and_then(Value::as_str),
                        Some("text" | "input_text") | None
                    )
                })
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect();
            texts.join("\n")
        }
        _ => return None,
    };
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed.starts_with('<') {
        return None;
    }
    title_line(trimmed)
}
