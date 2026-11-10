//! The options of a dialog on an agent's screen, and the keys that pick
//! each one (W5-Q, bench round 4 orchestration friction 7; W6-B, bench
//! round 5 orchestration row 3).
//!
//! An agent's dialog draws its choices as rows with the cursor (`❯`) on one
//! of them; Enter picks the row under the cursor. Older Claude Code builds
//! number the rows (`❯ 1. Yes, proceed`); Claude Code 2.1.321 draws its
//! folder-trust choices without numbers (`❯ No, exit` above `Yes, I trust
//! this folder`), the other rows indented to the cursor row's label. Both
//! are read, and each option carries the keys (Up or Down, then Enter) that
//! pick it from where the cursor is. The `agent start` result lists them,
//! so the orchestrator can show the person the question and, with their
//! consent, answer with `cmux terminal NAME keys ...` instead of guessing.

use serde_json::{Value, json};

use super::super::terminal_talk::roster;
use super::readiness;

/// How many of the screen's last non-blank rows hold the options at most.
const OPTION_ROWS: usize = 16;
/// Cursor marks a dialog draws before the selected option.
const CURSORS: [char; 3] = ['❯', '>', '›'];

/// One option of a dialog.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct DialogOption {
    /// The number the dialog draws, or the option's position (from 1) when
    /// it draws none.
    pub number: u32,
    pub label: String,
    pub selected: bool,
}

/// `options` as JSON: `{number, label, selected, keys}` each, `keys` being
/// the keys that pick that option ([`keys_to`]).
pub(in crate::cli) fn options_json(options: &[DialogOption]) -> Value {
    let listed = options.iter().enumerate().map(|(index, option)| {
        json!({
            "number": option.number,
            "label": option.label,
            "selected": option.selected,
            "keys": keys_to(options, index),
        })
    });
    Value::Array(listed.collect())
}

/// The keys that move the cursor from the selected option (the first one
/// when none is marked) to `options[target]` and press Enter.
pub(in crate::cli) fn keys_to(options: &[DialogOption], target: usize) -> Vec<&'static str> {
    let selected = options.iter().position(|option| option.selected).unwrap_or(0);
    let (key, moves) =
        if target < selected { ("up", selected - target) } else { ("down", target - selected) };
    let mut keys = vec![key; moves];
    keys.push("enter");
    keys
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

/// The options at the bottom of `screen`: the last run numbered 1, 2, 3,
/// ..., else the unnumbered rows around the last cursor row ([`unnumbered`]).
pub(in crate::cli) fn options(screen: &str) -> Vec<DialogOption> {
    let numbered = numbered(screen);
    if numbered.is_empty() { unnumbered(screen) } else { numbered }
}

/// The last run of options numbered 1, 2, 3, ... at the bottom of `screen`.
fn numbered(screen: &str) -> Vec<DialogOption> {
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

/// Box and padding characters around a dialog row's text.
fn padding(character: char) -> bool {
    character.is_whitespace() || character == '│'
}

/// A row's text without the box a dialog may draw around it (`│` and the
/// padding at both ends), and the column (in characters) where that text
/// starts.
fn unboxed(row: &str) -> (usize, &str) {
    let text = row.trim_start_matches(padding);
    (row.chars().count() - text.chars().count(), text.trim_end_matches(padding))
}

/// A cursor row: `❯ label` (or `>`, `›`), and the column of its label.
fn cursor_row(row: &str) -> Option<(usize, &str)> {
    let (column, text) = unboxed(row);
    let mark = text.chars().next().filter(|mark| CURSORS.contains(mark))?;
    let rest = &text[mark.len_utf8()..];
    let label = rest.trim_start();
    let gap = rest.chars().count() - label.chars().count();
    (gap > 0 && !label.is_empty()).then_some((column + 1 + gap, label))
}

/// A horizontal rule, as an agent's input box draws above and below its
/// prompt.
fn rule(row: &str) -> bool {
    row.chars().filter(|character| matches!(character, '─' | '━' | '═')).count() >= 10
}

/// The options of a dialog that draws no numbers: the last cursor row among
/// the bottom [`OPTION_ROWS`] non-blank rows and the rows right above and
/// below it (no blank row between) whose text starts at that row's label
/// column. A cursor row next to a rule, or rows with an input box's hint,
/// are an input box, not a dialog, and fewer than two rows are no choice.
fn unnumbered(screen: &str) -> Vec<DialogOption> {
    let rows: Vec<&str> = screen.lines().collect();
    let non_blank: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, row)| !row.trim().is_empty())
        .map(|(at, _)| at)
        .collect();
    let bottom = non_blank.get(non_blank.len().saturating_sub(OPTION_ROWS)..).unwrap_or_default();
    let Some((at, (column, label))) =
        bottom.iter().rev().find_map(|at| Some((*at, cursor_row(rows[*at])?)))
    else {
        return Vec::new();
    };
    let near_rule = [at.checked_sub(1), at.checked_add(1)]
        .into_iter()
        .flatten()
        .filter_map(|other| rows.get(other))
        .any(|row| rule(row));
    if near_rule {
        return Vec::new();
    }
    // A sibling row: its text starts at the label column, with no cursor,
    // no number and no rule.
    let sibling = |row: &str| {
        let (start, text) = unboxed(row);
        let plain = cursor_row(row).is_none() && option(row).is_none() && !rule(row);
        (start == column && !text.is_empty() && plain).then(|| text.to_owned())
    };
    let above: Vec<String> = rows[..at].iter().rev().map_while(|row| sibling(row)).collect();
    let below = rows[at + 1..].iter().map_while(|row| sibling(row));
    let labels: Vec<(String, bool)> = above
        .into_iter()
        .rev()
        .map(|label| (label, false))
        .chain(std::iter::once((label.to_owned(), true)))
        .chain(below.map(|label| (label, false)))
        .collect();
    // An input box's hint row (`⏎ send`, `? for shortcuts`) is no choice.
    let joined = labels.iter().map(|(label, _)| label.as_str()).collect::<Vec<_>>().join("\n");
    if labels.len() < 2 || readiness::composer_visible(&joined) {
        return Vec::new();
    }
    labels
        .into_iter()
        .zip(1..)
        .map(|((label, selected), number)| DialogOption { number, label, selected })
        .collect()
}

/// The keys that move the cursor from the selected option to the first one
/// whose label starts with "Yes" and press Enter; `None` without such an
/// option.
pub(in crate::cli) fn accept_keys(options: &[DialogOption]) -> Option<Vec<&'static str>> {
    Some(keys_to(options, options.iter().position(accepts)?))
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

/// Footer hints (lower case) that say Escape cancels the dialog.
const ESCAPE_HINTS: &[&str] = &["esc to cancel", "esc to deny", "esc to reject", "esc to exit"];

/// Label starts (lower case) of an option that says no.
const DENY_LABELS: &[&str] = &["no", "deny", "reject", "cancel", "don't", "do not"];

/// The bottom [`OPTION_ROWS`] non-blank rows of `screen`.
fn bottom_rows(screen: &str) -> Vec<&str> {
    let rows: Vec<&str> = screen.lines().filter(|row| !row.trim().is_empty()).collect();
    rows.get(rows.len().saturating_sub(OPTION_ROWS)..).unwrap_or_default().to_vec()
}

/// The keys that turn the dialog down: Escape when its footer says Escape
/// cancels it, else the keys that pick its first option that says no;
/// `None` when neither shows.
pub(in crate::cli) fn deny_keys(
    screen: &str,
    options: &[DialogOption],
) -> Option<Vec<&'static str>> {
    let footer = bottom_rows(screen).join(" ").to_lowercase();
    if ESCAPE_HINTS.iter().any(|hint| footer.contains(hint)) {
        return Some(vec!["escape"]);
    }
    let says_no = |option: &DialogOption| {
        let label = option.label.to_lowercase();
        DENY_LABELS.iter().any(|word| {
            label.strip_prefix(word).is_some_and(|rest| {
                rest.is_empty() || rest.starts_with(|next: char| !next.is_alphanumeric())
            })
        })
    };
    Some(keys_to(options, options.iter().position(says_no)?))
}

/// The question the dialog asks: the lowest of the bottom rows above its
/// options that holds a `?` at the end of a word, up to the last such `?`
/// (`Do you want to proceed?`). A lone `?` is a key in a footer hint
/// (`? for shortcuts`), not a question.
fn question(screen: &str) -> Option<String> {
    bottom_rows(screen).iter().rev().find_map(|row| {
        if option(row).is_some() || cursor_row(row).is_some() {
            return None;
        }
        let (_, text) = unboxed(row);
        let (end, _) = text.char_indices().rfind(|(index, character)| {
            *character == '?'
                && text[..*index].chars().next_back().is_some_and(char::is_alphanumeric)
        })?;
        let asked = text[..=end].trim();
        (asked.len() > 1).then(|| asked.to_owned())
    })
}

/// The dialog a blocked agent shows, as every blocked result has it
/// (`agent start`, `terminal send`, `terminal wait`, `terminal status`,
/// `agents dialog list`): `kind`, `msg` (the given one, else the question on
/// the screen), `options` (each with the `keys` that pick it), `deny_keys`,
/// and for `folder_trust` the `accept_keys` and `accept_label`.
pub(in crate::cli) fn dialog_json(kind: &str, msg: Option<&str>, screen: &str) -> Value {
    let options = options(screen);
    let msg =
        msg.filter(|msg| !msg.trim().is_empty()).map(str::to_owned).or_else(|| question(screen));
    let mut dialog = json!({
        "kind": kind,
        "msg": msg,
        "options": options_json(&options),
        "deny_keys": deny_keys(screen, &options),
    });
    if kind == "folder_trust"
        && let (Some(keys), Some(label)) = (accept_keys(&options), accept_label(&options))
        && let Some(object) = dialog.as_object_mut()
    {
        object.insert("accept_keys".into(), json!(keys));
        object.insert("accept_label".into(), json!(label));
    }
    dialog
}

/// What blocks the agent in `terminal`, when the word every agent list
/// shows for it is `blocked` (`roster::agent_of_terminal`): the kind and
/// message of its newest blocked OSC 7501 record, else a startup dialog on
/// `screen`, else a question its hooks reported (`agent_question`). `agents`
/// are the daemon's agent records of that terminal.
///
/// A `blocked` that only a screen guess gives (the screen-detection plugin)
/// is `None` once `screen` shows the agent's input box with no dialog on
/// it: the plugin can read a screen just before the agent redraws it and
/// then not read it again. The agent's own report of blocked always holds.
pub(in crate::cli) fn blocked_dialog(
    terminal: &Value,
    agents: &[Value],
    screen: &str,
) -> Option<Value> {
    let row = roster::agent_of_terminal(terminal, agents, false)?;
    if row.state != roster::AgentState::Blocked {
        return None;
    }
    let screen_guess = matches!(row.source.as_str(), "plugin" | "detected");
    if screen_guess
        && readiness::composer_visible(screen)
        && options(screen).is_empty()
        && readiness::startup_dialog(screen).is_none()
    {
        return None;
    }
    let number = |value: &Value| {
        value.as_u64().or_else(|| value.as_str().and_then(|text| text.parse().ok())).unwrap_or(0)
    };
    let record = terminal["extra"]["program_status"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|record| record["state"] == "blocked")
        .max_by_key(|record| number(&record["updated_at_ms"]));
    let kind = record
        .and_then(|record| record["kind"].as_str())
        .filter(|kind| !kind.is_empty())
        .or_else(|| readiness::startup_dialog(screen).map(|dialog| dialog.id))
        .unwrap_or(readiness::AGENT_QUESTION.id);
    Some(dialog_json(kind, record.and_then(|record| record["msg"].as_str()), screen))
}

/// The localized reason of a blocked `terminal send` or `terminal wait`:
/// ask the person, then answer `dialog` in the terminal `who` with keys,
/// naming its `deny_keys` when it has them.
pub(in crate::cli) fn dialog_reason(
    messages: &crate::localization::PaneCliMessages,
    who: &str,
    dialog: &Value,
) -> String {
    let kind = dialog["kind"].as_str().unwrap_or(readiness::AGENT_QUESTION.id);
    let deny: Vec<&str> =
        dialog["deny_keys"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let template = if deny.is_empty() { messages.dialog_waits } else { messages.dialog_waits_deny };
    template.replace("{kind}", kind).replace("{who}", who).replace("{deny}", &deny.join(" "))
}

/// The message of a `terminal send` that cmux refused because the agent of
/// `who` waits on `dialog`: the [`dialog_reason`] (kind and deny keys), what
/// the dialog asks when its `msg` is known, and that `--force` types anyway.
pub(in crate::cli) fn dialog_refusal(
    messages: &crate::localization::PaneCliMessages,
    who: &str,
    dialog: &Value,
) -> String {
    let mut parts = vec![dialog_reason(messages, who, dialog)];
    if let Some(msg) = dialog["msg"].as_str().filter(|msg| !msg.is_empty()) {
        parts.push(messages.dialog_asks.replace("{msg}", msg));
    }
    parts.push(messages.send_refused_typed.to_owned());
    parts.join(messages.folder_trust_separator)
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

    /// W5-Q review 3 (PR C): a dialog drawn in a box ends each row with
    /// `│`; the label the person approves has no box character.
    #[test]
    fn w5q_a_boxed_option_label_has_no_box_character() {
        let boxed = options(
            "│ ❯ 1. Yes, I trust this folder      │\n│   2. No, exit                     │",
        );
        assert_eq!(accept_label(&boxed), Some("Yes, I trust this folder"));
        assert_eq!(boxed.get(1).map(|option| option.label.as_str()), Some("No, exit"));
    }

    /// W6-B (bench round 5 orchestration row 3): Claude Code 2.1.321 draws
    /// its choices without numbers, the cursor on one row and the others
    /// indented to the same column. They are read in screen order (`number`
    /// is the position), in a box too, and the accept keys move the cursor.
    #[test]
    fn w6bc_unnumbered_cursor_rows_are_options() {
        let screen = " Security guide\n\n ❯ No, exit\n   Yes, I trust this folder\n\n \
                      Enter to confirm · Esc to cancel";
        let read = options(screen);
        assert_eq!(
            read,
            [
                DialogOption { number: 1, label: "No, exit".into(), selected: true },
                DialogOption {
                    number: 2,
                    label: "Yes, I trust this folder".into(),
                    selected: false,
                },
            ]
        );
        assert_eq!(accept_keys(&read), Some(vec!["down", "enter"]));
        assert_eq!(accept_label(&read), Some("Yes, I trust this folder"));
        let boxed = options(
            "│ Pick one        │\n│   Later         │\n│ ❯ Yes, go on    │\n│   No            │",
        );
        let labels: Vec<&str> = boxed.iter().map(|option| option.label.as_str()).collect();
        assert_eq!(labels, ["Later", "Yes, go on", "No"]);
        assert_eq!(accept_keys(&boxed), Some(vec!["enter"]));
    }

    /// W6-B: an agent's input box (a prompt mark with a rule above or
    /// below), its wrapped echo and a lone cursor row are no options.
    #[test]
    fn w6bc_an_input_box_or_a_lone_cursor_row_is_no_options() {
        let composer =
            "────────────────\n❯ fix the test\n  and the build\n────────────────\n  ? for help";
        assert!(options(composer).is_empty());
        assert!(options("› Ask Codex to do anything\n  ⏎ send   ctrl+j newline").is_empty());
        assert!(options(" ❯ Only one choice\n\n Enter to confirm").is_empty());
        assert!(options(" ❯ No, exit\n     deeper indent is no sibling").is_empty());
    }

    /// W6-C: the reason of a blocked send or wait is localized, names the
    /// terminal and the dialog's kind, and names the deny keys when the
    /// dialog has them.
    #[test]
    fn w6bc_the_blocked_dialog_reason_is_localized_and_names_the_deny_keys() {
        let english = &crate::localization::catalog_for_locale("en_US.UTF-8").pane_cli;
        let japanese = &crate::localization::catalog_for_locale("ja_JP.UTF-8").pane_cli;
        let screen = " Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel";
        let dialog = dialog_json("permission", Some("approve Bash: ls"), screen);
        assert_eq!(dialog["deny_keys"], json!(["escape"]));
        assert_eq!(dialog["msg"], "approve Bash: ls");
        let bare = dialog_json("agent_question", None, " Pick a database?\n plain text");
        assert_eq!(bare["msg"], "Pick a database?");
        assert!(bare["deny_keys"].is_null(), "{bare}");
        for messages in [english, japanese] {
            let reason = dialog_reason(messages, "beta", &dialog);
            assert!(reason.contains("cmux terminal beta keys escape"), "{reason}");
            assert!(reason.contains("permission"), "{reason}");
            let reason = dialog_reason(messages, "beta", &bare);
            assert!(reason.contains("cmux terminal beta keys"), "{reason}");
            assert!(!reason.contains("{deny}"), "{reason}");
            let refusal = dialog_refusal(messages, "beta", &dialog);
            assert!(refusal.starts_with(&dialog_reason(messages, "beta", &dialog)), "{refusal}");
            assert!(refusal.contains("approve Bash: ls"), "{refusal}");
            assert!(refusal.contains("--force") && !refusal.contains("{msg}"), "{refusal}");
        }
        assert_ne!(
            dialog_refusal(english, "beta", &dialog),
            dialog_refusal(japanese, "beta", &dialog)
        );
        assert_ne!(
            dialog_reason(english, "beta", &dialog),
            dialog_reason(japanese, "beta", &dialog)
        );
    }

    /// Claude Code 2.1.322 after Escape denied a permission dialog (real
    /// build, W6-BC deny run): its empty input box and footer hint.
    const DENIED_CLAUDE_2_1_322: &str = "\
  ⎿  Interrupted · What should Claude do instead?

✻ Cooked for 20s · done 10:00 AM

────────────────────────────────────────────────────────────────────────────────
❯ \n\
────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts                          ● high · /effort";

    /// The same agent while the permission dialog still shows.
    const PERMISSION_CLAUDE_2_1_322: &str = "\
⏺ Bash(touch /tmp/w6bc-rb)
  ⎿  Waiting…

────────────────────────────────────────────────────────────────────────────────
 Bash command
 touch /tmp/w6bc-rb
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /tmp from this project
   3. No

 Esc to cancel · Tab to amend";

    /// A terminal whose own OSC 7501 record went idle after a permission
    /// dialog, with the agent records `agents`.
    fn denied_terminal(agents: Value) -> (Value, Vec<Value>) {
        let terminal = json!({"id": "term_w6bc", "lifecycle": "running", "extra": {
            "program_status": [{"app": "claude-code", "state": "idle", "updated_at_ms": "1637"}]}});
        (terminal, agents.as_array().cloned().unwrap_or_default())
    }

    /// W6-BC review (real build): after Escape denied the dialog, the
    /// screen-detection plugin read the screen once before Claude redrew it,
    /// wrote `blocked` 265 ms after Claude's own idle record, and never read
    /// it again. That screen guess is no dialog once the screen shows the
    /// input box: `wait --until idle`, `send`, `terminal status` and `agents
    /// dialog list` read it through `blocked_dialog`.
    #[test]
    fn w6bc_a_stale_screen_guess_of_blocked_is_no_dialog() {
        let (terminal, agents) = denied_terminal(json!([
            {"terminal_id": "term_w6bc", "state": "blocked", "source": "hook",
             "updated_at_ms": "1100", "extra": {"agent": "claude"}},
            {"terminal_id": "term_w6bc", "state": "blocked", "source": "plugin",
             "updated_at_ms": "1902", "extra": {"agent": "claude-code"}},
        ]));
        let stale = blocked_dialog(&terminal, &agents, DENIED_CLAUDE_2_1_322);
        assert!(stale.is_none(), "{stale:?}");
        // The guess still holds while the screen shows the dialog, and
        // before the caller has read the screen.
        let live = blocked_dialog(&terminal, &agents, PERMISSION_CLAUDE_2_1_322);
        assert_eq!(
            live.as_ref().map(|dialog| dialog["options"][2]["label"].clone()),
            Some(json!("No"))
        );
        assert!(blocked_dialog(&terminal, &agents, "").is_some());
        // The agent's own report of blocked is never overruled by the screen.
        let (terminal, agents) = denied_terminal(json!([
            {"terminal_id": "term_w6bc", "state": "blocked", "source": "hook",
             "updated_at_ms": "1902", "extra": {"agent": "claude"}},
        ]));
        assert!(blocked_dialog(&terminal, &agents, DENIED_CLAUDE_2_1_322).is_some());
    }

    /// W6-BC review: a footer hint (`? for shortcuts`) is no question.
    #[test]
    fn w6bc_a_footer_hint_is_no_question() {
        let dialog = dialog_json("agent_question", None, DENIED_CLAUDE_2_1_322);
        let msg = dialog["msg"].as_str().unwrap_or_default();
        assert!(!msg.contains("manual mode") && !msg.contains("shortcuts"), "{dialog}");
        let footer = " Pick one\n ❯ 1. Yes\n   2. No\n  ⏵⏵ accept edits on · ? for shortcuts";
        assert!(dialog_json("agent_question", None, footer)["msg"].is_null());
        let dialog = dialog_json("permission", None, PERMISSION_CLAUDE_2_1_322);
        assert_eq!(dialog["msg"], "Do you want to proceed?", "{dialog}");
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
        assert!(!warned.contains("; "), "the Japanese reason has an ASCII separator: {warned}");
    }
}
