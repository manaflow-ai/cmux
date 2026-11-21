//! Toggle Terminal and Chat's draft: what the person typed and has not sent goes with the swap,
//! both ways (Leo, 2026-11-12: two live views of one session, instant both ways). The app records
//! every byte the terminal sends to its program (keys, IME text, pastes), the newest 16 KB, and
//! hands them over with the terminal's bottom rows and the chat composer's state; these rules
//! read the input line out of those bytes and say what moves.
//!
//! Two signals have to agree before anything moves. The bytes since the last Enter must be keys
//! these rules can follow, and the harness's input box on screen must show exactly that text
//! (or nothing, for a draft going in). The bytes alone miss what they never saw: a draft from
//! before this app attached, keys from another client, an Enter that answered a dialog instead
//! of sending. The screen alone cannot tell a draft from a dialog's option. A draft moves only
//! into an empty input, so two drafts are never merged, and a draft the rules cannot be sure of
//! stays where it is.

use serde::{Deserialize, Serialize};

/// The bottom rows of the terminal's screen that hold its input box and the hints under it.
pub const SCREEN_ROWS: usize = 12;

/// Box edges a harness draws beside its input, left out of a screen row and a draft alike.
const EDGES: &[char] = &['│', '┃', '▌', '▎', '▏', '║'];
/// The marks a harness draws before its input: Claude Code's `>`, Codex's `›`, `❯`.
const PROMPT_MARKS: &[char] = &['>', '›', '❯'];
/// A row that starts with a box rule ends the input box.
const RULES: &[char] = &['╰', '╭', '└', '┌', '─', '━', '═'];

/// The input line the typed bytes leave, after the last Enter.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Typed {
    Known(String),
    /// A key moved the cursor or the contents in a way the bytes do not say (an arrow, Tab,
    /// history, Esc), or the bytes start after the input began.
    Unknown,
}

/// Going to the chat (the terminal shows): its typed bytes, its bottom rows, the composer.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToChat {
    /// The newest bytes the terminal sent its program, oldest first.
    pub typed: Vec<u8>,
    /// Older bytes were dropped to keep the newest.
    pub truncated: bool,
    /// The terminal's active rows (its bottom screen), one line per row.
    pub screen: String,
    /// The chat composer holds nothing: no text, no chips.
    pub composer_empty: bool,
}

/// Going to the terminal (the chat shows): the composer's draft, the terminal's typed bytes and
/// bottom rows.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToTerminal {
    /// The composer's text when it can leave as text (no chips, no inline tokens); None otherwise.
    pub chat: Option<String>,
    pub typed: Vec<u8>,
    pub truncated: bool,
    pub screen: String,
}

/// What a swap to the chat does with the terminal's draft.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "draft")]
pub enum ChatDraft {
    /// Put `text` in the composer; once it holds it, send `erase` DEL bytes to the terminal.
    Carry {
        text: String,
        erase: usize,
    },
    None,
}

/// What a swap to the terminal does with the composer's draft.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "draft")]
pub enum TerminalDraft {
    /// Paste `text` into the terminal; then the composer gives it up.
    Paste {
        text: String,
    },
    None,
}

pub fn to_chat(facts: &ToChat) -> ChatDraft {
    if !facts.composer_empty {
        return ChatDraft::None;
    }
    let Typed::Known(text) = typed_draft(&facts.typed, facts.truncated) else {
        return ChatDraft::None;
    };
    if text.trim().is_empty() || shown_input(&facts.screen) != Some(squeeze(&text)) {
        return ChatDraft::None;
    }
    // One DEL a character, and no more: a spare one would take what the input holds after the
    // draft. The app sends them only if nothing was typed since these bytes were read.
    let erase = text.chars().count();
    ChatDraft::Carry { text, erase }
}

pub fn to_terminal(facts: &ToTerminal) -> TerminalDraft {
    let Some(chat) =
        facts.chat.as_deref().map(str::trim_end).filter(|text| !text.trim().is_empty())
    else {
        return TerminalDraft::None;
    };
    // A new line pasted into a program that did not ask for bracketed paste sends what is before
    // it, and the app cannot read that mode: a draft of several lines stays in the chat.
    if chat.contains(['\n', '\r']) {
        return TerminalDraft::None;
    }
    let empty = matches!(typed_draft(&facts.typed, facts.truncated), Typed::Known(typed) if typed.is_empty());
    if !empty || shown_input(&facts.screen).as_deref() != Some("") {
        return TerminalDraft::None;
    }
    TerminalDraft::Paste { text: chat.to_string() }
}

/// The text the harness's input box shows, whitespace and box edges left out: the last of the
/// bottom rows that starts with a prompt mark, after the mark, and the rows under it until a
/// blank row or a box rule. None when no bottom row starts with a mark (a dialog without one, a
/// shell, output still drawing).
pub fn shown_input(screen: &str) -> Option<String> {
    let rows: Vec<&str> = screen.lines().collect();
    let bottom = rows.get(rows.len().saturating_sub(SCREEN_ROWS)..).unwrap_or_default();
    let start = bottom.iter().rposition(|row| inner(row).starts_with(PROMPT_MARKS))?;
    let first = inner(bottom.get(start)?);
    let mut chars = first.chars();
    chars.next()?;
    let mut text = chars.as_str().to_string();
    for row in bottom.get(start.saturating_add(1)..).unwrap_or_default() {
        let row = inner(row);
        if row.is_empty() || row.starts_with(RULES) {
            break;
        }
        text.push_str(row);
    }
    Some(squeeze(&text))
}

/// A row without the whitespace and box edges around it.
fn inner(row: &str) -> &str {
    row.trim_matches(|c: char| c.is_whitespace() || EDGES.contains(&c))
}

fn squeeze(text: &str) -> String {
    text.chars().filter(|c| !c.is_whitespace() && !EDGES.contains(c)).collect()
}

/// The input line `bytes` leave: the text after the last Enter outside a bracketed paste.
pub fn typed_draft(bytes: &[u8], truncated: bool) -> Typed {
    let mut line = Line::default();
    let mut entered = false;
    let mut at = 0;
    while at < bytes.len() {
        let (key, next) = Key::read(bytes, at);
        at = next;
        match key {
            Key::Text(text) => line.text.push_str(&String::from_utf8_lossy(text)),
            Key::Char(text) => line.text.push_str(&text),
            Key::Paste(text) => {
                let text = String::from_utf8_lossy(text);
                line.text.push_str(&text.replace("\r\n", "\n").replace('\r', "\n"));
            }
            Key::Enter => {
                // A backslash before Enter asks the harness (and a shell) for a new line, not a send.
                if line.text.ends_with('\\') {
                    line.unknown = true;
                } else {
                    line = Line::default();
                    entered = true;
                }
            }
            Key::Erase => {
                line.text.pop();
            }
            Key::Clear => line.text.clear(),
            Key::Word => {
                let kept = line.text.trim_end().len();
                line.text.truncate(kept);
                let start = line
                    .text
                    .char_indices()
                    .rfind(|(_, c)| c.is_whitespace())
                    .map_or(0, |(space, c)| space.saturating_add(c.len_utf8()));
                line.text.truncate(start);
            }
            Key::Ignored => {}
            Key::Unknown => line.unknown = true,
        }
    }
    if line.unknown || (truncated && !entered) { Typed::Unknown } else { Typed::Known(line.text) }
}

#[derive(Default)]
struct Line {
    text: String,
    unknown: bool,
}

/// One key (or one report the terminal sent its program on its own) of the typed bytes.
enum Key<'a> {
    Text(&'a [u8]),
    /// A printable key the kitty keyboard protocol encoded.
    Char(String),
    Paste(&'a [u8]),
    Enter,
    /// Backspace: the last character goes.
    Erase,
    /// Ctrl+U, Ctrl+C: the whole input goes.
    Clear,
    /// Ctrl+W: the last word goes.
    Word,
    /// A focus or mouse report, a terminal's answer to a query, a key's release, a modifier key
    /// alone: no change to the input.
    Ignored,
    Unknown,
}

const ESC: u8 = 0x1b;
const PASTE_START: &[u8] = b"\x1b[200~";
const PASTE_END: &[u8] = b"\x1b[201~";
/// The kitty protocol's codes for a modifier key pressed alone (Shift, Control, Alt, Super,
/// Hyper, Meta, left and right, ISO level 3 and 5 shift).
const KITTY_MODIFIER_KEYS: std::ops::RangeInclusive<u32> = 57441..=57454;
/// The kitty protocol's other functional keys (arrows, F keys, keypad): not text.
const KITTY_FUNCTIONAL_KEYS: std::ops::RangeInclusive<u32> = 57344..=63743;
/// Modifier bits that do not change what a key types here: Caps Lock and Num Lock.
const LOCK_BITS: u32 = 64 | 128;
const SHIFT: u32 = 1;
const CTRL: u32 = 4;

impl<'a> Key<'a> {
    /// The key at `at` and where the next one starts (past the end: Unknown, at the end).
    fn read(bytes: &'a [u8], at: usize) -> (Key<'a>, usize) {
        let Some(&byte) = bytes.get(at) else { return (Key::Unknown, bytes.len()) };
        let next = at.saturating_add(1);
        match byte {
            b'\r' => (Key::Enter, next),
            0x7f | 0x08 => (Key::Erase, next),
            0x15 | 0x03 => (Key::Clear, next),
            0x17 => (Key::Word, next),
            ESC => Self::escape(bytes, at),
            0x00..=0x1f => (Key::Unknown, next),
            _ => {
                let rest = bytes.get(at..).unwrap_or_default();
                let length =
                    rest.iter().position(|&byte| byte < 0x20 || byte == 0x7f).unwrap_or(rest.len());
                let text = rest.get(..length).unwrap_or_default();
                (Key::Text(text), at.saturating_add(length))
            }
        }
    }

    fn escape(bytes: &'a [u8], at: usize) -> (Key<'a>, usize) {
        let rest = bytes.get(at..).unwrap_or_default();
        if let Some(after) = rest.strip_prefix(PASTE_START) {
            let body = at.saturating_add(PASTE_START.len());
            return match find(after, PASTE_END) {
                Some(length) => (
                    Key::Paste(after.get(..length).unwrap_or_default()),
                    body.saturating_add(length).saturating_add(PASTE_END.len()),
                ),
                // A paste still arriving: its end is not here yet.
                None => (Key::Unknown, bytes.len()),
            };
        }
        let past = |n: usize| at.saturating_add(n).min(bytes.len());
        match rest.get(1) {
            Some(b'[') => Self::csi(bytes, at.saturating_add(2)),
            // OSC: a color or clipboard answer, to BEL or ST.
            Some(b']') => (Key::Ignored, string_end(bytes, at.saturating_add(2), true)),
            // DCS, APC, PM: a terminal's answer (XTGETTCAP, DECRQSS), to ST.
            Some(b'P' | b'_' | b'^') => {
                (Key::Ignored, string_end(bytes, at.saturating_add(2), false))
            }
            // SS3: an arrow or F1-F4 in application mode.
            Some(b'O') => (Key::Unknown, past(3)),
            // Esc itself, or Alt with a key.
            _ => (Key::Unknown, past(2)),
        }
    }

    /// A CSI sequence whose parameters start at `start`.
    fn csi(bytes: &'a [u8], start: usize) -> (Key<'a>, usize) {
        let rest = bytes.get(start..).unwrap_or_default();
        let Some(length) = rest.iter().position(|byte| (0x40..=0x7e).contains(byte)) else {
            return (Key::Unknown, bytes.len());
        };
        let (Some(params), Some(&last)) = (rest.get(..length), rest.get(length)) else {
            return (Key::Unknown, bytes.len());
        };
        let end = start.saturating_add(length).saturating_add(1);
        let key = match (params, last) {
            // Focus in and out.
            (b"", b'I' | b'O') => Key::Ignored,
            // An SGR mouse report.
            ([b'<', ..], b'M' | b'm') => Key::Ignored,
            // A terminal's answer to a query (DA, DECRPM, the kitty keyboard flags): keys carry no
            // such prefix.
            ([b'?' | b'>' | b'=', ..], _) => Key::Ignored,
            (_, b'u') => Self::kitty(params),
            // A key's release in the kitty protocol (event type 3) changes nothing.
            (_, _) if kitty_event(params) == Some(3) => Key::Ignored,
            // Arrows, Home, End, Delete, F keys; the end of a paste whose start is not in the bytes.
            _ => Key::Unknown,
        };
        (key, end)
    }

    /// A kitty keyboard protocol key, `code[:shifted[:base]][;modifiers[:event][;text]]u`.
    fn kitty(params: &[u8]) -> Key<'a> {
        let Ok(params) = std::str::from_utf8(params) else { return Key::Unknown };
        let mut fields = params.split(';');
        let mut codes = fields.next().unwrap_or_default().split(':');
        let code = codes.next().and_then(|code| code.parse::<u32>().ok());
        let shifted = codes.next().and_then(|code| code.parse::<u32>().ok());
        let modifiers = fields.next().map_or(Some(1), |field| {
            let modifiers = field.split(':').next().unwrap_or_default();
            if modifiers.is_empty() { Some(1) } else { modifiers.parse::<u32>().ok() }
        });
        let text = fields.next();
        if fields.next().is_some() {
            return Key::Unknown;
        }
        match kitty_event(params.as_bytes()) {
            // A press or a repeat.
            Some(1 | 2) => {}
            Some(3) => return Key::Ignored,
            _ => return Key::Unknown,
        }
        let (Some(code), Some(modifiers)) = (code, modifiers) else { return Key::Unknown };
        let modifiers = modifiers.saturating_sub(1) & !LOCK_BITS;
        if KITTY_MODIFIER_KEYS.contains(&code) {
            return Key::Ignored;
        }
        match (code, modifiers) {
            (13, 0) => Key::Enter,
            (127 | 8, 0) => Key::Erase,
            // Ctrl+U, Ctrl+C.
            (117 | 99, CTRL) => Key::Clear,
            // Ctrl+W.
            (119, CTRL) => Key::Word,
            (_, 0 | SHIFT) if !KITTY_FUNCTIONAL_KEYS.contains(&code) => {
                // The text the key typed: the report's own, else the key (shifted, with Shift).
                let typed = match text {
                    Some(text) => {
                        Some(text.split(':').map(|code| code.parse::<u32>().ok()).collect())
                    }
                    None if modifiers == SHIFT => shifted.map(|code| vec![Some(code)]),
                    None => Some(vec![Some(code)]),
                };
                let chars: Option<String> = typed
                    .into_iter()
                    .flatten()
                    .map(|code| code.and_then(char::from_u32).filter(|c| !c.is_control()))
                    .collect();
                chars.filter(|chars| !chars.is_empty()).map_or(Key::Unknown, Key::Char)
            }
            _ => Key::Unknown,
        }
    }
}

/// The kitty protocol's event type of a key report (1 press, 2 repeat, 3 release): after a colon
/// in its second field, 1 when it has none; None when the field does not parse.
fn kitty_event(params: &[u8]) -> Option<u32> {
    let params = std::str::from_utf8(params).ok()?;
    match params.split(';').nth(1).and_then(|field| field.split_once(':')) {
        Some((_, event)) => event.parse().ok(),
        None => Some(1),
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

/// Where a string sequence that starts at `start` ends: after ST (ESC \), or BEL when `bel`.
fn string_end(bytes: &[u8], start: usize, bel: bool) -> usize {
    let rest = bytes.get(start..).unwrap_or_default();
    for (offset, &byte) in rest.iter().enumerate() {
        let at = start.saturating_add(offset);
        match byte {
            0x07 if bel => return at.saturating_add(1),
            ESC if rest.get(offset.saturating_add(1)) == Some(&b'\\') => {
                return at.saturating_add(2);
            }
            _ => {}
        }
    }
    bytes.len()
}

#[cfg(test)]
#[path = "tabs_draft_tests.rs"]
mod tests;
