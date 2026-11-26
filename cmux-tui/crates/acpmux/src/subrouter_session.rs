//! The sticky subrouter session of a caller that runs one conversation as
//! many short Claude processes (a Chief's turns and compactor nodes).
//!
//! The subrouter picks an upstream account per session, and each account has
//! its own prompt cache. A Chief starts a fresh Claude Code session for every
//! turn, so without one stable session the gateway may put the next turn on
//! another account and the whole cached prefix is written again (Oct 18-19:
//! 52% of claude-sr2 Chief turns rewrote 38k-83k tokens). `sr claude proxy`
//! turned `SUBROUTER_SESSION_KEY` into `X-Subrouter-Session`; `sr2 claude`
//! and plain routes do not, so acpmux adds the header itself for a preset
//! that opts in with `SUBROUTER_SESSION_HEADER=1`. A subagent (one long
//! session, already sticky by its own session id) does not opt in, so a
//! Chief's subagents are not all pinned to one account.

/// The key of the conversation (`optchat-<chief>-turn`, …).
pub const KEY_ENV: &str = "SUBROUTER_SESSION_KEY";
/// `1`: send [`KEY_ENV`] as the `X-Subrouter-Session` request header.
pub const HEADER_ENV: &str = "SUBROUTER_SESSION_HEADER";
/// Claude Code's extra request headers, one `Name: value` per line.
pub const HEADERS_ENV: &str = "ANTHROPIC_CUSTOM_HEADERS";
const HEADER: &str = "X-Subrouter-Session";

/// The `ANTHROPIC_CUSTOM_HEADERS` value for a process whose final env is
/// `get`: the existing lines (any older `X-Subrouter-Session` line dropped)
/// plus this session's line, or `None` to leave it unchanged (no opt-in, or
/// a key that is not a plain token: it would become a header line).
pub fn custom_headers(get: impl Fn(&str) -> Option<String>) -> Option<String> {
    if get(HEADER_ENV).as_deref() != Some("1") {
        return None;
    }
    let key = get(KEY_ENV)?;
    let key = key.trim();
    let plain = !key.is_empty()
        && key.len() <= 128
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b));
    if !plain {
        return None;
    }
    let mut lines: Vec<String> = get(HEADERS_ENV)
        .unwrap_or_default()
        .lines()
        .filter(|l| {
            let name = l.split(':').next().unwrap_or("").trim();
            !l.trim().is_empty() && !name.eq_ignore_ascii_case(HEADER)
        })
        .map(str::to_owned)
        .collect();
    lines.push(format!("{HEADER}: {key}"));
    Some(lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn run(pairs: &[(&str, &str)]) -> Option<String> {
        let env: BTreeMap<String, String> =
            pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        custom_headers(|k| env.get(k).cloned())
    }

    #[test]
    fn opt_in_adds_one_line_and_replaces_an_older_one() {
        let got = run(&[
            (HEADER_ENV, "1"),
            (KEY_ENV, "optchat-a-turn"),
            (HEADERS_ENV, "X-Subrouter-Agent: claude\nx-subrouter-session: old"),
        ]);
        assert_eq!(
            got.as_deref(),
            Some("X-Subrouter-Agent: claude\nX-Subrouter-Session: optchat-a-turn")
        );
    }

    #[test]
    fn no_opt_in_or_unsafe_key_changes_nothing() {
        assert_eq!(run(&[(KEY_ENV, "optchat-a-sub")]), None);
        assert_eq!(run(&[(HEADER_ENV, "1"), (KEY_ENV, "a b")]), None);
        assert_eq!(run(&[(HEADER_ENV, "1"), (KEY_ENV, "a\nX-Evil: 1")]), None);
        assert_eq!(run(&[(HEADER_ENV, "1")]), None);
    }
}
