//! Claude Code's terminal look (as of v2.1.310, 256-color, dark theme) drawn from acpmux
//! records.
//!
//! What the records hold, and so what this draws: the person's prompts, the assistant's answer
//! text, and, when the records carry them (a chat seeded from the transcript; a View Only chat's
//! live records do not), each tool call's input and result. What they do not hold, and so what
//! this draws from [`Chrome`] or not at all: the banner (version, model, plan), the permission
//! mode and effort in the footer, the person's unsent draft, the spinner's verb, timer and token
//! count, the turn's own duration, permission dialogs, tips, menus and notices.
//!
//! Layout, from the real screen (`tests/parity.rs`): the banner, then each item after a blank
//! line, then the input box (a blank line, a rule, the draft, a rule, the footer). A transcript
//! taller than the screen shows its bottom rows, as Ink's main-screen output scrolls.

use serde_json::Value;

use crate::{BOLD, Cell, FAINT, Grid, INVERSE, Line, Style, wrap};

/// Claude Code's colors (256-color indexes, dark theme).
const GRAY: u8 = 246;
const RULE: u8 = 244;
const CLAUDE: u8 = 174;
const TEXT: u8 = 231;
const OK: u8 = 114;
const ERROR: u8 = 167;
const PROMPT_BG: u8 = 237;
const CODE: u8 = 153;
const DEL_FG: u8 = 167;
const DEL_BG: u8 = 52;
const ADD_FG: u8 = 77;
const ADD_BG: u8 = 22;
const ADD_WORD_BG: u8 = 28;
const SYN_CALL: u8 = 148;
const SYN_STRING: u8 = 186;

/// What the phone knows beside the records: the session's facts, the person's own draft.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Chrome {
    /// Claude Code's version: the banner is drawn only with it.
    pub version: Option<String>,
    /// The banner's model and plan line, e.g. `Opus 5.5 · API Usage Billing`.
    pub model_line: Option<String>,
    /// The session's folder: the banner's third line, and what tool paths are shown relative to.
    pub cwd: Option<String>,
    /// The footer's permission mode, e.g. `manual mode on`.
    pub mode: String,
    /// The footer's effort, e.g. `medium`.
    pub effort: Option<String>,
    /// Text typed into the prompt and not sent.
    pub draft: String,
    /// Minutes east of UTC, for the time a turn ended.
    pub utc_offset_minutes: i32,
}

/// One tool call, as its `tool_call` and `tool_call_update` records say.
#[derive(Debug, Clone, PartialEq)]
struct Tool {
    id: String,
    name: String,
    input: Value,
    /// None until a `tool_call_update` with a final status settles it.
    settled: Option<Settled>,
}

#[derive(Debug, Clone, PartialEq)]
struct Settled {
    failed: bool,
    text: String,
}

#[derive(Debug, Clone, PartialEq)]
enum Item {
    Prompt(String),
    Answer(String),
    Tool(Tool),
    /// A finished turn: when it started and ended (ms since the epoch), when recorded.
    Done {
        started: Option<u64>,
        ended: Option<u64>,
    },
}

fn text_at<'a>(v: &'a Value, path: &str) -> Option<&'a str> {
    v.pointer(path).and_then(Value::as_str)
}

/// The transcript the records describe, and whether a turn is still running.
fn items(records: &[Value]) -> (Vec<Item>, bool) {
    let mut items: Vec<Item> = Vec::new();
    let mut started: Option<u64> = None;
    let mut running = false;
    for record in records {
        let kind = text_at(record, "/kind").unwrap_or_default();
        let at = record.get("at").and_then(Value::as_u64);
        let update = record.pointer("/msg/params/update").unwrap_or(&Value::Null);
        match kind {
            "turn_started" => {
                started = at;
                running = true;
            }
            "turn_end" => {
                items.push(Item::Done { started: started.take(), ended: at });
                running = false;
            }
            "user_message" => {
                if let Some(text) = text_at(record, "/msg/text") {
                    items.push(Item::Prompt(text.to_owned()));
                }
            }
            "agent_message_chunk" => {
                let text = text_at(update, "/content/text").unwrap_or_default();
                // A watched chat joins the pieces of one answer with a blank line; Claude Code
                // draws each piece as its own message.
                let (fresh, text) = match text.strip_prefix("\n\n") {
                    Some(rest) => (true, rest),
                    None => (false, text),
                };
                match items.last_mut() {
                    Some(Item::Answer(answer)) if !fresh => answer.push_str(text),
                    _ => items.push(Item::Answer(text.to_owned())),
                }
            }
            "tool_call" => {
                let id = text_at(update, "/toolCallId").unwrap_or_default().to_owned();
                let name = text_at(update, "/_meta/claude/tool")
                    .or_else(|| text_at(update, "/title"))
                    .unwrap_or_default()
                    .to_owned();
                let input = update.get("rawInput").cloned().unwrap_or(Value::Null);
                items.push(Item::Tool(Tool { id, name, input, settled: None }));
            }
            "tool_call_update" => {
                let id = text_at(update, "/toolCallId").unwrap_or_default();
                let status = text_at(update, "/status").unwrap_or_default();
                if !matches!(status, "completed" | "failed") {
                    continue;
                }
                let text = update
                    .get("content")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|c| text_at(c, "/content/text"))
                    .collect::<Vec<_>>()
                    .join("\n");
                for item in items.iter_mut().rev() {
                    if let Item::Tool(tool) = item
                        && tool.id == id
                    {
                        tool.settled = Some(Settled { failed: status == "failed", text });
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    (items, running)
}

/// Draws Claude Code's screen for `records` (acpmux log records: `{kind, msg, at}`) on a
/// `cols` x `rows` terminal.
pub fn render(records: &[Value], chrome: &Chrome, cols: u16, rows: u16) -> Grid {
    let width = usize::from(cols);
    let (items, running) = items(records);
    let mut lines: Vec<Line> = Vec::new();
    if let Some(version) = &chrome.version {
        banner(&mut lines, version, chrome);
        lines.push(Line::new());
    }
    for item in &items {
        lines.push(Line::new());
        match item {
            Item::Prompt(text) => prompt(&mut lines, text, width),
            Item::Answer(text) => answer(&mut lines, text, width),
            Item::Tool(tool) => tool_lines(&mut lines, tool, chrome, width),
            Item::Done { started, ended } => done(&mut lines, *started, *ended, chrome),
        }
    }
    if running {
        lines.push(Line::new());
        let mut l = Line::new();
        l.push("✻", Style::fg(CLAUDE)).push(" ", Style::PLAIN).push("Working…", Style::fg(CLAUDE));
        lines.push(l);
    }
    input_box(&mut lines, chrome, running, width);
    let skip = lines.len().saturating_sub(usize::from(rows));
    let mut grid = Grid::blank(cols, rows);
    for (slot, line) in grid.cells.iter_mut().zip(lines.into_iter().skip(skip)) {
        *slot = line.into_row(width);
    }
    grid
}

fn banner(lines: &mut Vec<Line>, version: &str, chrome: &Chrome) {
    let logo = Style::fg(CLAUDE);
    let mut l = Line::new();
    l.push(" ▐", logo).push("▛███▛█", logo.on(16)).push("   ", Style::PLAIN);
    l.push("Claude", Style::PLAIN.with(BOLD)).push(" ", Style::PLAIN);
    l.push("Code", Style::PLAIN.with(BOLD)).push(" ", Style::PLAIN);
    l.push(&format!("v{version}"), Style::fg(GRAY));
    lines.push(l);
    let mut l = Line::new();
    l.push("▝▜", logo).push("█████", logo.on(16)).push("█▀", logo).push("  ", Style::PLAIN);
    l.push(chrome.model_line.as_deref().unwrap_or_default(), Style::fg(GRAY));
    lines.push(l);
    let mut l = Line::new();
    l.push(" ▝▝", logo).push("   ", Style::PLAIN).push("▝▝", logo).push("   ", Style::PLAIN);
    l.push(chrome.cwd.as_deref().unwrap_or_default(), Style::fg(GRAY));
    lines.push(l);
}

fn prompt(lines: &mut Vec<Line>, text: &str, width: usize) {
    let bg = Style::fg(GRAY).on(PROMPT_BG);
    for (i, row) in wrap(text, width.saturating_sub(2)).iter().enumerate() {
        let mut l = Line::new();
        l.push(if i == 0 { "❯ " } else { "  " }, bg).push(row, Style::fg(TEXT).on(PROMPT_BG));
        // The prompt's background runs the full width.
        l.pad_to(width, Style::fg(TEXT).on(PROMPT_BG));
        lines.push(l);
    }
}

/// Answer text: `code` spans in their color without the backticks, `**bold**` bold.
fn answer(lines: &mut Vec<Line>, text: &str, width: usize) {
    let mut first = true;
    for para in text.trim_end().split('\n') {
        let (plain, styles) = markdown_inline(para);
        let mut offset = 0;
        for row in wrap(&plain, width.saturating_sub(2)) {
            let mut l = Line::new();
            if first {
                l.push("●", Style::fg(TEXT)).push(" ", Style::PLAIN);
                first = false;
            } else {
                l.push("  ", Style::PLAIN);
            }
            for c in row.chars() {
                let style = styles.get(offset).copied().unwrap_or(Style::PLAIN);
                l.push(&c.to_string(), style);
                offset += 1;
            }
            lines.push(l);
            // The space the wrap dropped at the break.
            while plain.chars().nth(offset) == Some(' ') && !row.ends_with(' ') {
                offset += 1;
            }
        }
    }
}

/// `text` without inline markdown marks, and each kept character's style.
fn markdown_inline(text: &str) -> (String, Vec<Style>) {
    let mut out = String::new();
    let mut styles = Vec::new();
    let mut code = false;
    let mut bold = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '`' {
            code = !code;
            continue;
        }
        if !code && c == '*' && chars.peek() == Some(&'*') {
            chars.next();
            bold = !bold;
            continue;
        }
        out.push(c);
        styles.push(match (code, bold) {
            (true, _) => Style::fg(CODE),
            (false, true) => Style::PLAIN.with(BOLD),
            _ => Style::PLAIN,
        });
    }
    (out, styles)
}

fn tool_label(name: &str) -> &str {
    match name {
        "Edit" | "MultiEdit" => "Update",
        other => other,
    }
}

fn relative<'a>(path: &'a str, cwd: Option<&str>) -> &'a str {
    cwd.and_then(|cwd| path.strip_prefix(cwd))
        .and_then(|rest| rest.strip_prefix('/'))
        .unwrap_or(path)
}

fn result_prefix(l: &mut Line) {
    l.push("  ", Style::PLAIN).push("⎿", Style::fg(GRAY)).push(" \u{a0}", Style::PLAIN);
}

fn tool_lines(lines: &mut Vec<Line>, tool: &Tool, chrome: &Chrome, width: usize) {
    let input = &tool.input;
    let cwd = chrome.cwd.as_deref();
    let path = text_at(input, "/file_path").map(|p| relative(p, cwd)).unwrap_or_default();
    let arg = match tool.name.as_str() {
        "Write" | "Edit" | "MultiEdit" | "Read" | "NotebookEdit" => path.to_owned(),
        "Bash" => text_at(input, "/command")
            .unwrap_or_default()
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned(),
        "Grep" | "Glob" => text_at(input, "/pattern").unwrap_or_default().to_owned(),
        _ => String::new(),
    };
    let dot = match &tool.settled {
        Some(Settled { failed: false, .. }) => Style::fg(OK),
        Some(Settled { failed: true, .. }) => Style::fg(ERROR),
        None => Style::fg(GRAY),
    };
    let mut l = Line::new();
    l.push("●", dot).push(" ", Style::PLAIN);
    l.push(tool_label(&tool.name), Style::PLAIN.with(BOLD));
    l.push("(", Style::PLAIN).push(&arg, Style::PLAIN).push(")", Style::PLAIN);
    lines.push(l);
    let Some(settled) = &tool.settled else {
        let mut l = Line::new();
        result_prefix(&mut l);
        l.push("Waiting…", Style::fg(GRAY));
        lines.push(l);
        return;
    };
    // A call with no result yet: adopting logs it failed until its result comes, so one with
    // no text is still waiting (on a permission, or running).
    if settled.failed && settled.text.trim().is_empty() {
        let mut l = Line::new();
        result_prefix(&mut l);
        l.push("Waiting…", Style::fg(GRAY));
        lines.push(l);
        return;
    }
    if settled.failed {
        let mut l = Line::new();
        result_prefix(&mut l);
        l.push(settled.text.lines().next().unwrap_or("Error"), Style::fg(ERROR));
        lines.push(l);
        return;
    }
    match tool.name.as_str() {
        "Write" => {
            let content = text_at(input, "/content").unwrap_or_default();
            let code: Vec<&str> = content.lines().collect();
            let mut l = Line::new();
            result_prefix(&mut l);
            l.push("Wrote ", Style::PLAIN).push(&code.len().to_string(), Style::PLAIN.with(BOLD));
            l.push(if code.len() == 1 { " line to " } else { " lines to " }, Style::PLAIN);
            l.push(path, Style::PLAIN.with(BOLD));
            lines.push(l);
            let digits = code.len().max(1).to_string().len() + 1;
            for (i, row) in code.iter().take(10).enumerate() {
                let mut l = Line::new();
                l.push("     ", Style::PLAIN);
                l.push(&format!("{:>digits$}", i + 1), Style::fg(TEXT).with(FAINT));
                l.push(" ", Style::PLAIN);
                highlight(&mut l, row, Color8::None);
                lines.push(l);
            }
        }
        "Edit" | "MultiEdit" => edit_lines(lines, input, width),
        _ => {
            let text = if settled.text.trim().is_empty() {
                "(No output)"
            } else {
                settled.text.trim_end()
            };
            let all: Vec<&str> = text.lines().collect();
            for (i, row) in all.iter().take(3).enumerate() {
                let mut l = Line::new();
                if i == 0 {
                    result_prefix(&mut l);
                } else {
                    l.push("     ", Style::PLAIN);
                }
                l.push(row, Style::PLAIN);
                lines.push(l);
            }
            if all.len() > 3 {
                let mut l = Line::new();
                l.push("     ", Style::PLAIN);
                l.push(&format!("… +{} lines (ctrl+o to expand)", all.len() - 3), Style::fg(GRAY));
                lines.push(l);
            }
        }
    }
}

/// The background a highlighted code row sits on.
#[derive(Clone, Copy)]
enum Color8 {
    None,
    On(u8),
}

/// A code row in Claude Code's dark syntax colors, roughly: string literals and called names
/// colored, the rest in the text color. Claude Code highlights with a real grammar per
/// language; the parity test counts every cell this gets wrong.
fn highlight(l: &mut Line, code: &str, bg: Color8) {
    let on = |s: Style| match bg {
        Color8::None => s,
        Color8::On(b) => s.on(b),
    };
    let chars: Vec<char> = code.chars().collect();
    let mut i = 0;
    while let Some(&c) = chars.get(i) {
        if c == '"' || c == '\'' {
            let end =
                chars.iter().skip(i + 1).position(|&d| d == c).map_or(chars.len(), |p| i + 2 + p);
            let s: String = chars.get(i..end).unwrap_or_default().iter().collect();
            l.push(&s, on(Style::fg(SYN_STRING)));
            i = end;
        } else if c.is_alphanumeric() || c == '_' {
            let end = chars
                .iter()
                .skip(i)
                .position(|d| !(d.is_alphanumeric() || *d == '_'))
                .map_or(chars.len(), |p| i + p);
            let s: String = chars.get(i..end).unwrap_or_default().iter().collect();
            let called = chars.get(end) == Some(&'(');
            l.push(&s, on(Style::fg(if called { SYN_CALL } else { TEXT })));
            i = end;
        } else {
            l.push(&c.to_string(), on(Style::fg(TEXT)));
            i += 1;
        }
    }
}

/// An edit's summary and diff. The records carry the replaced and new text, not where in the
/// file they are, so the line numbers count from 1 and no context lines show.
fn edit_lines(lines: &mut Vec<Line>, input: &Value, width: usize) {
    let old = text_at(input, "/old_string").unwrap_or_default();
    let new = text_at(input, "/new_string").unwrap_or_default();
    let old_rows: Vec<&str> = old.lines().collect();
    let new_rows: Vec<&str> = new.lines().collect();
    let mut l = Line::new();
    result_prefix(&mut l);
    let (a, r) = (new_rows.len(), old_rows.len());
    if a > 0 {
        l.push("Added ", Style::PLAIN).push(&a.to_string(), Style::PLAIN.with(BOLD));
        l.push(if a == 1 { " line" } else { " lines" }, Style::PLAIN);
    }
    if r > 0 {
        l.push(if a > 0 { ", removed " } else { "Removed " }, Style::PLAIN);
        l.push(&r.to_string(), Style::PLAIN.with(BOLD))
            .push(if r == 1 { " line" } else { " lines" }, Style::PLAIN);
    }
    lines.push(l);
    let row_width = width.saturating_sub(7);
    let digits = old_rows.len().max(new_rows.len()).max(1).to_string().len() + 1;
    for (i, row) in old_rows.iter().enumerate() {
        let mut l = Line::new();
        l.push("     ", Style::PLAIN);
        l.push(&format!("{:>digits$} -", i + 1), Style::fg(DEL_FG).on(DEL_BG));
        l.push(row, Style::fg(TEXT).on(DEL_BG));
        l.pad_to(row_width, Style::fg(TEXT).on(DEL_BG));
        lines.push(l);
    }
    for (i, row) in new_rows.iter().enumerate() {
        let mut l = Line::new();
        l.push("     ", Style::PLAIN);
        l.push(&format!("{:>digits$} +", i + 1), Style::fg(ADD_FG).on(ADD_BG));
        let start = l.width();
        highlight(&mut l, row, Color8::On(ADD_BG));
        // The changed words of a one-for-one line on the brighter green.
        if let Some(old_row) = old_rows.get(i) {
            let (pre, post) = common_ends(old_row, row);
            let len = row.chars().count();
            for x in (start + pre)..(start + len.saturating_sub(post)) {
                if let Some(cell) = l.cells.get_mut(x) {
                    cell.style = cell.style.on(ADD_WORD_BG);
                }
            }
        }
        l.pad_to(row_width, Style::fg(TEXT).on(ADD_BG));
        lines.push(l);
    }
}

/// How many characters `a` and `b` share at the start and, after that, at the end.
/// Word by word, as Claude Code marks changed words: a word is a run of letters, digits and
/// underscores, any other character a word of its own.
fn common_ends(a: &str, b: &str) -> (usize, usize) {
    fn words(s: &str) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let mut in_word = false;
        for c in s.chars() {
            let wordy = c.is_alphanumeric() || c == '_';
            match out.last_mut() {
                Some(last) if wordy && in_word => last.push(c),
                _ => out.push(c.to_string()),
            }
            in_word = wordy;
        }
        out
    }
    let (a, b) = (words(a), words(b));
    let pre = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let max_post = a.len().min(b.len()) - pre;
    let post =
        a.iter().rev().zip(b.iter().rev()).take(max_post).take_while(|(x, y)| x == y).count();
    let chars = |w: &[String]| w.iter().map(|w| w.chars().count()).sum::<usize>();
    (chars(b.get(..pre).unwrap_or_default()), chars(b.get(b.len() - post..).unwrap_or_default()))
}

fn done(lines: &mut Vec<Line>, started: Option<u64>, ended: Option<u64>, chrome: &Chrome) {
    let mut text = String::from("Worked");
    if let (Some(s), Some(e)) = (started, ended) {
        text.push_str(&format!(" for {}s", e.saturating_sub(s) / 1000));
    }
    if let Some(e) = ended {
        let minutes = (e / 60_000) as i64 + i64::from(chrome.utc_offset_minutes);
        let day = minutes.rem_euclid(24 * 60);
        let (h, m) = (day / 60, day % 60);
        let h12 = if h % 12 == 0 { 12 } else { h % 12 };
        text.push_str(&format!(" · done {h12}:{m:02} {}", if h < 12 { "AM" } else { "PM" }));
    }
    let mut l = Line::new();
    l.push("✻", Style::fg(GRAY)).push(" ", Style::PLAIN).push(&text, Style::fg(GRAY));
    lines.push(l);
}

fn input_box(lines: &mut Vec<Line>, chrome: &Chrome, running: bool, width: usize) {
    lines.push(Line::new());
    let rule = "─".repeat(width);
    let mut l = Line::new();
    l.push(&rule, Style::fg(RULE));
    lines.push(l.clone());
    let caret = if running { Style::fg(GRAY) } else { Style::PLAIN };
    let draft = wrap(&chrome.draft, width.saturating_sub(2));
    let last = draft.len().saturating_sub(1);
    for (i, row) in draft.iter().enumerate() {
        let mut d = Line::new();
        if i == 0 {
            d.push("❯", caret).push("\u{a0}", Style::PLAIN);
        } else {
            d.push("  ", Style::PLAIN);
        }
        d.push(row, Style::PLAIN);
        if i == last {
            d.cells.push(Cell { text: " ".to_owned(), style: Style::PLAIN.with(INVERSE) });
        }
        lines.push(d);
    }
    lines.push(l);
    let mut f = Line::new();
    f.push("  ", Style::PLAIN);
    for (i, word) in format!("⏸ {}", chrome.mode).split(' ').enumerate() {
        if i > 0 {
            f.push(" ", Style::PLAIN);
        }
        f.push(word, Style::fg(GRAY));
    }
    let hint = if running {
        "esc to interrupt"
    } else if chrome.draft.is_empty() {
        "? for shortcuts"
    } else {
        ""
    };
    if !hint.is_empty() {
        f.push(" ", Style::PLAIN)
            .push("·", Style::fg(GRAY))
            .push(" ", Style::PLAIN)
            .push(hint, Style::fg(GRAY));
    }
    if let Some(effort) = chrome.effort.as_deref() {
        let right = format!("◐ {effort} · /effort");
        let at = width.saturating_sub(2 + crate::str_width(&right));
        f.pad_to(at, Style::PLAIN);
        for (i, word) in right.split(' ').enumerate() {
            if i > 0 {
                f.push(" ", Style::PLAIN);
            }
            f.push(word, Style::fg(GRAY));
        }
    }
    lines.push(f);
}

#[cfg(test)]
#[path = "claude_tests.rs"]
mod tests;
