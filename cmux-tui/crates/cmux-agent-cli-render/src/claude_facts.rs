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
use crate::{FAINT, Grid};

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
                let version = &row[at + "Claude Code v".len()..];
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
                facts.mode = Some(rest[..end].trim().to_owned());
                facts.running = rest.contains("esc to interrupt");
            }
            if let Some(at) = row.find(" · /effort") {
                let effort = row[..at].rsplit(' ').next().unwrap_or_default();
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
        // The prompt: the last `❯` row with a rule above it, its draft running to the rule below.
        let prompt = (1..rows.len()).rev().find(|&y| {
            (rows[y].starts_with("❯\u{a0}") || rows[y].starts_with("❯ ") || rows[y] == "❯")
                && rows[y - 1].starts_with('─')
        });
        if let Some(y) = prompt {
            facts.prompt_seen = true;
            let mut dim = String::new();
            let mut typed: Vec<String> = Vec::new();
            for (i, row) in grid.cells[y..].iter().enumerate() {
                if i > 0 && rows[y + i].starts_with('─') {
                    break;
                }
                let mut line = String::new();
                for cell in row.iter().skip(2) {
                    let text = if cell.text.is_empty() { " " } else { cell.text.as_str() };
                    if cell.style.attrs & FAINT != 0 && i == 0 {
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
    }
}
