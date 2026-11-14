//! The numbered options of a startup dialog on an agent's screen, and the
//! keys that pick the accepting one (W5-Q, bench round 4 orchestration
//! friction 7).
//!
//! Claude's folder-trust dialog draws its choices as numbered lines with the
//! cursor (`❯`) on one of them; Enter picks the line under the cursor. The
//! `agent start` result lists them, so the orchestrator can show the person
//! the question and, with their consent, answer with `cmux terminal NAME
//! keys ...` instead of guessing.

use serde_json::{Value, json};

/// How many of the screen's last non-blank rows hold the options at most.
const OPTION_ROWS: usize = 16;
/// Cursor marks a dialog draws before the selected option.
const CURSORS: [char; 3] = ['❯', '>', '›'];

/// One numbered option of a dialog.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct DialogOption {
    pub number: u32,
    pub label: String,
    pub selected: bool,
}

impl DialogOption {
    pub(in crate::cli) fn to_json(&self) -> Value {
        json!({"number": self.number, "label": self.label, "selected": self.selected})
    }
}

/// `row` as a numbered option: an optional cursor, the number, `.`, the label.
fn option(row: &str) -> Option<DialogOption> {
    let row =
        row.trim_start_matches(|character: char| character.is_whitespace() || character == '│');
    let (selected, rest) = match row.strip_prefix(CURSORS) {
        Some(rest) => (true, rest.trim_start()),
        None => (false, row),
    };
    let digits = rest.find(|character: char| !character.is_ascii_digit())?;
    let number = rest.get(..digits)?.parse().ok()?;
    // A dialog drawn in a box ends the row with `│`.
    let label = rest
        .get(digits..)?
        .strip_prefix(". ")?
        .trim_end_matches(|character: char| character.is_whitespace() || character == '│')
        .trim();
    (!label.is_empty()).then(|| DialogOption { number, label: label.to_owned(), selected })
}

/// The last run of options numbered 1, 2, 3, ... at the bottom of `screen`.
pub(in crate::cli) fn options(screen: &str) -> Vec<DialogOption> {
    let rows: Vec<&str> = screen.lines().filter(|row| !row.trim().is_empty()).collect();
    let bottom = rows.get(rows.len().saturating_sub(OPTION_ROWS)..).unwrap_or_default();
    let mut found: Vec<DialogOption> = Vec::new();
    let mut run: Vec<DialogOption> = Vec::new();
    for row in bottom {
        let next = option(row);
        let continues = match (&next, run.last()) {
            (Some(next), Some(last)) => last.number.checked_add(1) == Some(next.number),
            _ => false,
        };
        if !continues && run.len() >= 2 {
            found = std::mem::take(&mut run);
        }
        match next {
            Some(next) if continues => run.push(next),
            Some(next) if next.number == 1 => run = vec![next],
            _ => run.clear(),
        }
    }
    if run.len() >= 2 { run } else { found }
}

/// The keys that move the cursor from the selected option to the first one
/// whose label starts with "Yes" and press Enter; `None` without such an
/// option.
pub(in crate::cli) fn accept_keys(options: &[DialogOption]) -> Option<Vec<&'static str>> {
    let accept = options.iter().position(accepts)?;
    let selected = options.iter().position(|option| option.selected).unwrap_or(0);
    let (key, moves) =
        if accept < selected { ("up", selected - accept) } else { ("down", accept - selected) };
    let mut keys = vec![key; moves];
    keys.push("enter");
    Some(keys)
}

/// Whether [`accept_keys`] picks `option`: the first label that starts
/// with "yes" is picked.
fn accepts(option: &DialogOption) -> bool {
    option.label.to_lowercase().starts_with("yes")
}

/// The label of the option [`accept_keys`] picks; `None` without one.
pub(in crate::cli) fn accept_label(options: &[DialogOption]) -> Option<&str> {
    options.iter().find(|option| accepts(option)).map(|option| option.label.as_str())
}

/// Words of an option that also lets the agent act without approval (a
/// Codex "... without asking for approval" choice), lower case.
const NO_APPROVAL: &[&str] = &[
    "without asking",
    "without approval",
    "bypass",
    "dangerous",
    "don't ask",
    "do not ask",
    "full access",
    "auto-approve",
    "auto approve",
];

/// The folder-trust `reason` for the terminal `who`: ask the person, then
/// answer with `cmux terminal WHO keys`. With `accept` (the keys and the
/// label they pick) it names both, and it warns when that label also turns
/// approvals off.
pub(in crate::cli) fn folder_trust_reason(
    messages: &crate::localization::PaneCliMessages,
    who: &str,
    accept: Option<(&[&str], &str)>,
) -> String {
    let Some((keys, label)) = accept else {
        return messages.folder_trust_ask.replace("{who}", who);
    };
    let mut reason = messages
        .folder_trust_keys
        .replace("{who}", who)
        .replace("{keys}", &keys.join(" "))
        .replace("{label}", label);
    let lower = label.to_lowercase();
    if NO_APPROVAL.iter().any(|words| lower.contains(words)) {
        reason.push_str(messages.folder_trust_separator);
        reason.push_str(&messages.folder_trust_no_approval.replace("{label}", label));
    }
    reason
}

#[cfg(test)]
mod tests;
