use super::*;
use std::collections::BTreeMap;

const GATEWAY: (&str, &str) = ("ANTHROPIC_BASE_URL", "http://127.0.0.1:4016");

fn run(pairs: &[(&str, &str)]) -> Option<String> {
    let mut env: BTreeMap<String, String> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    env.entry(GATEWAY.0.to_owned()).or_insert_with(|| GATEWAY.1.to_owned());
    custom_headers(|k| env.get(k).cloned(), false)
}

#[test]
fn a_direct_anthropic_chat_sends_no_priority() {
    let env = |pairs: &[(&str, &str)]| -> BTreeMap<String, String> {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    };
    // A plain `claude` on the person's own login: no base URL.
    let plain = env(&[(ENV, INTERACTIVE)]);
    assert_eq!(custom_headers(|k| plain.get(k).cloned(), false), None);
    // Anthropic's own API named by hand is not a gateway either.
    let direct = env(&[(ENV, BACKGROUND), ("ANTHROPIC_BASE_URL", "https://api.anthropic.com")]);
    assert_eq!(custom_headers(|k| direct.get(k).cloned(), false), None);
    // The sr2 launcher with no base URL still reaches its gateway.
    assert_eq!(
        custom_headers(|k| plain.get(k).cloned(), true).as_deref(),
        Some("X-Subrouter-Priority: interactive")
    );
    // A gateway base URL gets it.
    let sr2 = env(&[(ENV, BACKGROUND), ("ANTHROPIC_BASE_URL", "http://sr2-gateway.example:4016/")]);
    assert_eq!(
        custom_headers(|k| sr2.get(k).cloned(), false).as_deref(),
        Some("X-Subrouter-Priority: background")
    );
}

#[test]
fn person_chats_and_coordinators_are_interactive() {
    assert_eq!(classify("claude-17", true), INTERACTIVE);
    for coord in ["claude-sr2-coord", "claude-sr2-coord-old", "interim-coord", "web-coord"] {
        assert_eq!(classify(coord, false), INTERACTIVE, "{coord}");
    }
    for lane in ["ci-217x-dictator", "merge-dictator-2", "ask-efe8c0bf62", "ASK-gui-chats"] {
        assert_eq!(classify(lane, false), INTERACTIVE, "{lane}");
    }
    for lane in
        ["lane-gateway", "helper-3", "optchat-a-sub", "coordinator-relay", "coord", "task-ask-x"]
    {
        assert_eq!(classify(lane, false), BACKGROUND, "{lane}");
    }
}

#[test]
fn leaders_interim_coordinators_and_chief_are_interactive_by_role() {
    // The live coordinators of 2026-11-24, which the names alone left background.
    for (name, leads) in [
        ("interim-coord-2", 0),
        ("coord-successor", 3),
        ("coord-deputy-r2", 1),
        ("coord-dispatcher", 2),
        ("chief", 0),
    ] {
        assert_eq!(classify_role(name, false, leads, None), INTERACTIVE, "{name}");
    }
    // A coordinator's own lanes stay background: they lead nobody.
    for name in ["coord-successor/ws-disk", "coord-overload-inbox", "helper-3", "chief/sub"] {
        assert_eq!(classify_role(name, false, 0, None), BACKGROUND, "{name}");
    }
    // The names classify() knew still count, under a parent's prefix too.
    assert_eq!(classify_role("x/claude-sr2-coord", false, 0, None), INTERACTIVE);
    assert_eq!(classify_role("lane-3", true, 0, None), INTERACTIVE);
}

#[test]
fn the_priority_tag_wins_over_the_role() {
    assert_eq!(classify_role("helper-3", false, 0, Some("Interactive")), INTERACTIVE);
    assert_eq!(classify_role("coord-successor", false, 4, Some("background")), BACKGROUND);
    assert_eq!(classify_role("helper-3", false, 0, Some("urgent")), BACKGROUND);
}

#[test]
fn appends_after_existing_lines_and_replaces_an_older_priority() {
    let got = run(&[
        (ENV, "interactive"),
        (HEADERS_ENV, "X-Subrouter-Session: s1\nx-subrouter-priority: background"),
    ]);
    assert_eq!(got.as_deref(), Some("X-Subrouter-Session: s1\nX-Subrouter-Priority: interactive"));
    assert_eq!(run(&[(ENV, "background")]).as_deref(), Some("X-Subrouter-Priority: background"));
}

#[test]
fn unset_or_unknown_changes_nothing() {
    assert_eq!(run(&[(HEADERS_ENV, "A: b")]), None);
    assert_eq!(run(&[(ENV, "urgent\nX-Evil: 1")]), None);
}

#[test]
fn a_profile_value_wins() {
    let mut env = BTreeMap::new();
    set(&mut env, "lane-1", true);
    assert_eq!(env.get(ENV).map(String::as_str), Some(INTERACTIVE));
    let mut env = BTreeMap::from([(ENV.to_owned(), BACKGROUND.to_owned())]);
    set(&mut env, "x-coord", true);
    assert_eq!(env.get(ENV).map(String::as_str), Some(BACKGROUND));
}
