//! The facts only the host's screen has, read from Claude Code's own screen at the Mac's grid:
//! what [`crate::claude::render`] needs beside the records to draw the phone's grid (Leo,
//! 2026-11-25: "do everything at parity on the phone").
//!
//! The records carry the conversation; the screen carries the rest: the banner's version, model
//! and folder, the footer's mode and effort, whether a turn runs, the done verb Claude Code picks
//! at random, the dim placeholder in an empty prompt, and the person's unsent draft. Each is read
//! from rows whose shape does not depend on the width, so the Mac's wide screen and a phone's
//! narrow one give the same facts (`tests/parity.rs` checks them against the recorded sessions).

use crate::claude::Chrome;
use crate::{Cell, FAINT, Grid};

/// What one look at the screen found. `None`: not on screen now (the banner scrolled away, no
/// turn has ended), so the last value seen still holds ([`ScreenFacts::apply`]).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScreenFacts {
    pub version: Option<String>,
    pub model_line: Option<String>,
    pub cwd: Option<String>,
    pub mode: Option<String>,
    pub effort: Option<String>,
    pub done_verb: Option<String>,
    /// The prompt row's dim text; `None` with a draft or no prompt row.
    pub placeholder: Option<String>,
    /// The prompt's typed text, its wrapped rows joined; empty when none.
    pub draft: String,
    /// A turn runs: the footer says `esc to interrupt`.
    pub running: bool,
    /// The input box was on screen (a dialog or menu can take its place).
    pub prompt_seen: bool,
    /// The spinner row while a turn runs (`✻ Photosynthesizing… (3s · ↓ 25 tokens)`), cell for
    /// cell: its glyph, verb, shimmer, timer and token count are the host's alone.
    pub spinner: Option<Vec<Cell>>,
    /// A one-time notice under the banner (`▎ Auto mode is now Claude Code's default ...`),
    /// its rows cell for cell at the host's width; empty when none is on screen.
    pub notice: Vec<Vec<Cell>>,
}

/// Claude Code's spinner glyphs.
const SPINNER: &[char] = &['✻', '✶', '✳', '✢', '·', '✽', '*'];

/// Whether `row` is the spinner row: a glyph, a space, then one word ending in `…`.
fn is_spinner(row: &str) -> bool {
    let mut chars = row.chars();
    let (Some(glyph), Some(' ')) = (chars.next(), chars.next()) else { return false };
    let rest: String = chars.collect();
    let word = rest.split(' ').next().unwrap_or_default();
    SPINNER.contains(&glyph)
        && word.ends_with('…')
        && word.trim_end_matches('…').chars().all(char::is_alphabetic)
        && word.len() > '…'.len_utf8()
}

/// The banner's logo: the block characters before its text.
fn strip_logo(row: &str) -> &str {
    row.trim_start_matches(|c: char| " ▐▛▜▌▝▘▀▄▗▖█▙▟\u{a0}".contains(c)).trim_end()
}

impl ScreenFacts {
    /// Reads Claude Code's screen (2.1.320 and later, full-screen).
    pub fn read(grid: &Grid) -> ScreenFacts {
        let mut facts = ScreenFacts::default();
        let rows: Vec<String> = (0..grid.cells.len()).map(|y| grid.row_text(y)).collect();
        for (y, row) in rows.iter().enumerate() {
            if let Some(at) = row.find("Claude Code v") {
                let version = row.get(at + "Claude Code v".len()..).unwrap_or_default();
                let version: String =
                    version.chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect();
                if !version.is_empty() {
                    facts.version = Some(version);
                    let line = |dy: usize| {
                        rows.get(y + dy).map(|r| strip_logo(r).to_owned()).filter(|s| !s.is_empty())
                    };
                    facts.model_line = line(1);
                    facts.cwd = line(2);
                }
            }
            let trimmed = row.trim_start();
            if let Some(rest) = trimmed.strip_prefix("⏵⏵ ") {
                let end =
                    [" (", " ·"].iter().filter_map(|s| rest.find(s)).min().unwrap_or(rest.len());
                facts.mode = Some(rest.get(..end).unwrap_or(rest).trim().to_owned());
                facts.running = rest.contains("esc to interrupt");
            }
            if let Some(at) = row.find(" · /effort") {
                let effort =
                    row.get(..at).unwrap_or_default().rsplit(' ').next().unwrap_or_default();
                if !effort.is_empty() {
                    facts.effort = Some(effort.to_owned());
                }
            }
            if let Some(rest) = trimmed.strip_prefix("✻ ")
                && let Some((verb, _)) = rest.split_once(" for ")
                && !verb.is_empty()
                && verb.chars().all(char::is_alphabetic)
            {
                facts.done_verb = Some(verb.to_owned());
            }
        }
        if rows.iter().any(|r| r.contains("esc to interrupt")) {
            facts.running = true;
        }
        if let Some(y) = rows.iter().rposition(|r| is_spinner(r))
            && let Some(cells) = grid.cells.get(y)
        {
            let mut cells = cells.clone();
            while cells.last().is_some_and(Cell::is_blank) {
                cells.pop();
            }
            facts.spinner = Some(cells);
        }
        // A notice: the run of `▎` rows nearest the banner's end.
        let start = rows.iter().position(|r| r.starts_with('▎'));
        if let Some(start) = start {
            for (row, text) in grid.cells.iter().zip(&rows).skip(start) {
                if !text.starts_with('▎') {
                    break;
                }
                let mut cells = row.clone();
                while cells.last().is_some_and(Cell::is_blank) {
                    cells.pop();
                }
                facts.notice.push(cells);
            }
        }
        // The prompt: the last `❯` row with a rule above it, its draft running to the rule below.
        let prompt = (1..rows.len()).rev().find(|&y| {
            let row = rows.get(y).map_or("", String::as_str);
            (row.starts_with("❯\u{a0}") || row.starts_with("❯ ") || row == "❯")
                && rows.get(y - 1).is_some_and(|above| above.starts_with('─'))
        });
        if let Some(y) = prompt {
            facts.prompt_seen = true;
            let mut dim = String::new();
            let mut typed: Vec<String> = Vec::new();
            for (i, row) in grid.cells.get(y..).unwrap_or_default().iter().enumerate() {
                if i > 0 && rows.get(y + i).is_some_and(|r| r.starts_with('─')) {
                    break;
                }
                let mut line = String::new();
                let cells: Vec<&Cell> = row.iter().skip(2).collect();
                for (x, cell) in cells.iter().enumerate() {
                    let text = if cell.text.is_empty() { " " } else { cell.text.as_str() };
                    // The cursor sits on an empty prompt's first placeholder letter, which
                    // is then drawn plain (or inverse) rather than dim: it belongs to the
                    // placeholder when the rest of the row is dim.
                    let cursor_on_dim = x == 0
                        && !cell.is_blank()
                        && cells.get(1).is_some_and(|next| next.style.attrs & FAINT != 0)
                        && cells
                            .iter()
                            .skip(1)
                            .filter(|c| !c.is_blank())
                            .all(|c| c.style.attrs & FAINT != 0);
                    if i == 0 && (cell.style.attrs & FAINT != 0 || cursor_on_dim) {
                        dim.push_str(text);
                    } else {
                        line.push_str(text);
                    }
                }
                let line = line.replace('\u{a0}', " ").trim().to_owned();
                if !line.is_empty() {
                    typed.push(line);
                }
            }
            facts.draft = typed.join(" ");
            let dim = dim.trim().to_owned();
            if facts.draft.is_empty() && !dim.is_empty() {
                facts.placeholder = Some(dim);
            }
        }
        facts
    }

    /// Updates `chrome` with what this look found: the banner's and footer's facts only when
    /// seen (they persist), the prompt's every time the prompt is on screen.
    pub fn apply(&self, chrome: &mut Chrome) {
        let keep = |slot: &mut Option<String>, fact: &Option<String>| {
            if fact.is_some() {
                slot.clone_from(fact);
            }
        };
        keep(&mut chrome.version, &self.version);
        keep(&mut chrome.model_line, &self.model_line);
        keep(&mut chrome.cwd, &self.cwd);
        keep(&mut chrome.effort, &self.effort);
        keep(&mut chrome.done_verb, &self.done_verb);
        if let Some(mode) = &self.mode {
            chrome.mode.clone_from(mode);
        }
        if self.prompt_seen {
            chrome.draft.clone_from(&self.draft);
            chrome.placeholder.clone_from(&self.placeholder);
        }
        chrome.spinner.clone_from(&self.spinner);
        if !self.notice.is_empty() {
            chrome.notice = Some(self.notice.clone());
        }
    }
}
