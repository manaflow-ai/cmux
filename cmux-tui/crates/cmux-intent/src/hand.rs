//! For a CLI that reads its own argv (cmux's resource scopes): `word` and `words`, the Rust twin of
//! intent.py's functions of the same names.

use crate::close::close_matches;
use crate::repair::{CUTOFF, Candidate, Kind, MAX_SHOWN, Repair, norm_flag};
use crate::report::{log, show_words};
use crate::table::{Table, off};
use std::io::Write;

/// `tok` when it is one of `known`, else the one word of `known` it meant (a table alias of one word, a
/// synonym, a spelling, a unique prefix, the one close match), said on `err`. A destructive or outward
/// word is never guessed: `tok` is returned for the CLI to refuse, with the candidate printed.
/// `flags`: `tok` is a flag (the `flag_synonyms` groups); `under`: the subcommand path it sits under.
pub fn word_to(
    tok: &str,
    known: &[String],
    prog: &str,
    flags: bool,
    under: &[String],
    tbl: &Table,
    err: &mut dyn Write,
) -> String {
    if known.iter().any(|k| k == tok) || off() {
        return tok.to_owned();
    }
    let head = tok.split('=').next().unwrap_or(tok);
    let mut cands: Vec<String> = Vec::new();
    if !flags {
        for rule in tbl.cli_entry(prog).map(|e| e.aliases.as_slice()).unwrap_or_default() {
            if let [to] = rule.to.as_slice()
                && rule.from == [tok]
                && rule.under == under
                && known.contains(to)
            {
                cands.push(to.clone());
            }
        }
    }
    if cands.is_empty() {
        cands = tbl
            .mates(head, flags)
            .into_iter()
            .filter(|m| known.iter().any(|k| k == m))
            .map(str::to_owned)
            .collect();
    }
    if cands.is_empty() && flags {
        cands = norm_flag(head).into_iter().filter(|c| known.contains(c)).take(1).collect();
    }
    if cands.is_empty() {
        let pre: Vec<String> = known.iter().filter(|k| k.starts_with(tok)).cloned().collect();
        cands = if pre.len() == 1 && tok.chars().count() >= 2 {
            pre
        } else {
            close_matches(head, known, MAX_SHOWN, CUTOFF)
        };
    }
    let mut seen = Vec::new();
    cands.retain(|c| {
        let new = !seen.contains(c);
        seen.push(c.clone());
        new
    });
    let Some(first) = cands.first().cloned() else {
        return tok.to_owned();
    };
    let value = tok.split_once('=').map_or(String::new(), |(_, v)| format!("={v}"));
    let shown: Vec<String> = cands
        .iter()
        .take(MAX_SHOWN)
        .map(|c| if flags { format!("{c}{value}") } else { c.clone() })
        .collect();
    let first_shown = shown.first().cloned().unwrap_or_else(|| first.clone());
    let mut result = Repair {
        outcome: Kind::Ran,
        argv: vec![tok.to_owned()],
        candidates: shown
            .iter()
            .map(|s| Candidate { argv: vec![s.clone()], notes: vec![format!("`{s}` for `{tok}`")] })
            .collect(),
        error: String::new(),
        word: None,
    };
    if cands.len() > 1 {
        result.outcome = Kind::Candidates;
        let _ = writeln!(
            err,
            "{prog}: `{tok}` could mean (nothing ran): {}",
            shown.iter().map(|s| format!("`{s}`")).collect::<Vec<_>>().join(", ")
        );
    } else if tbl.unsafe_word(&first)
        || tbl.unsafe_word(tok)
        || (!flags && tbl.exact_path(prog, &[under, std::slice::from_ref(&first)].concat()))
    {
        result.outcome = Kind::Exact;
        result.word = Some(first);
        let _ = writeln!(
            err,
            "{prog}: `{tok}` is not a form of {prog}, and `{first_shown}` is destructive or outward, so nothing ran: \
             the exact form is needed. Did you mean `{first_shown}`?"
        );
    } else {
        let _ = writeln!(err, "{prog}: ran `{first_shown}` for `{tok}`");
    }
    log(prog, &[tok.to_owned()], &result);
    if result.outcome == Kind::Ran { first_shown } else { tok.to_owned() }
}

/// `word_to` on stderr with the process table.
pub fn word(tok: &str, known: &[String], prog: &str, flags: bool, under: &[String]) -> String {
    word_to(tok, known, prog, flags, under, Table::load(), &mut std::io::stderr())
}

/// The table's multi-word aliases for `prog` applied at the head of `args`, then the first plain word read
/// as one of `subcommands`, then each `--flag` as one of `flags[that subcommand]` plus `flags[""]`.
pub fn words_to(
    args: &[String],
    prog: &str,
    subcommands: &[String],
    flags: &dyn Fn(&str) -> Vec<String>,
    tbl: &Table,
    err: &mut dyn Write,
) -> Vec<String> {
    let mut out = args.to_vec();
    if off() {
        return out;
    }
    for rule in tbl.cli_entry(prog).map(|e| e.aliases.as_slice()).unwrap_or_default() {
        let (from, to) = (&rule.from, &rule.to);
        if !from.is_empty()
            && rule.under.is_empty()
            && out.starts_with(from)
            && (from.len() > 1 || to.len() > 1)
            && !to.iter().any(|t| tbl.unsafe_word(t))
        {
            let new: Vec<String> =
                to.iter().cloned().chain(out.iter().skip(from.len()).cloned()).collect();
            let _ = writeln!(
                err,
                "{prog}: ran `{}` for `{}`",
                show_words(prog, &new),
                show_words(prog, &out)
            );
            let result = Repair {
                outcome: Kind::Ran,
                argv: out.clone(),
                candidates: vec![Candidate { argv: new.clone(), notes: vec!["table".to_owned()] }],
                error: String::new(),
                word: None,
            };
            log(prog, &out, &result);
            out = new;
            break;
        }
    }
    let mut sub = String::new();
    if !subcommands.is_empty()
        && let Some(slot) = out.iter_mut().find(|t| !t.starts_with('-'))
    {
        let fixed = word_to(slot, subcommands, prog, false, &[], tbl, err);
        sub = fixed.clone();
        *slot = fixed;
    }
    let mut known = flags("");
    known.extend(flags(&sub));
    if !known.is_empty() {
        for word in out.iter_mut() {
            if word == "--" {
                break;
            }
            let name = word.split('=').next().unwrap_or_default().to_owned();
            if word.starts_with("--") && word.len() > 2 && !known.contains(&name) {
                *word = word_to(word, &known, prog, true, &[], tbl, err);
            }
        }
    }
    out
}

/// `words_to` on stderr with the process table.
pub fn words(
    args: &[String],
    prog: &str,
    subcommands: &[String],
    flags: &dyn Fn(&str) -> Vec<String>,
) -> Vec<String> {
    words_to(args, prog, subcommands, flags, Table::load(), &mut std::io::stderr())
}
