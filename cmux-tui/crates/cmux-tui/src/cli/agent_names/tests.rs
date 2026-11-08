use serde_json::{Value, json};

use super::{Found, Place, Scope, Target, lookup, replace, resolve, targets, valid_agent_name};

const ALPHA: &str = "term_a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const BETA: &str = "term_b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
const OLD: &str = "term_0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d";
const SHELL: &str = "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e";

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// alpha runs claude (live, hook record); beta is a live shell tab; an
/// exited `alpha` tab is kept beside the live one; two shells share `dup`.
fn snapshot() -> Value {
    json!({
        "panes": [{"id": "pane_1", "name": "left"}, {"id": "pane_2", "name": null}],
        "tabs": [
            {"id": "tab_alpha", "name": "alpha", "content_id": ALPHA, "pane_id": "pane_1"},
            {"id": "tab_old", "name": "alpha", "content_id": OLD, "pane_id": "pane_2"},
            {"id": "tab_beta", "name": "beta", "content_id": BETA, "pane_id": "pane_2"},
            {"id": "tab_dup1", "name": "dup", "content_id": SHELL, "pane_id": "pane_1"},
            {"id": "tab_dup2", "name": "dup", "content_id": BETA, "pane_id": "pane_2"},
            {"id": "tab_gone", "name": "gone", "content_id": OLD, "pane_id": "pane_2"},
            {"id": "tab_left", "name": "left", "content_id": SHELL, "pane_id": "pane_2"},
        ],
        "terminals": [
            {"id": ALPHA, "lifecycle": "running", "tab_id": "tab_alpha"},
            {"id": OLD, "lifecycle": "exited", "tab_id": "tab_old"},
            {"id": BETA, "lifecycle": "running", "tab_id": "tab_beta"},
            {"id": SHELL, "lifecycle": "running", "tab_id": "tab_dup1"},
        ],
        "agents": [
            {"terminal_id": ALPHA, "state": "idle", "updated_at_ms": "10"},
            {"terminal_id": OLD, "state": "done", "updated_at_ms": "5"},
        ],
    })
}

#[test]
fn w3h_agent_names_follow_the_grammar_and_avoid_command_words_and_ids() {
    let longest = "a".repeat(32);
    let too_long = "a".repeat(33);
    for good in ["alpha", "a", "fix-tests-2", "b_2", longest.as_str()] {
        assert!(valid_agent_name(good).is_ok(), "{good}");
    }
    for bad in [
        "",
        "Alpha",
        "1abc",
        "-x",
        "a b",
        "a.b",
        "über",
        too_long.as_str(),
        "current",
        "caller",
        "focused",
        "start",
        "resume",
        "list",
        "send",
        "term_1",
        "tab_x",
        "pane_main",
    ] {
        assert!(valid_agent_name(bad).is_err(), "{bad}");
    }
}

#[test]
fn w3h_a_name_selects_the_live_agent_first_then_live_then_exited_tabs() {
    let snapshot = snapshot();
    // The live tab running an agent wins over the exited tab of the same name.
    assert_eq!(
        resolve(&snapshot, "alpha"),
        Found::One(Place {
            terminal: ALPHA.into(),
            tab: "tab_alpha".into(),
            pane: "pane_1".into(),
            live: true,
            agent: true,
        })
    );
    assert_eq!(resolve(&snapshot, "name:alpha"), resolve(&snapshot, "alpha"));
    // A unique tab name without an agent works too.
    assert!(matches!(resolve(&snapshot, "beta"), Found::One(place) if place.terminal == BETA));
    // An exited tab is found when nothing live has the name (resume).
    assert!(matches!(resolve(&snapshot, "gone"), Found::One(place) if !place.live));
    assert_eq!(
        resolve(&snapshot, "dup"),
        Found::Ambiguous(vec!["tab_dup1".into(), "tab_dup2".into()])
    );
    assert_eq!(resolve(&snapshot, "nobody"), Found::Missing);
}

#[test]
fn w3h_selector_words_and_flags_that_may_be_names_are_found_and_replaced() {
    let words = strings(&["terminal", "alpha", "send", "--text", "hi", "--wait", "idle"]);
    let found = targets(&words);
    assert_eq!(found, vec![Target { scope: Scope::Terminal, word: "alpha".into(), flag: None }]);
    // Ids, keywords, command words and the agent verbs are left alone.
    let skipped: [&[&str]; 8] = [
        &["terminal", ALPHA, "send"],
        &["terminal", "current", "screen", "read"],
        &["terminal", "list", "--agents"],
        &["tab", "create", "terminal"],
        &["agent", "start", "alpha", "--pane", "beta"],
        &["agent", "resume", "alpha"],
        &["terminal", "alpha"],
        &["workspace", "list", "--pane", "beta"],
    ];
    for skipped in skipped {
        assert!(targets(&strings(skipped)).is_empty(), "{skipped:?}");
    }
    let flags =
        strings(&["agent", "list", "--terminal", "alpha", "--tab=beta", "--", "--pane", "x"]);
    assert_eq!(
        targets(&flags),
        vec![
            Target { scope: Scope::Terminal, word: "alpha".into(), flag: Some("--terminal") },
            Target { scope: Scope::Tab, word: "beta".into(), flag: Some("--tab") },
        ]
    );

    let snapshot = snapshot();
    let mut args = strings(&["--session", "s", "terminal", "alpha", "send", "--text", "alpha"]);
    let found = targets(&args[2..]);
    let target = &found[0];
    let id = lookup(&snapshot, target).unwrap().unwrap();
    assert!(replace(&mut args, target, &id));
    assert_eq!(args, strings(&["--session", "s", "terminal", ALPHA, "send", "--text", "alpha"]));

    let tab = strings(&["tab", "alpha", "focus"]);
    let found = targets(&tab);
    let target = &found[0];
    assert_eq!(lookup(&snapshot, target).unwrap().as_deref(), Some("tab_alpha"));
    let mut flagged = strings(&["agent", "list", "--terminal=beta"]);
    let found = targets(&flagged);
    let target = &found[0];
    let id = lookup(&snapshot, target).unwrap().unwrap();
    assert!(replace(&mut flagged, target, &id));
    assert_eq!(flagged, strings(&["agent", "list", &format!("--terminal={BETA}")]));
    // A pane with the name keeps its own name; a missing name stays as it is.
    let pane = Target { scope: Scope::Pane, word: "left".into(), flag: None };
    assert_eq!(lookup(&snapshot, &pane).unwrap(), None);
    let terminal = Target { scope: Scope::Terminal, word: "left".into(), flag: None };
    assert_eq!(lookup(&snapshot, &terminal).unwrap().as_deref(), Some(SHELL));
    let missing = Target { scope: Scope::Terminal, word: "nobody".into(), flag: None };
    assert_eq!(lookup(&snapshot, &missing).unwrap(), None);
    let ambiguous = Target { scope: Scope::Terminal, word: "dup".into(), flag: None };
    let error = lookup(&snapshot, &ambiguous).unwrap_err();
    assert_eq!(error["code"], "selector.ambiguous");
    assert_eq!(error["details"]["candidates"], json!(["tab_dup1", "tab_dup2"]));
}
