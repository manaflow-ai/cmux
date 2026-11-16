//! Toggle Terminal and Chat's approval: while the terminal drives a session, the harness's own
//! approval dialog shows in the paired chat and is answered from it (Leo, 2026-11-12: two live
//! views of one session, instant both ways). The app reads the terminal's viewport, one line per
//! row, and asks here; the chat draws the dialog as its permission card, and a click comes back as
//! the option's number, which [`answer_keys`] turns into the keys the terminal gets.
//!
//! The dialogs read are the numbered ones Claude Code and Codex draw at the bottom of the screen:
//! a question, the rows that say what it is about, and options `1. …`, `2. …` with a cursor
//! (`❯`, `›`, `>`) on one of them, then at most a few hint rows. A numbered list in an answer has
//! no cursor and is followed by the prompt box, so it is never a dialog.

use serde::{Deserialize, Serialize};

/// Cursor marks a dialog draws before its selected option.
const CURSORS: [char; 3] = ['❯', '›', '>'];
/// Box and bar glyphs a dialog draws at a row's edges.
const EDGES: &[char] = &['│', '┃', '║', '▌', '▎'];
/// How many of the screen's last non-blank rows can hold a dialog's options.
const OPTION_ROWS: usize = 24;
/// How many non-blank rows may follow the options (hints such as "Esc to cancel").
const HINT_ROWS: usize = 3;
/// The most rows a dialog's question may sit above its first option.
const QUESTION_ROWS: usize = 12;
/// The most rows of what the dialog is about, and the longest of each.
const DETAIL_ROWS: usize = 12;
const DETAIL_CHARS: usize = 400;

/// The terminal's viewport, one line per row.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ApprovalScreen {
    pub screen: String,
}

/// A click on the chat's card: the option it picked, with its label and the [`TerminalApproval::id`]
/// of the dialog the card showed, against the terminal's viewport read again now.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ApprovalAnswer {
    pub screen: String,
    pub key: u32,
    pub label: String,
    pub id: String,
}

/// A harness's approval dialog on the terminal's screen.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalApproval {
    /// What the dialog asks, whole: its question, heading, command, every body row (before any
    /// clip) and its options, but not where the cursor is. Two dialogs that ask the same question
    /// about different commands differ here, so a card's click never answers a dialog it did not show.
    pub id: String,
    /// "Do you want to proceed?", "Would you like to run the following command?".
    pub question: String,
    /// The dialog's heading row above its body ("Bash command", "Edit file"), when it has one.
    pub header: Option<String>,
    /// The command it asks to run: Claude Code's first row under a "… command" heading, Codex's
    /// `$ …` row.
    pub command: Option<String>,
    /// The dialog's other rows, in order (a description, Codex's "Reason: …", a diff).
    pub detail: Vec<String>,
    pub options: Vec<ApprovalOption>,
}

/// One option of a dialog.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalOption {
    /// The number the dialog draws before it.
    pub key: u32,
    /// The label without its key hint.
    pub label: String,
    /// The key hint the dialog draws after the label (`y`, `esc`, `shift+tab`).
    pub hint: Option<String>,
    /// As an ACP option reads: `allow_once`, `allow_always`, `reject_once`, or `other`.
    pub kind: &'static str,
    /// The cursor is on it: Enter alone picks it.
    pub selected: bool,
}

/// One screen row as a dialog reads it.
struct Row {
    /// The row without its box edges, trimmed.
    text: String,
    /// Leading spaces after the box edge.
    indent: usize,
}

impl Row {
    fn read(line: &str) -> Row {
        let line = line.trim_end_matches(|c: char| c.is_whitespace() || EDGES.contains(&c));
        let start = line.trim_start_matches(' ');
        // A boxed row's indent counts from its edge.
        let inner = start.strip_prefix(EDGES).unwrap_or(line);
        let indent = inner.chars().take_while(|c| *c == ' ').count();
        Row { text: inner.trim().to_owned(), indent }
    }

    fn blank(&self) -> bool {
        self.text.is_empty()
    }

    /// A rule or a box's top or bottom: the dialog's edge.
    fn rule(&self) -> bool {
        !self.text.is_empty()
            && self.text.chars().count() >= 3
            && self.text.chars().all(|c| "─━═╭╮╰╯┌┐└┘┏┓┗┛-".contains(c))
    }

    /// A dashed rule inside a dialog (Claude Code's diff frame): part of the dialog.
    fn dashed(&self) -> bool {
        !self.text.is_empty() && self.text.chars().all(|c| "╌┄┈╍┅┉ ".contains(c))
    }

    /// A transcript row above a dialog: an answer's or a tool call's bullet, a prompt's mark.
    fn transcript(&self) -> bool {
        self.text.starts_with(['⏺', '●', '•', '◦', '✻', '✶', '⎿'])
            || CURSORS.iter().any(|c| self.text.starts_with(*c))
    }

    /// A hint row below the options ("Esc to cancel · Tab to amend", "Press enter to confirm").
    fn hint(&self) -> bool {
        let lower = self.text.to_lowercase();
        self.rule()
            || ["esc", "enter", "tab", "ctrl", "↑", "↓", "navigate", "cancel", "confirm"]
                .iter()
                .any(|word| lower.contains(word))
    }
}

/// `row` as a numbered option: an optional cursor, the number, `.`, the label.
fn option(row: &Row) -> Option<ApprovalOption> {
    let (selected, rest) = match row.text.strip_prefix(CURSORS) {
        Some(rest) => (true, rest.trim_start()),
        None => (false, row.text.as_str()),
    };
    let digits = rest.find(|c: char| !c.is_ascii_digit())?;
    let key: u32 = rest.get(..digits)?.parse().ok()?;
    let label = rest.get(digits..)?.strip_prefix(". ")?.trim();
    if label.is_empty() {
        return None;
    }
    let (label, hint) = split_hint(label);
    Some(ApprovalOption { key, kind: kind(&label), label, hint, selected })
}

/// A label's trailing key hint, `(y)`, `(esc)`, `(shift+tab)`: short, with no space.
fn split_hint(label: &str) -> (String, Option<String>) {
    if let Some(open) = label.rfind(" (")
        && label.ends_with(')')
    {
        let hint = label.get(open.saturating_add(2)..label.len().saturating_sub(1)).unwrap_or("");
        if !hint.is_empty()
            && hint.chars().count() <= 12
            && !hint.contains(' ')
            && let Some(head) = label.get(..open)
        {
            return (head.trim_end().to_owned(), Some(hint.to_owned()));
        }
    }
    (label.to_owned(), None)
}

/// What an option does, from its words, as an ACP option's kind.
fn kind(label: &str) -> &'static str {
    let lower = label.to_lowercase();
    let starts = |words: &[&str]| words.iter().any(|w| lower.starts_with(w));
    if starts(&["yes", "allow", "approve", "proceed", "accept"]) {
        let lasting =
            ["don't ask again", "do not ask again", "always", "allow all", "this session"];
        if lasting.iter().any(|w| lower.contains(w)) { "allow_always" } else { "allow_once" }
    } else if starts(&["no", "deny", "reject", "decline", "cancel", "abort"]) {
        "reject_once"
    } else {
        "other"
    }
}

/// The dialog at the bottom of `screen`, or None.
pub fn terminal_approval(facts: &ApprovalScreen) -> Option<TerminalApproval> {
    let rows: Vec<Row> = facts.screen.lines().map(Row::read).collect();
    let filled: Vec<usize> =
        rows.iter().enumerate().filter(|(_, r)| !r.blank()).map(|(i, _)| i).collect();
    let window = filled.get(filled.len().saturating_sub(OPTION_ROWS)..).unwrap_or_default();
    // The last run of options numbered 1, 2, 3, ... in a row (blank rows between are fine).
    let mut run: Vec<(usize, ApprovalOption)> = Vec::new();
    let mut found: Vec<(usize, ApprovalOption)> = Vec::new();
    for &at in window {
        let next = rows.get(at).and_then(option);
        let continues = matches!((&next, run.last()),
            (Some(n), Some((_, last))) if last.key.checked_add(1) == Some(n.key));
        if !continues && run.len() >= 2 {
            found = std::mem::take(&mut run);
        }
        match next {
            Some(n) if continues => run.push((at, n)),
            Some(n) if n.key == 1 => run = vec![(at, n)],
            _ => run.clear(),
        }
    }
    if run.len() >= 2 {
        found = run;
    }
    let (first, last) = (found.first()?.0, found.last()?.0);
    // A dialog's cursor is on exactly one option.
    if found.iter().filter(|(_, o)| o.selected).count() != 1 {
        return None;
    }
    // Below the options: a few hints at most, never the prompt box or more transcript.
    let below: Vec<&Row> = rows
        .get(last.saturating_add(1)..)
        .unwrap_or_default()
        .iter()
        .filter(|r| !r.blank())
        .collect();
    if below.len() > HINT_ROWS || !below.iter().all(|r| r.hint()) {
        return None;
    }
    // The question: the nearest row ending in `?` above the first option.
    let above: Vec<usize> =
        filled.iter().copied().filter(|&i| i < first).rev().take(QUESTION_ROWS).collect();
    let question_at = above
        .iter()
        .copied()
        .take_while(|&i| rows.get(i).is_some_and(|r| !r.rule()))
        .find(|&i| rows.get(i).is_some_and(|r| r.text.ends_with('?')))?;
    let question = rows.get(question_at)?;
    // Between the question and the options (Codex's reason and command).
    let after: Vec<&Row> = rows
        .get(question_at.saturating_add(1)..first)
        .unwrap_or_default()
        .iter()
        .filter(|r| !r.blank())
        .collect();
    // Above the question, up to the dialog's edge: its heading and body (Claude Code's).
    let mut before: Vec<&Row> = Vec::new();
    let mut blanks = 0_u8;
    for row in rows.get(..question_at).unwrap_or_default().iter().rev() {
        if row.blank() {
            blanks = blanks.saturating_add(1);
            if blanks >= 2 {
                break;
            }
            continue;
        }
        blanks = 0;
        if row.rule() || row.transcript() || before.len() >= DETAIL_ROWS {
            break;
        }
        if !row.dashed() {
            before.push(row);
        }
    }
    before.reverse();
    // A heading sits at the question's indent, its body deeper.
    let header = before
        .first()
        .filter(|r| r.indent <= question.indent && before.len() > 1)
        .map(|r| r.text.clone());
    let body = before.get(usize::from(header.is_some())..).unwrap_or_default();
    let mut detail: Vec<String> = Vec::new();
    let mut command = None;
    if header.as_deref().is_some_and(|h| h.to_lowercase().ends_with("command"))
        && let Some(first) = body.first()
    {
        command = Some(first.text.clone());
        detail.extend(body.get(1..).unwrap_or_default().iter().map(|r| r.text.clone()));
    } else {
        detail.extend(body.iter().map(|r| r.text.clone()));
    }
    for row in after {
        match row.text.strip_prefix("$ ") {
            Some(c) if command.is_none() => command = Some(c.trim().to_owned()),
            _ => detail.push(row.text.clone()),
        }
    }
    let options: Vec<ApprovalOption> = found.into_iter().map(|(_, o)| o).collect();
    let id = dialog_id(&question.text, header.as_deref(), command.as_deref(), &detail, &options);
    let clip = |t: String| {
        if t.chars().count() > DETAIL_CHARS { t.chars().take(DETAIL_CHARS).collect() } else { t }
    };
    detail.truncate(DETAIL_ROWS);
    Some(TerminalApproval {
        id,
        question: question.text.clone(),
        header,
        command: command.map(clip),
        detail: detail.into_iter().map(clip).collect(),
        options,
    })
}

/// [`TerminalApproval::id`]: FNV-1a (64-bit) over the dialog's parts, each ended by a separator
/// no row holds, so moving text between parts changes it too.
fn dialog_id(
    question: &str,
    header: Option<&str>,
    command: Option<&str>,
    detail: &[String],
    options: &[ApprovalOption],
) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut part = |text: &str| {
        for byte in text.bytes().chain([0x1f]) {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
        }
    };
    part(question);
    part(header.unwrap_or("\u{1e}"));
    part(command.unwrap_or("\u{1e}"));
    detail.iter().for_each(|row| part(row));
    part("\u{1d}");
    for option in options {
        part(&option.key.to_string());
        part(&option.label);
        part(option.hint.as_deref().unwrap_or(""));
    }
    format!("{hash:016x}")
}

/// The keys that pick option `key` of the dialog on `screen` now: the cursor moves to it and
/// Enter picks it. None when the screen no longer shows that dialog (its [`TerminalApproval::id`]:
/// answered in the terminal meanwhile, or another dialog, even one asking the same question about
/// another command) with that option, so a click never answers what it did not show.
pub fn answer_keys(answer: &ApprovalAnswer) -> Option<Vec<&'static str>> {
    let shown = terminal_approval(&ApprovalScreen { screen: answer.screen.clone() })?;
    if answer.id.is_empty() || shown.id != answer.id {
        return None;
    }
    let target =
        shown.options.iter().position(|o| o.key == answer.key && o.label == answer.label)?;
    let selected = shown.options.iter().position(|o| o.selected)?;
    let (key, moves) = if target < selected {
        ("up", selected.abs_diff(target))
    } else {
        ("down", target.abs_diff(selected))
    };
    let mut keys = vec![key; moves];
    keys.push("enter");
    Some(keys)
}

#[cfg(test)]
#[path = "tabs_approval_tests.rs"]
mod tests;
