//! What `terminal <t> send` types and what it reads back. Pure.
//!
//! - [`input_bytes`]: the message as a bracketed paste when the terminal
//!   turned paste mode on (`ESC [ ? 2004 h`, which Claude Code, Codex and
//!   shells with line editors do), so a multi-line message stays one message
//!   and no character of it acts as a key binding. Enter goes separately.
//! - [`reply_since`]: the screen lines after the sent message's echo, less
//!   the harness's own input box and status footer. Without the echo (a
//!   harness that shows a paste as a placeholder), the lines after what the
//!   screen showed before the send, else the screen alone: never the turns
//!   that were on the screen before the message.
//!
//! Echo matching ignores whitespace and the Markdown marks a harness renders
//! away (Claude Code draws `` `code` `` as `code`, `**bold**` as bold).

/// Bracketed paste start and end (xterm `?2004`).
const PASTE_START: &str = "\x1b[200~";
const PASTE_END: &str = "\x1b[201~";
/// How many characters of the message (whitespace removed) the end and
/// start anchors use when the full message is not on screen.
const ANCHOR_CHARS: usize = 48;
/// The shortest end of the message an anchor may use.
const MIN_ANCHOR_CHARS: usize = 20;
/// How far from the bottom the footer search looks, in lines.
const FOOTER_LINES: usize = 14;
/// How many lines a turn summary wraps into at most in a narrow pane.
const SUMMARY_LINES: usize = 4;
/// How many of the last non-empty lines of the screen before the send mark
/// where the reply starts when the echo is not found.
const BEFORE_TAIL_LINES: usize = 3;

/// Whether a terminal's VT state (`terminal <t> state read`) has
/// bracketed paste on.
pub(in crate::cli) fn paste_mode_on(state: &[u8]) -> bool {
    let on = b"\x1b[?2004h";
    let off = b"\x1b[?2004l";
    let last = |needle: &[u8]| state.windows(needle.len()).rposition(|window| window == needle);
    match (last(on), last(off)) {
        (Some(on), Some(off)) => on > off,
        (Some(_), None) => true,
        _ => false,
    }
}

/// The bytes to type for `message`, without Enter. A trailing newline is
/// dropped: Enter is the caller's. A paste end marker inside the message
/// is removed so it cannot end the paste early.
pub(in crate::cli) fn input_bytes(message: &str, paste_mode: bool) -> Vec<u8> {
    let message = message.trim_end_matches(['\n', '\r']);
    if !paste_mode {
        return message.as_bytes().to_vec();
    }
    let body = message.replace(PASTE_END, "").replace("\r\n", "\n");
    format!("{PASTE_START}{body}{PASTE_END}").into_bytes()
}

/// The text the agent printed after `message`, and whether the message's
/// echo was found (`false`: the whole screen less its footer).
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct Reply {
    pub text: String,
    pub anchored: bool,
}

/// Whether an echo comparison keeps `character`: not whitespace (wraps and
/// indents differ) and not a Markdown mark a harness may render away.
fn kept(character: &char) -> bool {
    !character.is_whitespace() && !matches!(character, '`' | '*' | '_' | '~')
}

fn squeeze(text: &str) -> Vec<char> {
    text.chars().filter(kept).collect()
}

/// The line of the last line of the last match of `needle` in `lines`,
/// comparing with [`kept`] characters only (so wrapped, indented and
/// rendered echoes match).
fn last_match(lines: &[String], needle: &[char]) -> Option<usize> {
    if needle.is_empty() {
        return None;
    }
    let mut flat = Vec::new();
    let mut owner = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        for character in line.chars().filter(kept) {
            flat.push(character);
            owner.push(index);
        }
    }
    if flat.len() < needle.len() {
        return None;
    }
    (0..=flat.len() - needle.len())
        .rev()
        .find(|&start| flat[start..start + needle.len()] == *needle)
        .map(|start| owner[start + needle.len() - 1])
}

/// The line after the message's echo: the full message, else its end, else
/// its start, else a Claude Code paste placeholder (`[Pasted text #1 …]`).
pub(in crate::cli) fn anchor(lines: &[String], message: &str) -> Option<usize> {
    let key = squeeze(message);
    let tail = |chars: usize| &key[key.len().saturating_sub(chars)..];
    let head = &key[..key.len().min(ANCHOR_CHARS)];
    let placeholder = squeeze("[Pasted text #");
    // Shorter ends find a message whose start scrolled off or wrapped
    // differently; the full message and longer ends are tried first.
    [&key[..], tail(ANCHOR_CHARS), tail(32), tail(MIN_ANCHOR_CHARS), head, &placeholder[..]]
        .into_iter()
        .filter(|needle| needle.len() >= MIN_ANCHOR_CHARS.min(key.len()))
        .find_map(|needle| last_match(lines, needle))
        .map(|line| line + 1)
}

/// A rule line of a harness's input box: `────` (Claude Code, muse), with
/// or without a label in it.
fn is_rule(line: &str) -> bool {
    let trimmed = line.trim();
    let rule = trimmed.chars().filter(|character| matches!(character, '─' | '━' | '═')).count();
    (trimmed.starts_with('─') || trimmed.starts_with('━') || trimmed.starts_with('═')) && rule >= 10
}

/// A composer line: `›` (Codex) or `❯`/`>` alone (an empty prompt).
fn is_composer(line: &str) -> bool {
    let trimmed = line.trim_start();
    trimmed.starts_with('›') || matches!(trimmed.trim_end(), "❯" | ">")
}

/// A harness's turn summary or spinner line: Claude Code's `✻ Brewed for
/// 1m 38s · done 10:33 PM` (a symbol, a word, `for`, a duration).
fn is_turn_summary(line: &str) -> bool {
    let mut words = line.split_whitespace();
    let symbol = words.next().unwrap_or_default();
    let symbolic =
        symbol.chars().count() == 1 && symbol.chars().all(|character| !character.is_alphanumeric());
    symbolic
        && words.next().is_some_and(|word| word.chars().all(char::is_alphabetic))
        && words.next() == Some("for")
        && words.next().is_some_and(|word| word.starts_with(|c: char| c.is_ascii_digit()))
}

/// `body` without the input box and status lines at its bottom.
fn without_footer(body: &[String]) -> &[String] {
    let start = body.len().saturating_sub(FOOTER_LINES);
    let cut = (start..body.len())
        .find(|&index| is_rule(&body[index]))
        .or_else(|| (start..body.len()).find(|&index| is_composer(&body[index])));
    let mut body = &body[..cut.unwrap_or(body.len())];
    while let Some((last, rest)) = body.split_last() {
        if last.trim().is_empty() || is_turn_summary(last) {
            body = rest;
        } else if let Some(start) = wrapped_summary_start(body) {
            body = body.get(..start).unwrap_or_default();
        } else {
            break;
        }
    }
    body
}

/// Where a turn summary that a narrow pane wrapped starts at the end of
/// `body`: its first line, then indented continuation lines (`✻ Churned` /
/// `  for 1s · done` / `  2:36 PM`).
fn wrapped_summary_start(body: &[String]) -> Option<usize> {
    (2..=SUMMARY_LINES).find_map(|count| {
        let start = body.len().checked_sub(count)?;
        let lines = body.get(start..)?;
        let (first, rest) = lines.split_first()?;
        let continued = rest
            .iter()
            .all(|line| line.starts_with(char::is_whitespace) && !line.trim().is_empty());
        let joined = lines.iter().map(|line| line.trim()).collect::<Vec<_>>().join(" ");
        (continued && !first.starts_with(char::is_whitespace) && is_turn_summary(&joined))
            .then_some(start)
    })
}

/// Trailing whitespace off each line; leading and trailing blank lines off.
fn tidy(lines: &[String]) -> String {
    let lines: Vec<&str> = lines.iter().map(|line| line.trim_end()).collect();
    let first = lines.iter().position(|line| !line.is_empty()).unwrap_or(lines.len());
    let last = lines.iter().rposition(|line| !line.is_empty()).map_or(first, |index| index + 1);
    lines[first..last].join("\n")
}

/// The reply in `lines` (history then screen, oldest first) to `message`.
///
/// Without the echo: with `before`, the screen before the message was
/// typed, the reply is what `lines` hold after the last lines of `before`,
/// else `screen` (the last screen read) alone; without `before` it is all
/// of `lines`.
pub(in crate::cli) fn reply_since(
    lines: &[String],
    message: &str,
    before: Option<&[String]>,
    screen: &[String],
) -> Reply {
    if let Some(start) = anchor(lines, message) {
        return Reply { text: tidy(without_footer(&lines[start..])), anchored: true };
    }
    let body = match before {
        None => lines,
        Some(before) => {
            after_before(lines, before).and_then(|start| lines.get(start..)).unwrap_or(screen)
        }
    };
    Reply { text: tidy(without_footer(body)), anchored: false }
}

/// The line after the last place `lines` show the last non-empty lines of
/// `before`'s body (its footer off).
fn after_before(lines: &[String], before: &[String]) -> Option<usize> {
    let body = without_footer(before);
    let tail: Vec<&String> =
        body.iter().rev().filter(|line| !line.trim().is_empty()).take(BEFORE_TAIL_LINES).collect();
    let needle: Vec<char> = tail.iter().rev().flat_map(|line| squeeze(line)).collect();
    last_match(lines, &needle).map(|line| line + 1)
}

/// Screen text as lines.
pub(in crate::cli) fn lines(text: &str) -> Vec<String> {
    text.split('\n').map(str::to_owned).collect()
}

/// The prompt marks an input box line starts with.
const PROMPT_MARKS: [char; 3] = ['❯', '>', '›'];

/// The text in the agent's input box at the bottom of `screen`: the lines
/// between the last two rules (Claude Code draws its input box so), the
/// first of them starting with a prompt mark, without the mark. `None` when
/// the screen shows no such box.
pub(in crate::cli) fn input_box_text(screen: &str) -> Option<String> {
    let lines: Vec<&str> = screen.lines().collect();
    let rules: Vec<usize> = (0..lines.len())
        .filter(|index| lines.get(*index).is_some_and(|line| is_rule(line)))
        .collect();
    let (top, bottom) = rules.windows(2).rev().find_map(|pair| match pair {
        [top, bottom] if bottom > &(top + 1) => Some((*top, *bottom)),
        _ => None,
    })?;
    let inside = lines.get(top + 1..bottom)?;
    let (first, rest) = inside.split_first()?;
    let first =
        first.trim_start_matches(|character: char| character.is_whitespace() || character == '│');
    let first = first.strip_prefix(PROMPT_MARKS)?;
    let mut text = first.trim().to_owned();
    for line in rest {
        let line =
            line.trim_matches(|character: char| character.is_whitespace() || character == '│');
        if !line.is_empty() {
            text.push(' ');
            text.push_str(line);
        }
    }
    Some(text)
}

/// Whether the input box on `screen` ([`input_box_text`]) still holds
/// `message`: its text is the start of the message (or the whole of it), or
/// a paste placeholder (`[Pasted text #1 +20 lines]`). An empty box, a hint
/// in it, or no box is `false`.
pub(in crate::cli) fn input_box_holds(screen: &str, message: &str) -> bool {
    let Some(text) = input_box_text(screen) else { return false };
    if text.contains("[Pasted text") {
        return true;
    }
    let boxed = squeeze(&text);
    let sent = squeeze(message);
    !boxed.is_empty() && (sent.starts_with(&boxed) || boxed.starts_with(&sent))
}
