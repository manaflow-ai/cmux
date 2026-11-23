//! The composer's built-in `@` tools (CMUX-682): a person who writes `@computer-use` or
//! `@browser-use` asks the agent to use cmux's own tool for it. acpmux reads the mention from the
//! person's visible words where a prompt arrives (`session/prompt`, and an edit of a waiting prompt
//! in `hub/queue_edit.rs`) and adds a fixed note for the agent as one hidden context block
//! (`prompt_context.rs`), so every route that carries the words carries the note: the remote wire,
//! a text-only side question, a Sandboxed run and a queue edit, none of which keep a client's
//! context.
//!
//! The rules match the web page's parser (webviews/src/agent-session/acpmux/toolMentions.ts
//! `toolMentionsIn`); `tool_mention_cases.json` is the contract both read. The notes are text for
//! the agent, copied verbatim from that file's `NOTES`.

use serde_json::{Value, json};

/// The element the note is wrapped in (`prompt_context::is_context_text` drops it from a replay).
pub const TAG: &str = "<cmux-tools-context>";

/// The tools, in menu order, with the note each adds.
const TOOLS: [(&str, &str); 2] = [
    (
        "computer-use",
        "The person wrote @computer-use: do this with cmux Computer Use, which drives the apps on this Mac (the cmux-computer-use skill and its tools). Use it for the steps that need an app's own window.",
    ),
    (
        "browser-use",
        "The person wrote @browser-use: do this in the cmux browser (the cmux-browser skill, or `cmux browser` in your shell), not in a separate or headless browser.",
    ),
];

/// The tools `text` names as `@computer-use` / `@browser-use` (or `$computer-use`) outside code,
/// in menu order, each once.
pub fn mentioned(text: &str) -> Vec<&'static str> {
    if !text.contains('@') && !text.contains('$') {
        return Vec::new();
    }
    let prose = without_code(text);
    let mut found = [false; TOOLS.len()];
    for (at, ch) in prose.char_indices() {
        if ch != '@' && ch != '$' {
            continue;
        }
        if !leads(&prose[..at]) {
            continue;
        }
        let rest = &prose[at + 1..];
        for (i, (name, _)) in TOOLS.iter().enumerate() {
            let Some(head) = rest.get(..name.len()) else { continue };
            if head.eq_ignore_ascii_case(name) && trails(&rest[name.len()..]) {
                found[i] = true;
            }
        }
    }
    TOOLS.iter().zip(found).filter(|(_, f)| *f).map(|((name, _), _)| *name).collect()
}

/// The note for `tools`, or `None` when it names none.
pub fn note(tools: &[&str]) -> Option<String> {
    let lines: Vec<&str> =
        TOOLS.iter().filter(|(name, _)| tools.contains(name)).map(|(_, line)| *line).collect();
    if lines.is_empty() {
        return None;
    }
    Some(format!(
        "{TAG}\nThe person did not type this note; do not quote it.\n{}\n</cmux-tools-context>",
        lines.join("\n")
    ))
}

/// The note for the tools the person's own text blocks (every text block that is not a context
/// block) name, or `None`.
pub fn own_note(blocks: &[Value]) -> Option<String> {
    let text = blocks
        .iter()
        .filter(|b| !crate::prompt_context::is_context(b))
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    note(&mentioned(&text))
}

/// Whether context block `block` of `blocks` is only the note their words make: it hides nothing
/// a rebuild from the words loses, so a Retry or a resend still runs the prompt (`prompt_images.rs`
/// `hiddenContext`, [`add_note`] on the rebuilt blocks).
pub fn is_own_note(block: &Value, blocks: &[Value]) -> bool {
    let Some(text) = block.get("text").and_then(Value::as_str) else { return false };
    own_note(blocks).is_some_and(|note| note == text.trim())
}

/// Appends [`own_note`] as one context block, unless a context block already holds a note (a
/// client that sent it through `_meta.acpmux.context`, alone or after its workspace note).
pub fn add_note(blocks: &mut Vec<Value>) {
    if blocks.iter().any(|b| {
        crate::prompt_context::is_context(b)
            && b.get("text").and_then(Value::as_str).is_some_and(|t| t.contains(TAG))
    }) {
        return;
    }
    if let Some(note) = own_note(blocks) {
        blocks.push(json!({"type": "text", "text": note, "_meta": {"acpmux": {"context": true}}}));
    }
}

fn is_space(ch: char) -> bool {
    // JavaScript's `\s`: Unicode's white space and U+FEFF, but not U+0085.
    (ch.is_whitespace() && ch != '\u{85}') || ch == '\u{FEFF}'
}

/// Whether a mention may start after `before`: the start, a space, an attachment (U+FFFC) or an
/// opening mark, then any Markdown emphasis.
fn leads(before: &str) -> bool {
    let before = before.trim_end_matches(['*', '_', '~']);
    match before.chars().next_back() {
        None => true,
        Some(ch) => is_space(ch) || matches!(ch, '\u{FFFC}' | '(' | '[' | '"' | '\''),
    }
}

/// Whether a mention may end before `after`: any Markdown emphasis, then the end, a space, an
/// attachment, a closing mark, or a full stop that ends a sentence (`@computer-use.md` is a file).
fn trails(after: &str) -> bool {
    let after = after.trim_start_matches(['*', '_', '~']);
    let mut chars = after.chars();
    match chars.next() {
        None => true,
        Some('.') => chars.next().is_none_or(is_space),
        Some(ch) => {
            is_space(ch)
                || matches!(ch, '\u{FFFC}' | ',' | ';' | ':' | '!' | '?' | ')' | ']' | '"' | '\'')
        }
    }
}

/// `text` with its code blanked (line breaks kept): fenced blocks, then inline code spans.
fn without_code(text: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    let mut fence: Option<(char, usize)> = None;
    for line in text.split('\n') {
        let run = fence_run(line);
        let blank = match (fence, run) {
            (Some((mark, length)), run) => {
                if let Some((ch, n, rest)) = run
                    && ch == mark
                    && n >= length
                    && rest.trim().is_empty()
                {
                    fence = None;
                }
                true
            }
            (None, Some((ch, n, rest))) if !(ch == '`' && rest.contains('`')) => {
                fence = Some((ch, n));
                true
            }
            (None, _) => false,
        };
        lines.push(if blank { blanked(line) } else { line.to_owned() });
    }
    let fenced = lines.join("\n");
    let spans = code_spans(&fenced);
    if spans.is_empty() {
        return fenced;
    }
    let mut out = String::with_capacity(fenced.len());
    let mut at = 0;
    for (start, end) in spans {
        out.push_str(&fenced[at..start]);
        out.push_str(&blanked(&fenced[start..end]));
        at = end;
    }
    out.push_str(&fenced[at..]);
    out
}

/// Each character of `text` as a space, line breaks kept.
fn blanked(text: &str) -> String {
    text.chars().map(|c| if c == '\n' { '\n' } else { ' ' }).collect()
}

/// A line's fence run: after its indentation (spaces, tabs) and blockquote markers, a run of 3+
/// backticks or tildes, as its mark, its length and the rest of the line.
fn fence_run(line: &str) -> Option<(char, usize, &str)> {
    let content = line.trim_start_matches([' ', '\t', '>']);
    let mark = content.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let length = content.len() - content.trim_start_matches(mark).len();
    (length >= 3).then(|| (mark, length, &content[length..]))
}

/// Whether a line starts a block of its own, which no inline code span crosses: a heading, a
/// quote or a list item (slashCommands.ts `BLOCK_START`).
fn block_start(line: &str) -> bool {
    let spaces = line.len() - line.trim_start_matches(' ').len();
    if spaces > 3 {
        return false;
    }
    let rest = &line[spaces..];
    let spaced = |s: &str| s.is_empty() || s.starts_with([' ', '\t']);
    let hashes = rest.len() - rest.trim_start_matches('#').len();
    if (1..=6).contains(&hashes) && spaced(&rest[hashes..]) {
        return true;
    }
    if rest.starts_with('>') {
        return true;
    }
    if let Some(after) = rest.strip_prefix(['-', '*', '+']) {
        return after.starts_with([' ', '\t']);
    }
    let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    digits > 0
        && rest[digits..]
            .strip_prefix(['.', ')'])
            .is_some_and(|after| after.starts_with([' ', '\t']))
}

/// A fenced code block's opening line as slashCommands.ts `fenceOpening` reads it.
fn fence_opening(line: &str) -> bool {
    let spaces = line.len() - line.trim_start_matches(' ').len();
    if spaces > 3 {
        return false;
    }
    let rest = &line[spaces..];
    let Some(mark) = rest.chars().next().filter(|c| *c == '`' || *c == '~') else {
        return false;
    };
    let length = rest.len() - rest.trim_start_matches(mark).len();
    length >= 3 && !(mark == '`' && rest[length..].contains('`'))
}

/// Where each line that ends a paragraph starts (a blank line, a block start, a fence opening),
/// in order: an inline code span never runs over one (slashCommands.ts `blockBreaks`).
fn block_breaks(text: &str) -> Vec<usize> {
    let bytes = text.as_bytes();
    let mut breaks = Vec::new();
    let mut at = 0;
    loop {
        let mut end = at;
        while end < bytes.len() && bytes[end] != b'\n' && bytes[end] != b'\r' {
            end += 1;
        }
        let content = &text[at..end];
        if at > 0 && (content.trim().is_empty() || block_start(content) || fence_opening(content)) {
            breaks.push(at);
        }
        if end >= bytes.len() {
            break;
        }
        at = if bytes[end] == b'\r' && bytes.get(end + 1) == Some(&b'\n') {
            end + 2
        } else {
            end + 1
        };
    }
    breaks
}

/// The inline code spans of `text` (CommonMark: a backtick run, then the next run of exactly as
/// many before the paragraph ends), as byte ranges (slashCommands.ts `codeSpans`).
fn code_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    if !text.contains('`') {
        return spans;
    }
    let bytes = text.as_bytes();
    let breaks = block_breaks(text);
    let mut unclosed = std::collections::HashSet::new();
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] != b'`' {
            at += 1;
            continue;
        }
        match code_span_at(bytes, at, &mut unclosed, &breaks) {
            Some(end) => {
                spans.push((at, end));
                at = end;
            }
            None => {
                while at < bytes.len() && bytes[at] == b'`' {
                    at += 1;
                }
            }
        }
    }
    spans
}

/// The end of the code span that opens at `at`, or `None` when its run is literal.
fn code_span_at(
    bytes: &[u8],
    at: usize,
    unclosed: &mut std::collections::HashSet<usize>,
    breaks: &[usize],
) -> Option<usize> {
    let mut open = at;
    while open < bytes.len() && bytes[open] == b'`' {
        open += 1;
    }
    let run = open - at;
    if unclosed.contains(&run) {
        return None;
    }
    let mut from = open;
    loop {
        let Some(next) = find_run(bytes, from, run) else {
            unclosed.insert(run);
            return None;
        };
        // A break in `open..=next` ends the paragraph first.
        let first = breaks.partition_point(|b| *b <= open);
        if breaks.get(first).is_some_and(|b| *b <= next) {
            return None;
        }
        let mut stop = next;
        while stop < bytes.len() && bytes[stop] == b'`' {
            stop += 1;
        }
        if stop - next == run && bytes[next - 1] != b'`' {
            return Some(stop);
        }
        from = stop;
    }
}

/// The first index at or after `from` where `run` backticks in a row start.
fn find_run(bytes: &[u8], from: usize, run: usize) -> Option<usize> {
    let mut i = from;
    while i + run <= bytes.len() {
        if bytes[i..i + run].iter().all(|b| *b == b'`') {
            return Some(i);
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_mention_shared_cases_read_as_the_web_page_reads_them() {
        let cases: Vec<Value> =
            serde_json::from_str(include_str!("tool_mention_cases.json")).expect("the cases parse");
        assert!(!cases.is_empty());
        for case in cases {
            let text = case["text"].as_str().expect("a case's text");
            let want: Vec<&str> = case["tools"]
                .as_array()
                .expect("a case's tools")
                .iter()
                .map(|t| t.as_str().expect("a tool"))
                .collect();
            assert_eq!(mentioned(text), want, "{text:?}");
        }
    }

    #[test]
    fn tool_mention_note_names_each_tool_in_menu_order() {
        assert_eq!(note(&[]), None);
        let both = note(&["browser-use", "computer-use"]).unwrap();
        assert!(both.starts_with("<cmux-tools-context>\nThe person did not type this note; do not quote it.\nThe person wrote @computer-use:"), "{both}");
        assert!(both.ends_with("not in a separate or headless browser.\n</cmux-tools-context>"));
        assert!(crate::prompt_context::is_context_text(&both));
    }

    #[test]
    fn tool_mention_note_is_added_once_from_the_persons_words() {
        let mut blocks = vec![json!({"type": "text", "text": "open it with @browser-use"})];
        add_note(&mut blocks);
        assert_eq!(blocks.len(), 2);
        assert!(crate::prompt_context::is_context(&blocks[1]));
        assert!(blocks[1]["text"].as_str().unwrap().contains("@browser-use: do this"));
        // The note's own words name the tool; it is not read as the person's.
        add_note(&mut blocks);
        assert_eq!(blocks.len(), 2);

        // A client's context that already holds it, after its workspace note.
        let combined = format!(
            "<cmux-workspace-context>W</cmux-workspace-context>\n\n{}",
            note(&["browser-use"]).unwrap()
        );
        let mut blocks = vec![
            json!({"type": "text", "text": "open it with @browser-use"}),
            json!({"type": "text", "text": combined, "_meta": {"acpmux": {"context": true}}}),
        ];
        add_note(&mut blocks);
        assert_eq!(blocks.len(), 2);

        let mut blocks = vec![json!({"type": "text", "text": "no tools"})];
        add_note(&mut blocks);
        assert_eq!(blocks.len(), 1);
    }

    #[test]
    fn tool_mention_scan_stays_linear_on_unclosed_backticks() {
        let text = format!("{} @computer-use", "`a ".repeat(50_000));
        assert_eq!(mentioned(&text), ["computer-use"]);
    }
}
