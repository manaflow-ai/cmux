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
    let label = rest.get(digits..)?.strip_prefix(". ")?.trim();
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
    let accept =
        options.iter().position(|option| option.label.to_lowercase().starts_with("yes"))?;
    let selected = options.iter().position(|option| option.selected).unwrap_or(0);
    let (key, moves) =
        if accept < selected { ("up", selected - accept) } else { ("down", accept - selected) };
    let mut keys = vec![key; moves];
    keys.push("enter");
    Some(keys)
}

/// The label of the option [`accept_keys`] picks; `None` without one.
#[cfg_attr(not(test), allow(dead_code))]
pub(in crate::cli) fn accept_label(_options: &[DialogOption]) -> Option<&str> {
    None
}

/// The folder-trust `reason` for the terminal `who`: ask the person, then
/// answer with `cmux terminal WHO keys`. With `accept` (the keys and the
/// label they pick) it names both, and it warns when that label also turns
/// approvals off.
#[cfg_attr(not(test), allow(dead_code))]
pub(in crate::cli) fn folder_trust_reason(
    _messages: &crate::localization::PaneCliMessages,
    who: &str,
    accept: Option<(&[&str], &str)>,
) -> String {
    match accept {
        Some((keys, _)) => format!(
            "the agent asks whether you trust this folder; ask the person, and when they \
             agree run cmux terminal {who} keys {} (cmux never answers it on its own)",
            keys.join(" ")
        ),
        None => "the agent asks whether you trust this folder; ask the person, then answer \
                 it with cmux terminal NAME keys (cmux never answers it on its own)"
            .to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn w5q_options_read_the_last_numbered_run_and_its_cursor() {
        let screen = " Pick one\n 1. not this list\n 2. either\n\n ❯ 1. Yes, proceed\n   2. No, exit\n\n Enter to confirm";
        let read = options(screen);
        assert_eq!(
            read,
            [
                DialogOption { number: 1, label: "Yes, proceed".into(), selected: true },
                DialogOption { number: 2, label: "No, exit".into(), selected: false },
            ]
        );
        assert_eq!(accept_keys(&read), Some(vec!["enter"]));
        assert!(options("⏺ 1. a numbered line alone").is_empty());
        let none_yes = options(" ❯ 1. No, exit\n   2. Maybe");
        assert_eq!(accept_keys(&none_yes), None);
        let below = options(" ❯ 1. No, exit\n   2. Later\n   3. Yes, I trust this folder");
        assert_eq!(accept_keys(&below), Some(vec!["down", "down", "enter"]));
    }

    /// W5-Q review (PR C): the person approves the exact text the keys
    /// pick, so the result names it (`accept_label`).
    #[test]
    fn w5q_the_accept_label_is_the_option_the_keys_pick() {
        let below = options(" ❯ 1. No, exit\n   2. Later\n   3. Yes, I trust this folder");
        assert_eq!(accept_label(&below), Some("Yes, I trust this folder"));
        assert_eq!(accept_label(&options(" ❯ 1. No, exit\n   2. Maybe")), None);
    }

    /// W5-Q review (PR C): the folder-trust reason is localized, names the
    /// terminal (never the placeholder `NAME`), names the option the keys
    /// pick, and warns when that option also turns approvals off (a Codex
    /// "... without asking for approval" choice).
    #[test]
    fn w5q_the_folder_trust_reason_names_the_choice_and_warns_on_no_approval() {
        let english = &crate::localization::catalog_for_locale("en_US.UTF-8").pane_cli;
        let japanese = &crate::localization::catalog_for_locale("ja_JP.UTF-8").pane_cli;
        let plain = "Yes, I trust this folder";
        let risky = "Yes, allow Codex to work in this folder without asking for approval";
        let keys: &[&str] = &["up", "enter"];
        for messages in [english, japanese] {
            let asked = folder_trust_reason(messages, "beta", None);
            assert!(!asked.contains("NAME"), "{asked}");
            assert!(asked.contains("cmux terminal beta keys"), "{asked}");
            let named = folder_trust_reason(messages, "beta", Some((keys, plain)));
            assert!(named.contains("cmux terminal beta keys up enter"), "{named}");
            assert!(named.contains(plain), "{named}");
        }
        let en = folder_trust_reason(english, "beta", Some((keys, plain)));
        let ja = folder_trust_reason(japanese, "beta", Some((keys, plain)));
        assert_ne!(en, ja, "the Japanese reason is Japanese");
        assert!(!en.contains("warning:"), "{en}");
        let warned = folder_trust_reason(english, "beta", Some((keys, risky)));
        assert!(warned.contains("warning:"), "{warned}");
        let warned = folder_trust_reason(japanese, "beta", Some((keys, risky)));
        assert!(warned.contains("警告"), "{warned}");
    }
}
