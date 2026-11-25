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
//! Any other route gets nothing. An older priority line is dropped, so a lane
//! never inherits one from its login, except the one acpmux itself set from
//! [`crate::subrouter_priority::ENV`] (a coordinator's `coordinator`, a
//! lane's `background`): until 2026-11-24 this pass dropped that one too, so
//! on sr2 every coordinator ran as a lane and its `/compact` got the pool's
//! 503 (Leo, 2026-11-24: "fix 529s properly with better designs"). The
//! gateway reads the header as an admission class (subrouter
//! `internal/proxy/admission_class.go`).

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
    // acpmux's own class for this session (subrouter_priority.rs), which a
    // login's line must not replace and this pass must not drop.
    let own = get(crate::subrouter_priority::ENV)
        .map(|v| v.trim().to_ascii_lowercase())
        .filter(|v| crate::subrouter_priority::is_known(v));
    let want = if person { Some("person".to_owned()) } else { own };
    let mut lines: Vec<String> = existing
        .lines()
        .filter(|l| !l.trim().is_empty() && !is_priority(l))
        .map(str::to_owned)
        .collect();
    if let Some(value) = &want {
        lines.push(format!("{HEADER}: {value}"));
    }
    let joined = lines.join("\n");
    let unchanged =
        existing.lines().filter(|l| !l.trim().is_empty()).collect::<Vec<_>>().join("\n");
    (joined != unchanged).then_some(joined)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn run(pairs: &[(&str, &str)], launcher: bool) -> Option<String> {
        let env: BTreeMap<String, String> =
            pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        let person = env.get(PERSON_ENV).map(String::as_str) == Some("1");
        custom_headers(|k| env.get(k).cloned(), launcher, person)
    }

    const GATEWAY: (&str, &str) =
        ("ANTHROPIC_BASE_URL", "http://sr2-gateway.tail137216.ts.net:4016");

    #[test]
    fn a_persons_chat_on_the_gateway_asks_for_the_reserve() {
        let got = run(
            &[
                GATEWAY,
                (PERSON_ENV, "1"),
                (HEADERS_ENV, "X-Cmux-Agent-Id: chat-1\nx-subrouter-priority: lane"),
            ],
            false,
        );
        assert_eq!(got.as_deref(), Some("X-Cmux-Agent-Id: chat-1\nX-Subrouter-Priority: person"));
    }

    #[test]
    fn the_sr2_launcher_gets_it_with_no_base_url() {
        assert_eq!(
            run(&[(PERSON_ENV, "1")], true).as_deref(),
            Some("X-Subrouter-Priority: person")
        );
        assert!(is_sr2_launcher("sr2"));
        assert!(is_sr2_launcher("/Users/leoli/bin/sr2"));
        assert!(!is_sr2_launcher("claude"));
        assert!(!is_sr2_launcher("/usr/local/bin/sr2-helper"));
        // The app's default chat profile: argv ~/.local/bin/claude-sr2, profile
        // claude-sr2 or claude-sr2-pipe, family derived as plain `claude`.
        assert!(is_sr2_launcher("/Users/leoli/.local/bin/claude-sr2"));
        assert!(is_sr2_launcher("claude-sr2-pipe"));
        assert!(!is_sr2_launcher("claude"));
        assert!(!is_sr2_launcher("claude-sr2x"));
    }

    #[test]
    fn a_lane_never_carries_it() {
        assert_eq!(run(&[GATEWAY, (HEADERS_ENV, "X-Subrouter-Session: k")], false), None);
        // One its login or profile set is dropped: only the daemon's mark asks.
        let got = run(
            &[GATEWAY, (HEADERS_ENV, "X-Subrouter-Priority: person\nX-Subrouter-Session: k")],
            false,
        );
        assert_eq!(got.as_deref(), Some("X-Subrouter-Session: k"));
        assert_eq!(run(&[(PERSON_ENV, "0")], true), None);
    }

    // Until 2026-11-24 this pass dropped the line subrouter_priority had just
    // set, so on sr2 a coordinator ran as a lane and its /compact got the
    // pool's 503.
    #[test]
    fn acpmuxs_own_class_survives_on_the_gateway() {
        let env = |value: &'static str, headers: &'static str| {
            [GATEWAY, (crate::subrouter_priority::ENV, value), (HEADERS_ENV, headers)]
        };
        let coord = "X-Subrouter-Session: k\nX-Subrouter-Priority: coordinator";
        assert_eq!(run(&env("coordinator", coord), false), None, "already right");
        assert_eq!(
            run(&env("coordinator", "X-Subrouter-Priority: person\nX-Subrouter-Session: k"), false)
                .as_deref(),
            Some(coord),
            "a login's line gives way to acpmux's own"
        );
        assert_eq!(
            run(&env("batch", "X-Subrouter-Priority: batch"), true),
            None,
            "a review keeps batch through the launcher"
        );
        let mut person = env("coordinator", coord).to_vec();
        person.push((PERSON_ENV, "1"));
        assert_eq!(
            run(&person, false).as_deref(),
            Some("X-Subrouter-Session: k\nX-Subrouter-Priority: person"),
            "the person's mark wins"
        );
    }

    #[test]
    fn other_routes_get_nothing() {
        assert_eq!(run(&[(PERSON_ENV, "1")], false), None, "Claude talks to Anthropic directly");
        let direct = [("ANTHROPIC_BASE_URL", "https://api.anthropic.com"), (PERSON_ENV, "1")];
        assert_eq!(run(&direct, false), None);
    }

    #[test]
    fn mark_is_the_daemons_answer() {
        let mut env = BTreeMap::from([(PERSON_ENV.to_owned(), "1".to_owned())]);
        mark(&mut env, false);
        assert!(!env.contains_key(PERSON_ENV), "a profile's or request's value goes");
        mark(&mut env, true);
        assert_eq!(env.get(PERSON_ENV).map(String::as_str), Some("1"));
    }
}
