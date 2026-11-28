//! Part of `Hub`; see `hub/mod.rs`. A session's taint letters (RFD 0179 idea 11): like a
//! kernel's taint mask, printed in every later oops, they mark a session that ran something
//! unusual, so a report about it (its row, `acpmux ls --fields taint`, later its death record
//! and its pull requests) says so.
//!
//! - `A`: an admin merge, `gh pr merge ... --admin` (past branch protection).
//! - `O`: a guard override, a command run with `GUARD_OVERRIDE=` or `LAND_JUDGE_OVERRIDE=` set
//!   (as a `VAR=value` prefix, through `env`, or `export`ed).
//! - `R`: a forced rerun, `gh run rerun ... --force` (past the broker's fixed-on-base check).
//!
//! Read from the shell script a tool call declares (`rawInput.command`), split into its
//! top-level commands outside quotes (`pull_requests::commands`), so a grep, an echo or a commit
//! message that only mentions one taints nothing. A call taints when it is seen, not when it
//! ends: an override acts at the call's start, whatever its exit. Each letter keeps when it was
//! first seen, once (`SessionMeta::taint`); a replayed log sets nothing new.

use std::collections::BTreeMap;

use super::*;

/// Variables whose setting overrides a guard (`O`).
const OVERRIDES: [&str; 2] = ["GUARD_OVERRIDE", "LAND_JUDGE_OVERRIDE"];

/// The taint letters a tool call `update` (a `session/update`'s `update`) sets, sorted, once each.
/// Only a call that declares a shell command (`rawInput.command`) counts: a title is not a script.
pub(super) fn of_call(update: &Value) -> Vec<char> {
    if update.pointer("/rawInput/command").or_else(|| update.pointer("/rawInput/cmd")).is_none() {
        return vec![];
    }
    let Some(script) = super::pull_requests::script(update) else { return vec![] };
    of_script(&script)
}

/// The taint letters `script` sets (module docs), sorted, once each.
pub(super) fn of_script(script: &str) -> Vec<char> {
    let mut out = std::collections::BTreeSet::new();
    for (command, _) in super::pull_requests::commands(script) {
        let mut words = command.split_whitespace().peekable();
        if words.peek() == Some(&"export") {
            words.next();
        }
        let mut overrides = false;
        while let Some(&w) = words.peek() {
            if w == "env" {
                words.next();
                continue;
            }
            match w.split_once('=') {
                Some((k, _)) if !k.is_empty() && !k.starts_with('-') => {
                    overrides |= OVERRIDES.contains(&k);
                    words.next();
                }
                _ => break,
            }
        }
        if overrides {
            out.insert('O');
        }
        let rest: Vec<&str> = words.map(|w| w.trim_matches(|c| c == '\'' || c == '"')).collect();
        match rest[..] {
            ["gh", "pr", "merge", ref args @ ..] if args.contains(&"--admin") => {
                out.insert('A');
            }
            ["gh", "run", "rerun", ref args @ ..] if args.contains(&"--force") => {
                out.insert('R');
            }
            _ => {}
        }
    }
    out.into_iter().collect()
}

/// Notes the taint letters of tool call `update` on `m`, each with `at` (ms) the first time.
pub(super) fn absorb(update: &Value, m: &mut SessionMeta, at: u64) {
    for letter in of_call(update) {
        m.taint.entry(letter.to_string()).or_insert(at);
    }
}

/// A session's taint letters as its summary shows them: sorted, one each ("AO"), empty for none.
pub(super) fn letters(taint: &BTreeMap<String, u64>) -> String {
    taint.keys().map(String::as_str).collect()
}

#[cfg(test)]
#[path = "taint_tests.rs"]
mod tests;
