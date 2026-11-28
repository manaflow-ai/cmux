//! Toggle Terminal and Chat's place: a swap lands at the same turn in the other view, both ways
//! (Leo, 2026-11-12: two live views of one session, instant both ways). The chat names its
//! prompts (the person's messages, oldest first) and the turn at the top of its view; the terminal
//! hands over its screen, one line per row with row 0 the oldest kept, and where its viewport is.
//! Both views show the same prompts, so each prompt's row in the terminal is the pivot: found
//! newest first, each above the one after it, the way the harness printed them.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// The glyphs a terminal harness draws before a prompt it echoes (`> `, `› `, `❯ `, a bar).
const MARKS: &[char] = &['>', '›', '❯', '»', '│', '┃', '▌', '▎', '|'];
/// The most of a prompt's first line a row has to start with: enough to tell prompts apart, short
/// enough to fit one row of a narrow terminal after its mark.
const KEY_CHARS: usize = 48;
const MIN_KEY_CHARS: usize = 8;

/// Going to the terminal: the chat's prompts and its turn, the terminal's screen.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToTerminal {
    pub prompts: Vec<String>,
    /// The prompt (an index into `prompts`) of the turn at the top of the chat's view; None while
    /// the chat follows its latest message.
    pub at: Option<usize>,
    /// Screen rows from `base` on, one line per row: the newest rows the app read (a bounded
    /// window of a long history, `base` 0 for all of it).
    pub screen: String,
    pub base: usize,
    pub columns: usize,
}

/// Going to the chat: the terminal's screen and viewport, the chat's prompts.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToChat {
    pub prompts: Vec<String>,
    /// Screen rows from `base` on, one line per row: from the screen's start through the viewport
    /// (`base` 0), or from the viewport's top (`base` == `top`) to the newest row.
    pub screen: String,
    pub base: usize,
    pub columns: usize,
    /// The screen row at the top of the terminal's viewport.
    pub top: usize,
    /// The viewport shows the newest rows.
    pub at_bottom: bool,
}

/// Where the terminal scrolls before it shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "place")]
pub enum TerminalPlace {
    /// To its newest rows: the chat follows its latest message.
    Latest,
    /// Screen row `row` at the top of the viewport: the chat's turn's prompt.
    Row { row: usize },
    /// Where it is: no prompt of the chat's is on the terminal's screen.
    Stay,
}

/// Where the chat scrolls before it shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "place")]
pub enum ChatPlace {
    /// To its latest message: the terminal shows its newest rows.
    Latest,
    /// To prompt `index`'s turn: the newest prompt at or above the terminal's viewport top.
    Turn { index: usize },
    /// Where it is: no prompt of the chat's is on the terminal's screen.
    Stay,
}

pub fn terminal_place(facts: &ToTerminal) -> TerminalPlace {
    let Some(at) = facts.at else { return TerminalPlace::Latest };
    if facts.prompts.is_empty() {
        return TerminalPlace::Stay;
    }
    let rows = prompt_rows(&facts.prompts, &facts.screen, facts.columns);
    // The asked prompt's row, else the nearest older prompt the window still has.
    match rows.iter().take(at.saturating_add(1)).rev().find_map(|row| *row) {
        Some(row) => TerminalPlace::Row { row: facts.base.saturating_add(row) },
        None => TerminalPlace::Stay,
    }
}

pub fn chat_place(facts: &ToChat) -> ChatPlace {
    if facts.at_bottom {
        return ChatPlace::Latest;
    }
    let rows = prompt_rows(&facts.prompts, &facts.screen, facts.columns);
    let found = rows
        .iter()
        .enumerate()
        .filter_map(|(index, row)| row.map(|row| (index, facts.base.saturating_add(row))));
    let mut first = None;
    let mut turn = None;
    for (index, row) in found {
        first.get_or_insert(index);
        if row <= facts.top {
            turn = Some(index);
        }
    }
    if let Some(index) = turn {
        return ChatPlace::Turn { index };
    }
    match first {
        // Above every prompt of a window from the viewport's top: the turn is the one before the
        // first prompt below it, whose own prompt is above the window.
        Some(index) if facts.base > 0 => ChatPlace::Turn { index: index.saturating_sub(1) },
        // Above every prompt of the whole screen (the harness's welcome): its oldest turn.
        Some(index) => ChatPlace::Turn { index },
        None => ChatPlace::Stay,
    }
}

/// The most screen rows a swap reads: the cost stays flat however long the session.
pub const READ_ROWS: usize = 20_000;

/// Going to the terminal, once the chat named its turn: what the app reads of the hidden
/// terminal's screen.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TerminalReadFacts {
    /// The chat's turn (`ToTerminal::at`); None while it follows its latest message.
    pub at: Option<usize>,
    /// The screen's rows, its history included.
    pub total: usize,
    /// The most rows to read ([`READ_ROWS`] when not sent).
    #[serde(default = "read_rows")]
    pub rows: usize,
}

/// What the app reads of the terminal before it shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "read")]
pub enum TerminalRead {
    /// Nothing: the chat follows its latest message, so the terminal goes to its newest rows.
    Latest,
    /// The newest rows from `base` on: all of a short screen (`base` 0, read through the
    /// viewport), else with the viewport moved to `base` and read from its top.
    Screen { base: usize, from_viewport_top: bool },
}

/// Ghostty addresses no window of a long history but from or through the viewport, so the
/// hidden terminal's viewport moves to the top of its newest `rows` to read them.
pub fn terminal_read(facts: &TerminalReadFacts) -> TerminalRead {
    if facts.at.is_none() {
        return TerminalRead::Latest;
    }
    let base = facts.total.saturating_sub(facts.rows);
    TerminalRead::Screen { base, from_viewport_top: base > 0 }
}

/// Going to the terminal, its screen read: the place facts and where the viewport was.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToTerminalScroll {
    #[serde(flatten)]
    pub place: ToTerminal,
    /// The viewport's top row before the read moved it.
    pub top: usize,
    /// The viewport showed the newest rows before the read moved it.
    pub at_bottom: bool,
}

/// How the terminal scrolls before it shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "scroll")]
pub enum TerminalScroll {
    /// To its newest rows.
    Latest,
    /// Screen row `row` at the top of the viewport.
    Row { row: usize },
    /// Not at all: the read never moved it.
    Keep,
}

/// The terminal's scroll for the chat's turn; nothing to land on puts it back where it was
/// (the read moved it only when `base` is above 0).
pub fn terminal_scroll(facts: &ToTerminalScroll) -> TerminalScroll {
    match terminal_place(&facts.place) {
        TerminalPlace::Row { row } => TerminalScroll::Row { row },
        TerminalPlace::Latest => TerminalScroll::Latest,
        TerminalPlace::Stay if facts.place.base == 0 => TerminalScroll::Keep,
        TerminalPlace::Stay if facts.at_bottom => TerminalScroll::Latest,
        TerminalPlace::Stay => TerminalScroll::Row { row: facts.top },
    }
}

/// Going to the chat, the terminal still showing: its viewport and whether the chat is at its
/// latest message.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatReadFacts {
    pub top: usize,
    /// The viewport's rows.
    pub visible: usize,
    pub total: usize,
    pub at_bottom: bool,
    pub at_latest: bool,
    /// The most rows to read ([`READ_ROWS`] when not sent).
    #[serde(default = "read_rows")]
    pub rows: usize,
}

/// What the app does first going to the chat.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "read")]
pub enum ChatRead {
    /// Nothing to read: the terminal shows its newest rows, so the chat goes to its latest
    /// message (`show` false: it is there already).
    Latest { show: bool },
    /// Read the chat's prompts, then the terminal's rows from `base` on: through the viewport
    /// when what is above it fits (`base` 0), else from the viewport's top.
    Screen { base: usize, from_viewport_top: bool, through_viewport_bottom: bool },
    /// Neither fits: the chat stays.
    Stay,
}

pub fn chat_read(facts: &ChatReadFacts) -> ChatRead {
    if facts.at_bottom {
        return ChatRead::Latest { show: !facts.at_latest };
    }
    let cap = facts.rows;
    let from_top = facts.top.saturating_add(facts.visible) > cap;
    if from_top && facts.total.saturating_sub(facts.top) > cap {
        return ChatRead::Stay;
    }
    ChatRead::Screen {
        base: if from_top { facts.top } else { 0 },
        from_viewport_top: from_top,
        through_viewport_bottom: !from_top,
    }
}

/// Going to the chat, the terminal's rows read: the place facts and the chat's turn now.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToChatShow {
    #[serde(flatten)]
    pub place: ToChat,
    /// The prompt whose turn the chat shows; None at its latest message.
    pub at: Option<usize>,
}

/// What the chat shows before it shows.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "show")]
pub enum ChatShow {
    /// Its latest message.
    Latest,
    /// Prompt `index`'s turn.
    Turn { index: usize },
    /// Nothing moves: it is there already, or nothing matched.
    Stay,
}

pub fn chat_show(facts: &ToChatShow) -> ChatShow {
    match chat_place(&facts.place) {
        ChatPlace::Latest if facts.at.is_some() => ChatShow::Latest,
        ChatPlace::Turn { index } if Some(index) != facts.at => ChatShow::Turn { index },
        _ => ChatShow::Stay,
    }
}

fn read_rows() -> usize {
    READ_ROWS
}

/// Each prompt's row on `screen`, or None where the screen lacks it (scrolled out of its history,
/// or not drawn). Prompts the harness marked (`> hi`) win over a reply line that happens to start
/// with a prompt's words, unless the harness marks none of them.
pub fn prompt_rows(prompts: &[String], screen: &str, columns: usize) -> Vec<Option<usize>> {
    let rows: Vec<Row> = screen.lines().map(Row::read).collect();
    let keys: Vec<Option<String>> = prompts.iter().map(|prompt| key(prompt, columns)).collect();
    let mut by_word: HashMap<&str, Vec<usize>> = HashMap::new();
    for (at, row) in rows.iter().enumerate() {
        if let Some(word) = row.text.split(' ').next().filter(|word| !word.is_empty()) {
            by_word.entry(word).or_default().push(at);
        }
    }
    let marked = backward(&keys, &rows, &by_word, true);
    let any = backward(&keys, &rows, &by_word, false);
    let count = |found: &[Option<usize>]| found.iter().flatten().count();
    if count(&marked) > 0 && count(&marked).saturating_mul(2) >= count(&any) { marked } else { any }
}

/// Newest prompt first, each the nearest matching row above the newer one's.
fn backward(
    keys: &[Option<String>],
    rows: &[Row],
    by_word: &HashMap<&str, Vec<usize>>,
    marked: bool,
) -> Vec<Option<usize>> {
    let mut found = vec![None; keys.len()];
    let mut below = rows.len();
    for (index, key) in keys.iter().enumerate().rev() {
        let Some(key) = key else { continue };
        let word = key.split(' ').next().unwrap_or_default();
        let Some(candidates) = by_word.get(word) else { continue };
        let end = candidates.partition_point(|&row| row < below);
        let hit = candidates.get(..end).unwrap_or_default().iter().rev().copied().find(|&at| {
            rows.get(at)
                .is_some_and(|row| (!marked || row.marked) && row.text.starts_with(key.as_str()))
        });
        if let Some(row) = hit {
            if let Some(slot) = found.get_mut(index) {
                *slot = Some(row);
            }
            below = row;
        }
    }
    found
}

/// One screen row: its words with runs of spaces folded, after any prompt mark.
struct Row {
    text: String,
    marked: bool,
}

impl Row {
    fn read(line: &str) -> Row {
        let trimmed = line.trim_start();
        let rest = trimmed.trim_start_matches(|c: char| MARKS.contains(&c) || c.is_whitespace());
        Row { text: fold(rest), marked: rest.len() != trimmed.len() }
    }
}

/// What a row holding `prompt` starts with: its first line's words, as many whole words as fit
/// a row (a harness wraps at a word); None for an empty prompt.
fn key(prompt: &str, columns: usize) -> Option<String> {
    let line = fold(prompt.lines().find(|line| !line.trim().is_empty())?);
    let line = line.trim_start_matches(|c: char| MARKS.contains(&c) || c.is_whitespace());
    let room = columns.saturating_sub(6).clamp(MIN_KEY_CHARS, KEY_CHARS);
    if line.chars().count() <= room {
        return (!line.is_empty()).then(|| line.to_string());
    }
    let cut: String = line.chars().take(room).collect();
    // The last word may wrap to the next row: keep whole words, or the cut when it is one word.
    let whole = match line.chars().nth(room) {
        Some(' ') => cut.as_str(),
        _ => cut.rsplit_once(' ').map_or(cut.as_str(), |(head, _)| head),
    };
    Some(whole.trim_end().to_string())
}

/// `text` with surrounding space trimmed and every run of whitespace one space.
fn fold(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
#[path = "tabs_place_tests.rs"]
mod tests;
