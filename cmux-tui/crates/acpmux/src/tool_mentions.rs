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

// Slices without a panic (plans/cmux-next/rust-panic-free.md): every index in this file comes from
// `find`, a char walk or an ASCII count, so it is a char boundary; one that is not reads as "".
fn head_to(s: &str, end: usize) -> &str {
    s.get(..end).unwrap_or("")
}
fn tail_at(s: &str, start: usize) -> &str {
    s.get(start..).unwrap_or("")
}
fn part(s: &str, start: usize, end: usize) -> &str {
    s.get(start..end).unwrap_or("")
}

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
        if !leads(head_to(&prose, at)) {
            continue;
        }
        let rest = tail_at(&prose, at + 1);
        for (i, (name, _)) in TOOLS.iter().enumerate() {
            let Some(head) = rest.get(..name.len()) else { continue };
            if head.eq_ignore_ascii_case(name) && trails(tail_at(rest, name.len())) {
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
    note(&mentioned(&own_text(blocks)))
}

/// The person's own text of `blocks`: every text block that is not a context block, one per line.
pub fn own_text(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter(|b| !crate::prompt_context::is_context(b))
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// `text` without the tools note acpmux made for its own mentions ([`note`] of [`mentioned`] of
/// the rest), with the blank lines before it, wherever it stands: the one text a bridged chat's
/// app was sent joins the person's words and the note (`hub/bridge.rs` `text_of`), and a Codex
/// Desktop transcript keeps it (`hub/watch.rs`). Any other text stays, a `<cmux-…-context>`
/// element the person wrote too.
pub fn without_own_note(text: &str) -> std::borrow::Cow<'_, str> {
    if text.contains(TAG) {
        for set in 1..(1usize << TOOLS.len()) {
            let tools: Vec<&str> = TOOLS
                .iter()
                .enumerate()
                .filter(|(i, _)| set & (1 << i) != 0)
                .map(|(_, (name, _))| *name)
                .collect();
            let Some(note) = note(&tools) else { continue };
            let joined = format!("\n\n{note}");
            // Only the generated copy: the last one outside code. A copy the person pasted in a
            // fenced block or a code span is their text and stays.
            let mut end = text.len();
            while let Some(at) = head_to(text, end).rfind(&joined) {
                let through = head_to(text, at + joined.len());
                if without_code(through).trim_end().ends_with("</cmux-tools-context>") {
                    let rest = format!("{}{}", head_to(text, at), tail_at(text, at + joined.len()));
                    if mentioned(&rest) == tools {
                        return std::borrow::Cow::Owned(rest);
                    }
                    break;
                }
                end = at;
            }
        }
    }
    std::borrow::Cow::Borrowed(text)
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
/// opening mark (a bracket, a straight or typographic quote), then any Markdown emphasis. A block
/// quote's or list item's marker is blanked before this reads it (`without_code`), so
/// `>@computer-use` starts after a space.
fn leads(before: &str) -> bool {
    let before = before.trim_end_matches(['*', '_', '~']);
    match before.chars().next_back() {
        None => true,
        Some(ch) => {
            is_space(ch)
                || matches!(ch, '\u{FFFC}' | '(' | '[' | '"' | '\'' | '\u{201C}' | '\u{2018}')
        }
    }
}

/// Whether a mention may end before `after`: any Markdown emphasis, then the end, a space, an
/// attachment, a closing mark (a straight or typographic quote too), or a full stop that ends a
/// sentence: the end, a space or a closing mark after it (`(@computer-use.)`; `@computer-use.md`
/// is a file).
fn trails(after: &str) -> bool {
    let after = after.trim_start_matches(['*', '_', '~']);
    let mut chars = after.chars();
    match chars.next() {
        None => true,
        Some('.') => chars.next().is_none_or(|ch| is_space(ch) || closing(ch)),
        Some(ch) => {
            is_space(ch) || matches!(ch, '\u{FFFC}' | ',' | ';' | ':' | '!' | '?') || closing(ch)
        }
    }
}

/// A closing bracket or a straight or typographic closing quote.
fn closing(ch: char) -> bool {
    matches!(ch, ')' | ']' | '"' | '\'' | '\u{201D}' | '\u{2019}')
}

/// `text` as prose: each line's container markers (`>`, a list item's marker and indent) and its
/// fenced code blanked, then the inline code spans of each paragraph, which a container's markers
/// never end (`> run \`a` then `> b\` now` is one span). Line breaks are kept and tabs read as
/// spaces (`expand_tabs`); only the mentions in it are read.
fn without_code(text: &str) -> String {
    let mut prose = String::with_capacity(text.len());
    let mut breaks = Vec::new();
    let mut scan = Fences::default();
    for (i, line) in text.split('\n').enumerate() {
        if i > 0 {
            prose.push('\n');
        }
        let wide = expand_tabs(line);
        let read = scan.read(&wide);
        if i > 0 && !read.continues {
            breaks.push(prose.len());
        }
        if read.code {
            prose.push_str(&blanked(&wide));
        } else {
            prose.push_str(&blanked(head_to(&wide, read.start)));
            prose.push_str(tail_at(&wide, read.start));
        }
    }
    let spans = code_spans(&prose, &breaks);
    if spans.is_empty() {
        return prose;
    }
    let mut out = String::with_capacity(prose.len());
    let mut at = 0;
    for (start, end) in spans {
        out.push_str(part(&prose, at, start));
        out.push_str(&blanked(part(&prose, start, end)));
        at = end;
    }
    out.push_str(tail_at(&prose, at));
    out
}

/// Each character of `text` as a space, line breaks kept.
fn blanked(text: &str) -> String {
    text.chars().map(|c| if c == '\n' { '\n' } else { ' ' }).collect()
}

/// The fenced code blocks of a text, line by line, as CommonMark reads them inside its containers
/// (toolMentions.ts `withoutCode` keeps the same rules). A block quote (`>`) holds a line that
/// carries its marker; a list item (`-`, `*`, `+`, `1.`, `1)`) holds a blank line and one indented
/// to its content. A fence opened in a container ends with it: lazy continuation is only for a
/// paragraph, so `> ~~~` then a line without `>` is prose again. Inside its container, a fence
/// closes at a line of its mark at least as long, indented at most three spaces. Tabs count to
/// the next multiple of four columns. It also says where each line's content starts after its
/// container markers, and whether the line goes on with the paragraph before it, which is where
/// an inline code span may run on.
#[derive(Default)]
struct Fences {
    /// The open containers, outermost first: `None` a block quote, `Some(n)` a list item whose
    /// content starts `n` columns into its parent's.
    open: Vec<Option<usize>>,
    /// The open fence's mark and length (it sits in every open container).
    fence: Option<(u8, usize)>,
    /// The last line was paragraph text, which a lazy line continues.
    paragraph: bool,
}

/// One line as [`Fences::read`] read it.
struct Line {
    /// The line is a fenced block's (its opening, content or closing).
    code: bool,
    /// Where its content starts, after its container markers (bytes into the line it read).
    start: usize,
    /// It goes on with the paragraph of the line before (no blank line, block start, new or
    /// closed container between them).
    continues: bool,
}

impl Fences {
    /// Reads the next line, its tabs expanded.
    fn read(&mut self, wide: &str) -> Line {
        let (matched, rest) = match_open(&self.open, wide);
        let start = |rest: &str| wide.len() - rest.len();
        if let Some((mark, length)) = self.fence {
            if matched == self.open.len() {
                if closes(rest, mark, length) {
                    self.fence = None;
                }
                return Line { code: true, start: start(rest), continues: false };
            }
            // Its container ended, so the fence did too.
            self.fence = None;
            self.paragraph = false;
        }
        let closed = matched < self.open.len();
        if closed {
            if self.paragraph && !blank(rest) && !starts_block(rest) {
                // A lazy line goes on with the paragraph.
                return Line { code: false, start: start(rest), continues: true };
            }
            self.open.truncate(matched);
        }
        let before = self.open.len();
        let rest = open_new(&mut self.open, rest);
        if let Some(fence) = opens(rest) {
            self.fence = Some(fence);
            self.paragraph = false;
            return Line { code: true, start: start(rest), continues: false };
        }
        let continues = self.paragraph
            && !closed
            && self.open.len() == before
            && !blank(rest)
            && !starts_block(rest);
        self.paragraph = !blank(rest) && !heading(rest) && !thematic_break(rest);
        Line { code: false, start: start(rest), continues }
    }
}

/// `line` with each tab as the spaces to the next multiple of four columns.
fn expand_tabs(line: &str) -> std::borrow::Cow<'_, str> {
    if !line.contains('\t') {
        return std::borrow::Cow::Borrowed(line);
    }
    let mut out = String::with_capacity(line.len() + 8);
    let mut column = 0;
    for ch in line.chars() {
        if ch == '\t' {
            let n = 4 - column % 4;
            out.extend(std::iter::repeat_n(' ', n));
            column += n;
        } else {
            out.push(ch);
            column += 1;
        }
    }
    std::borrow::Cow::Owned(out)
}

/// Whether `s` holds only spaces (and a line's `\r`).
fn blank(s: &str) -> bool {
    s.bytes().all(|b| b == b' ' || b == b'\r')
}

fn spaces(s: &str) -> usize {
    s.len() - s.trim_start_matches(' ').len()
}

/// How many of `open` `line` continues, and the rest of it after their markers and indents.
fn match_open<'a>(open: &[Option<usize>], line: &'a str) -> (usize, &'a str) {
    let mut rest = line;
    for (i, container) in open.iter().enumerate() {
        match container {
            None => {
                let n = spaces(rest);
                if n > 3 || !tail_at(rest, n).starts_with('>') {
                    return (i, rest);
                }
                rest = tail_at(rest, n + 1);
                rest = rest.strip_prefix(' ').unwrap_or(rest);
            }
            Some(indent) => {
                if blank(rest) {
                    continue;
                }
                if spaces(rest) < *indent {
                    return (i, rest);
                }
                rest = tail_at(rest, *indent);
            }
        }
    }
    (open.len(), rest)
}

/// The length of the list marker `s` starts with (`-`, `*`, `+`, or 1 to 9 digits then `.` or
/// `)`), when a space or the line's end follows it.
fn list_marker(s: &str) -> Option<usize> {
    let bytes = s.as_bytes();
    let length = match bytes.first()? {
        b'-' | b'*' | b'+' => 1,
        b'0'..=b'9' => {
            let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
            if digits > 9 || !matches!(bytes.get(digits), Some(b'.' | b')')) {
                return None;
            }
            digits + 1
        }
        _ => return None,
    };
    (blank(tail_at(s, length)) || tail_at(s, length).starts_with(' ')).then_some(length)
}

/// Opens the block quotes and list items `rest` starts with, and gives what follows them.
fn open_new<'a>(open: &mut Vec<Option<usize>>, mut rest: &'a str) -> &'a str {
    loop {
        let n = spaces(rest);
        if n > 3 {
            return rest;
        }
        let after = tail_at(rest, n);
        if let Some(inner) = after.strip_prefix('>') {
            open.push(None);
            rest = inner.strip_prefix(' ').unwrap_or(inner);
            continue;
        }
        // `* * *` is a thematic break, no list item.
        if thematic_break(rest) {
            return rest;
        }
        let Some(marker) = list_marker(after) else { return rest };
        let content = tail_at(after, marker);
        if blank(content) {
            open.push(Some(n + marker + 1));
            return content;
        }
        // Five or more spaces after the marker start indented code: the content is one in.
        let gap = match spaces(content) {
            gap if gap >= 5 => 1,
            gap => gap,
        };
        open.push(Some(n + marker + gap));
        rest = tail_at(content, gap);
    }
}

/// The fence `rest` opens: at most three spaces, then 3+ backticks or tildes, as its mark and
/// length (a backtick fence's info has no backtick).
fn opens(rest: &str) -> Option<(u8, usize)> {
    let n = spaces(rest);
    if n > 3 {
        return None;
    }
    let after = tail_at(rest, n);
    let mark = *after.as_bytes().first().filter(|b| **b == b'`' || **b == b'~')?;
    let length = after.bytes().take_while(|b| *b == mark).count();
    (length >= 3 && !(mark == b'`' && tail_at(after, length).contains('`')))
        .then_some((mark, length))
}

/// Whether `rest` closes the fence of `mark` and `length`.
fn closes(rest: &str, mark: u8, length: usize) -> bool {
    let n = spaces(rest);
    if n > 3 {
        return false;
    }
    let after = tail_at(rest, n);
    let run = after.bytes().take_while(|b| *b == mark).count();
    run >= length && blank(tail_at(after, run))
}

/// Whether `rest` starts a block, so it is no lazy line of a paragraph: a block quote, a list
/// item, a fence, a heading or a thematic break.
fn starts_block(rest: &str) -> bool {
    let n = spaces(rest);
    if n > 3 {
        return false;
    }
    let after = tail_at(rest, n);
    after.starts_with('>')
        || list_marker(after).is_some()
        || opens(rest).is_some()
        || heading(rest)
        || thematic_break(rest)
}

/// Whether `rest` is a thematic break: at most three spaces, then 3+ of one of `-`, `*`, `_`,
/// with spaces between them allowed. It ends a paragraph (under one, `---` underlines a heading,
/// which ends it too), so an inline code span never runs across it.
fn thematic_break(rest: &str) -> bool {
    let n = spaces(rest);
    if n > 3 {
        return false;
    }
    let after = tail_at(rest, n).trim_end_matches([' ', '\r']);
    let Some(mark) = after.bytes().next().filter(|b| matches!(b, b'-' | b'*' | b'_')) else {
        return false;
    };
    after.bytes().all(|b| b == mark || b == b' ')
        && after.bytes().filter(|b| *b == mark).count() >= 3
}

/// Whether `rest` is an ATX heading: at most three spaces, 1 to 6 `#`, then a space or the end.
fn heading(rest: &str) -> bool {
    let n = spaces(rest);
    if n > 3 {
        return false;
    }
    let after = tail_at(rest, n);
    let hashes = after.bytes().take_while(|b| *b == b'#').count();
    (1..=6).contains(&hashes)
        && (blank(tail_at(after, hashes)) || tail_at(after, hashes).starts_with(' '))
}

/// The inline code spans of `text` (CommonMark: a backtick run, then the next run of exactly as
/// many before the paragraph ends at one of `breaks`, the starts of the lines that end one), as
/// byte ranges (slashCommands.ts `codeSpans`).
fn code_spans(text: &str, breaks: &[usize]) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    if !text.contains('`') {
        return spans;
    }
    let bytes = text.as_bytes();
    let mut unclosed = std::collections::HashSet::new();
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] != b'`' {
            at += 1;
            continue;
        }
        match code_span_at(bytes, at, &mut unclosed, breaks) {
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
    fn tool_mention_own_note_goes_from_a_transcript_and_nothing_else() {
        let cu = note(&["computer-use"]).unwrap();
        let both = note(&["computer-use", "browser-use"]).unwrap();
        // At the end, or followed by other text (a reply hint).
        assert_eq!(
            without_own_note(&format!("open Notes with @computer-use\n\n{cu}")),
            "open Notes with @computer-use"
        );
        assert_eq!(
            without_own_note(&format!(
                "use @browser-use and @computer-use\n\n{both}\n\nReply in one line."
            )),
            "use @browser-use and @computer-use\n\nReply in one line."
        );
        // A person's own context-shaped example stays, with the note after it gone.
        let example = "show me @computer-use with\n\n<cmux-foo-context>\nx\n</cmux-foo-context>";
        assert_eq!(without_own_note(example), example);
        assert_eq!(without_own_note(&format!("{example}\n\n{cu}")), example);
        // A note that is not the one the words make, or with no blank line before it, stays.
        let other = format!("open Notes with @browser-use\n\n{cu}");
        assert_eq!(without_own_note(&other), other);
        let no_mention = format!("plain words\n\n{cu}");
        assert_eq!(without_own_note(&no_mention), no_mention);
        let glued = format!("use @computer-use {cu}");
        assert_eq!(without_own_note(&glued), glued);
        assert_eq!(without_own_note("plain words"), "plain words");
    }

    #[test]
    fn tool_mention_scan_stays_linear_on_unclosed_backticks() {
        let text = format!("{} @computer-use", "`a ".repeat(50_000));
        assert_eq!(mentioned(&text), ["computer-use"]);
    }
}

#[cfg(test)]
mod own_note_tests {
    use super::*;

    /// A copy of the note the person pasted in a fenced example stays; the generated one goes.
    #[test]
    fn a_fenced_copy_of_the_note_stays_and_the_generated_one_goes() {
        let note = note(&["browser-use"]).unwrap();
        let typed = format!("use @browser-use\n\n```\n\n{note}\n```");
        let delivered = format!("{typed}\n\n{note}");
        assert_eq!(without_own_note(&delivered), typed);
        assert_eq!(without_own_note(&typed), typed, "nothing generated to strip");
    }
}
// clippy-195 probe
