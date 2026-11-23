//! "Eh close enough" for cmux's hand-rolled grammar: when the mux grammar refuses a command, a mistyped or
//! synonym scope or verb is read as the one word it meant (`cmux sessions ls` -> `cmux session ls`), said on
//! stderr, and the command runs again. The words come from the help the CLI prints, so only a command this
//! build lists is ever supplied. A destructive or outward word is never guessed: `cmux_intent::word` prints
//! the exact form needed and nothing runs. `INTENT_OFF=1` turns it off.

use super::completion::{read_help, rows, verbs};
use std::io::Write;

/// Global options that take the next word as their value.
const GLOBAL_VALUED: &[&str] =
    &["--socket", "--session", "--machine", "--app-socket", "--idempotency-key"];
const EXTRA_SCOPES: &[&str] = &["attach", "completion", "help", "logout", "whoami"];
/// Scopes whose verbs are read, one per row, from `cmux SCOPE --help`.
const VERB_SCOPES: &[&str] = &[
    "vm",
    "device",
    "chats",
    "setup",
    "settings",
    "customize",
    "history",
    "chief",
    "machine",
    "skill",
    "client",
    "daemon",
    "session",
    "remote",
    "host",
    "link",
    "github",
    "workflow",
    "computer-use",
    "closed",
    "git",
    "docs",
];

/// `args` with its scope word (then its verb) read as the word it meant, or None when nothing changed.
/// `root_help` is the root usage text; `verbs_of(scope)` the scope's verbs.
pub(super) fn fix(
    args: &[String],
    root_help: &str,
    verbs_of: &dyn Fn(&str) -> Vec<String>,
    tbl: &cmux_intent::Table,
    err: &mut dyn Write,
) -> Option<Vec<String>> {
    if cmux_intent::off() {
        return None;
    }
    let mut at = 0;
    while at < args.len() && args[at].starts_with('-') {
        at +=
            1 + usize::from(GLOBAL_VALUED.contains(&args[at].as_str()) && !args[at].contains('='));
    }
    let tok = args.get(at)?;
    if !tok.chars().next().is_some_and(|c| c.is_ascii_alphabetic()) {
        return None;
    }
    let mut scopes = rows(root_help);
    scopes.extend(EXTRA_SCOPES.iter().map(|s| (*s).to_owned()));
    let mut out = args.to_vec();
    let scope = cmux_intent::word_to(tok, &scopes, "cmux", false, &[], tbl, err);
    out[at] = scope.clone();
    if VERB_SCOPES.contains(&scope.as_str())
        && let Some(verb) =
            args.get(at + 1).filter(|v| v.chars().next().is_some_and(|c| c.is_ascii_alphabetic()))
    {
        let known = verbs_of(&scope);
        if !known.is_empty() {
            let under = [scope.clone()];
            out[at + 1] = cmux_intent::word_to(verb, &known, "cmux", false, &under, tbl, err);
        }
    }
    (out != args).then_some(out)
}

/// `fix` with the process's help readers and table, for `cli::run`'s dead end.
pub(super) fn retry(args: &[String], root_help: &str) -> Option<Vec<String>> {
    fix(
        args,
        root_help,
        &|scope| read_help(&[scope]).map(|text| verbs(scope, &text)).unwrap_or_default(),
        cmux_intent::Table::load(),
        &mut std::io::stderr(),
    )
}

#[cfg(test)]
mod tests;
