use super::*;
use std::collections::BTreeMap;

fn run(pairs: &[(&str, &str)], launcher: bool) -> Option<String> {
    let env: BTreeMap<String, String> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    let person = env.get(PERSON_ENV).map(String::as_str) == Some("1");
    custom_headers(|k| env.get(k).cloned(), launcher, person)
}

const GATEWAY: (&str, &str) = ("ANTHROPIC_BASE_URL", "http://sr2-gateway.tail137216.ts.net:4016");

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
    assert_eq!(run(&[(PERSON_ENV, "1")], true).as_deref(), Some("X-Subrouter-Priority: person"));
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
