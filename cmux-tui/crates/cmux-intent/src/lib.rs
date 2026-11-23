//! Intent aliasing: a CLI that runs the one close match of a mistyped or wishful form and says so.
//!
//! Leo, 2026-11-23: "we can keep hill climbing cli, not just for humans (well, tbh bc they're now
//! the minority these days) but for agents... esp for those that expect different things for some
//! reason, or fuck up commands, or do too much wishful thinking. we need to have really powerful
//! aliasing for intent." And 2026-11-20: "we need a bunch of synonyms for code for you guys where it
//! just goes 'eh close enough' and works".
//!
//! The Rust twin of leo-workspace `tools/intent.py`: the same table (`intent_aliases.json`, embedded;
//! `$INTENT_TABLE` replaces it), the same edits in the same order, the same words on stderr, the same
//! log line, and the same vectors (`intent_vectors.json`, `tests/vectors.rs`). `INTENT_OFF=1` turns it off.
//!
//! A clap CLI takes it at its parse, after clap has refused (a form that parses costs nothing):
//!
//! ```ignore
//! let matches = cmux_intent::matches(cmd, "acpmux", "acpmux", &args)?; // args: the words after the program
//! ```
//!
//! or, where the CLI wants its own refusals first, `cmux_intent::recover(&cmd, key, display, &args, &err)`
//! returns the repaired words to parse once more. A CLI that reads its own argv uses `word` and `words`.

mod close;
mod hand;
mod repair;
mod report;
mod table;
mod walk;

pub use close::{close_matches, ratio, shell_join};
pub use hand::{word, word_to, words, words_to};
pub use repair::{Candidate, Kind, Repair, eligible, repair};
pub use report::{iso_utc, log, log_path, log_to, say, say_to, show_words};
pub use table::{Table, off};

use clap::Command;

/// The words `err` (clap's refusal of `args`, the words after the program name) meant, when one form
/// is clearly meant and is safe to run: said on stderr and logged. `key` names the CLI in the table's
/// `cli` part and `display` how it is run (`cmux acp`). Candidates and exact-form refusals are printed
/// and logged and return None, as does a form nothing clear was meant by.
pub fn recover(
    cmd: &Command,
    key: &str,
    display: &str,
    args: &[String],
    err: &clap::Error,
) -> Option<Vec<String>> {
    if off() || !eligible(err.kind()) {
        return None;
    }
    recover_with(cmd, key, display, args, Table::load())
}

/// `recover` with a given table, for callers that already have the result of clap's refusal.
pub fn recover_with(
    cmd: &Command,
    key: &str,
    display: &str,
    args: &[String],
    tbl: &Table,
) -> Option<Vec<String>> {
    let result = repair(cmd, key, args, tbl);
    if result.outcome == Kind::Ok {
        return None;
    }
    log(display, args, &result);
    say(display, args, &result);
    (result.outcome == Kind::Ran).then_some(result.argv)
}

/// `cmd`'s matches for `args`; when clap refuses, the one form meant (see `recover`) is parsed instead.
pub fn matches(
    cmd: &Command,
    key: &str,
    display: &str,
    args: &[String],
) -> Result<clap::ArgMatches, clap::Error> {
    let full = |words: &[String]| -> Vec<String> {
        std::iter::once(display.to_owned()).chain(words.iter().cloned()).collect()
    };
    let mut first = cmd.clone();
    match first.try_get_matches_from_mut(full(args)) {
        Ok(m) => Ok(m),
        Err(err) => match recover(cmd, key, display, args, &err) {
            Some(fixed) => cmd.clone().try_get_matches_from(full(&fixed)),
            None => Err(err),
        },
    }
}
