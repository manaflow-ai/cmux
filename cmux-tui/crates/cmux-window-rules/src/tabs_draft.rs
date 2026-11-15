//! Toggle Terminal and Chat's draft: what the person typed and has not sent goes with the swap,
//! both ways (Leo, 2026-11-12: two live views of one session, instant both ways). The app records
//! every byte the terminal sends to its program (keys, IME text, pastes), the newest 16 KB, and
//! hands them over with the chat composer's state; these rules read the input line out of those
//! bytes and say what moves. A draft moves only into an empty input, and only when every byte
//! since the last Enter is one these rules can follow: two drafts are never merged, and a draft
//! the rules cannot be sure of stays where it is.

use serde::{Deserialize, Serialize};

/// How many of a draft's last characters (whitespace left out) the terminal's bottom rows must
/// show before the draft leaves the terminal: what the harness draws in its input box. A dialog
/// that took the keys instead draws something else, and the draft stays.
pub const SHOWN_CHARS: usize = 24;
/// The bottom rows of the terminal's screen that hold its input box and the hints under it.
pub const SCREEN_ROWS: usize = 12;
/// DEL bytes past the draft's characters: one on an empty input deletes nothing, and a character
/// the harness draws from two (a combined emoji) takes one DEL, not two.
pub const ERASE_SLACK: usize = 2;

/// Box edges a harness draws beside its input, left out of a screen row and a draft alike.
const EDGES: &[char] = &['│', '┃', '▌', '▎', '▏', '║'];

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

/// Going to the terminal (the chat shows): the composer's draft, the terminal's typed bytes.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToTerminal {
    /// The composer's text when it can leave as text (no chips, no inline tokens); None otherwise.
    pub chat: Option<String>,
    pub typed: Vec<u8>,
    pub truncated: bool,
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
    if text.trim().is_empty() || !shown(&text, &facts.screen) {
        return ChatDraft::None;
    }
    let erase = text.chars().count() + ERASE_SLACK;
    ChatDraft::Carry { text, erase }
}

pub fn to_terminal(facts: &ToTerminal) -> TerminalDraft {
    let Some(chat) =
        facts.chat.as_deref().map(str::trim_end).filter(|text| !text.trim().is_empty())
    else {
        return TerminalDraft::None;
    };
    match typed_draft(&facts.typed, facts.truncated) {
        Typed::Known(typed) if typed.is_empty() => TerminalDraft::Paste { text: chat.to_string() },
        _ => TerminalDraft::None,
    }
}

/// Whether the screen's bottom rows hold the draft's last characters, whitespace and box edges
/// left out of both (the harness wraps a long draft across rows).
fn shown(draft: &str, screen: &str) -> bool {
    let tail: Vec<char> = squeeze(draft).chars().collect();
    let tail: String = tail[tail.len().saturating_sub(SHOWN_CHARS)..].iter().collect();
    let rows: Vec<&str> = screen.lines().collect();
    let bottom = rows[rows.len().saturating_sub(SCREEN_ROWS)..].concat();
    !tail.is_empty() && squeeze(&bottom).contains(&tail)
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
                    .map_or(0, |(space, c)| space + c.len_utf8());
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
    Paste(&'a [u8]),
    Enter,
    /// Backspace: the last character goes.
    Erase,
    /// Ctrl+U, Ctrl+C: the whole input goes.
    Clear,
    /// Ctrl+W: the last word goes.
    Word,
    /// A focus or mouse report, a terminal's answer to a query: no change to the input.
    Ignored,
    Unknown,
}

const ESC: u8 = 0x1b;
const PASTE_START: &[u8] = b"\x1b[200~";
const PASTE_END: &[u8] = b"\x1b[201~";

impl<'a> Key<'a> {
    /// The key at `at` and where the next one starts.
    fn read(bytes: &'a [u8], at: usize) -> (Key<'a>, usize) {
        let byte = bytes[at];
        match byte {
            b'\r' => (Key::Enter, at + 1),
            0x7f | 0x08 => (Key::Erase, at + 1),
            0x15 | 0x03 => (Key::Clear, at + 1),
            0x17 => (Key::Word, at + 1),
            ESC => Self::escape(bytes, at),
            0x00..=0x1f => (Key::Unknown, at + 1),
            _ => {
                let end = bytes[at..]
                    .iter()
                    .position(|&byte| byte < 0x20 || byte == 0x7f)
                    .map_or(bytes.len(), |length| at + length);
                (Key::Text(&bytes[at..end]), end)
            }
        }
    }

    fn escape(bytes: &'a [u8], at: usize) -> (Key<'a>, usize) {
        let rest = &bytes[at..];
        if rest.starts_with(PASTE_START) {
            let body = at + PASTE_START.len();
            return match find(&bytes[body..], PASTE_END) {
                Some(length) => {
                    (Key::Paste(&bytes[body..body + length]), body + length + PASTE_END.len())
                }
                // A paste still arriving: its end is not here yet.
                None => (Key::Unknown, bytes.len()),
            };
        }
        match rest.get(1) {
            Some(b'[') => Self::csi(bytes, at + 2),
            // OSC: a color or clipboard answer, to BEL or ST.
            Some(b']') => (Key::Ignored, string_end(bytes, at + 2, true)),
            // DCS, APC, PM: a terminal's answer (XTGETTCAP, DECRQSS), to ST.
            Some(b'P' | b'_' | b'^') => (Key::Ignored, string_end(bytes, at + 2, false)),
            // SS3: an arrow or F1-F4 in application mode.
            Some(b'O') => (Key::Unknown, (at + 3).min(bytes.len())),
            // Esc itself, or Alt with a key.
            _ => (Key::Unknown, (at + 2).min(bytes.len())),
        }
    }

    /// A CSI sequence whose parameters start at `start`.
    fn csi(bytes: &'a [u8], start: usize) -> (Key<'a>, usize) {
        let Some(length) = bytes[start..].iter().position(|byte| (0x40..=0x7e).contains(byte))
        else {
            return (Key::Unknown, bytes.len());
        };
        let params = &bytes[start..start + length];
        let end = start + length + 1;
        let key = match (params, bytes[start + length]) {
            // Focus in and out.
            (b"", b'I' | b'O') => Key::Ignored,
            // An SGR mouse report.
            ([b'<', ..], b'M' | b'm') => Key::Ignored,
            // A terminal's answer to a query (DA, DECRPM, the kitty keyboard flags): keys carry no
            // such prefix.
            ([b'?' | b'>' | b'=', ..], _) => Key::Ignored,
            (_, b'u') => Self::kitty(params),
            // The end of a paste whose start is not in the bytes.
            _ => Key::Unknown,
        };
        (key, end)
    }

    /// A kitty keyboard protocol key, `code;modifiers u`.
    fn kitty(params: &[u8]) -> Key<'a> {
        let text = std::str::from_utf8(params).unwrap_or_default();
        let mut parts = text.split(';');
        let code = parts.next().and_then(|code| code.split(':').next()?.parse::<u32>().ok());
        let modifiers = match parts.next() {
            None => Some(1),
            Some(modifiers) => modifiers.split(':').next().and_then(|m| m.parse::<u32>().ok()),
        };
        if parts.next().is_some() {
            return Key::Unknown;
        }
        match (code, modifiers) {
            (Some(13), Some(1)) => Key::Enter,
            (Some(127), Some(1)) => Key::Erase,
            // Ctrl+U, Ctrl+C.
            (Some(117 | 99), Some(5)) => Key::Clear,
            // Ctrl+W.
            (Some(119), Some(5)) => Key::Word,
            _ => Key::Unknown,
        }
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

/// Where a string sequence that starts at `start` ends: after ST (ESC \), or BEL when `bel`.
fn string_end(bytes: &[u8], start: usize, bel: bool) -> usize {
    let mut at = start;
    while at < bytes.len() {
        match bytes[at] {
            0x07 if bel => return at + 1,
            ESC if bytes.get(at + 1) == Some(&b'\\') => return at + 2,
            _ => at += 1,
        }
    }
    bytes.len()
}

#[cfg(test)]
#[path = "tabs_draft_tests.rs"]
mod tests;
