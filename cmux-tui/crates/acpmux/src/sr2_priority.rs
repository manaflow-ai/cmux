//! sr2 person priority: a chat a person started asks the sr2 gateway for the
//! last usable Claude accounts, so agent lanes that drain the pool never lock
//! the person out of their own chats (Leo, 2026-11-23: "man i cant even
//! fucking talk to the gui chats rn cuz of alleged "overload@"). The pool's
//! "no non-exhausted claude accounts" 503 is what Claude Code shows as
//! "529 Overloaded".
//!
//! The daemon decides it at every spawn from `SessionMeta::created_by`
//! (`hub/created_by.rs`: the app, the proven person, or the person's phone or
//! browser), never from a profile, a preset or a request: [`mark`] sets
//! [`PERSON_ENV`] for a person's chat and removes it from every other, after
//! the session env. A sub-session, a lane an agent started or a script's chat
//! is no person's. The command builder (`agent/command.rs`) takes the mark
//! off the env, as it does acpmux's other markers, so the agent never sees it
//! and a daemon's own env can never pass one on. The launch then sends `X-Subrouter-Priority: person` in
//! `ANTHROPIC_CUSTOM_HEADERS` ([`custom_headers`]) when the request goes to
//! the sr2 gateway: its base URL names the gateway
//! (`sr2_cost_labels::is_sr2_gateway`), or the harness is the sr2 launcher
//! ([`is_sr2_launcher`]: `sr2`, the `claude-sr2` wrapper the app's default chat
//! profile runs, or a profile named for it), which keeps every line that is not
//! `X-Cmux-*`.
//! Any other route gets nothing, and any older priority line is dropped, so a
//! lane never inherits one from its login. The gateway reads and removes the
//! header before routing (subrouter `internal/proxy/person_reserve.go`).

use crate::subrouter_session::HEADERS_ENV;

/// `1`: this chat is a person's. Set only by [`mark`], read and removed by the command builder.
pub const PERSON_ENV: &str = "ACPMUX_SR2_PERSON";
const HEADER: &str = "X-Subrouter-Priority";

/// Set [`PERSON_ENV`] in a spawn's env for a person's chat, remove it otherwise.
pub fn mark(env: &mut std::collections::BTreeMap<String, String>, person: bool) {
    if person {
        env.insert(PERSON_ENV.to_owned(), "1".to_owned());
    } else {
        env.remove(PERSON_ENV);
    }
}

/// Whether `program` (or a profile or family name) is the sr2 launcher: `sr2`
/// itself (`sr2 claude2 ...`), or the `claude-sr2` wrapper and the profiles
/// named for it (`claude-sr2`, `claude-sr2-pipe`). The app's default chat
/// profile is a `claude-stdio` one whose argv is `~/.local/bin/claude-sr2`, so
/// its family derives to plain `claude`: the program and profile name are what
/// say it goes to sr2.
pub fn is_sr2_launcher(program: &str) -> bool {
    let base = std::path::Path::new(program.trim()).file_name().and_then(|n| n.to_str());
    base.is_some_and(|b| b == "sr2" || b == "claude-sr2" || b.starts_with("claude-sr2-"))
}

/// The `ANTHROPIC_CUSTOM_HEADERS` value for a launch whose final env is `get`,
/// whose program is the sr2 launcher when `launcher`, and that is a person's
/// chat when `person`: the existing lines minus any older priority line, plus
/// this chat's when it is a person's; `None` to leave the value unchanged (not
/// an sr2 route, or nothing to change).
pub fn custom_headers(
    get: impl Fn(&str) -> Option<String>,
    launcher: bool,
    person: bool,
) -> Option<String> {
    let gateway =
        get("ANTHROPIC_BASE_URL").is_some_and(|u| crate::sr2_cost_labels::is_sr2_gateway(&u));
    if !gateway && !launcher {
        return None;
    }
    let existing = get(HEADERS_ENV).unwrap_or_default();
    let is_priority =
        |l: &str| l.split(':').next().unwrap_or("").trim().eq_ignore_ascii_case(HEADER);
    if !person && !existing.lines().any(is_priority) {
        return None;
    }
    let mut lines: Vec<String> = existing
        .lines()
        .filter(|l| !l.trim().is_empty() && !is_priority(l))
        .map(str::to_owned)
        .collect();
    if person {
        lines.push(format!("{HEADER}: person"));
    }
    Some(lines.join("\n"))
}

#[cfg(test)]
#[path = "sr2_priority_tests.rs"]
mod tests;
