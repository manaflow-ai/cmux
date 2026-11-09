use serde_json::{Value, json};

use super::{
    Found, Place, Scope, Target, args_with_words, lookup, replace, resolve, rewrite_words, targets,
    valid_agent_name,
};

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
        "write",
        "term_1",
        "tab_x",
        "pane_main",
    ] {
        assert!(valid_agent_name(bad).is_err(), "{bad}");
    }
}

#[test]
fn w3h_a_name_selects_a_live_tab_first_then_an_exited_tab() {
    let snapshot = snapshot();
    // The live tab wins over the exited tab of the same name.
    assert_eq!(
        resolve(&snapshot, "alpha"),
        Found::One(Place {
            terminal: ALPHA.into(),
            tab: "tab_alpha".into(),
            pane: "pane_1".into(),
            live: true,
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

fn positional(scope: Scope, word: &str, index: usize) -> Target {
    Target { scope, word: word.into(), flag: None, index, inline: false }
}

#[test]
fn w3h_selector_words_and_flags_that_may_be_names_are_found_and_replaced() {
    let words = strings(&["terminal", "alpha", "write", "--text", "hi"]);
    let found = targets(&words);
    assert_eq!(found, vec![positional(Scope::Terminal, "alpha", 1)]);
    // Ids, keywords, command words and the agent verbs are left alone.
    let skipped: [&[&str]; 8] = [
        &["terminal", ALPHA, "write"],
        &["terminal", "current", "screen", "read"],
        &["terminal", "list"],
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
        strings(&["agent", "list", "--terminal", "alpha", "--pane=beta", "--", "--pane", "x"]);
    assert_eq!(
        targets(&flags),
        vec![
            Target {
                scope: Scope::Terminal,
                word: "alpha".into(),
                flag: Some("--terminal"),
                index: 3,
                inline: false,
            },
            Target {
                scope: Scope::Pane,
                word: "beta".into(),
                flag: Some("--pane"),
                index: 4,
                inline: true,
            },
        ]
    );

    let snapshot = snapshot();
    let mut words = strings(&["terminal", "alpha", "write", "--text", "alpha"]);
    let found = targets(&words);
    let target = &found[0];
    let id = lookup(&snapshot, target).unwrap().unwrap();
    replace(&mut words, target, &id);
    assert_eq!(words, strings(&["terminal", ALPHA, "write", "--text", "alpha"]));

    let tab = strings(&["tab", "alpha", "focus"]);
    let found = targets(&tab);
    let target = &found[0];
    assert_eq!(lookup(&snapshot, target).unwrap().as_deref(), Some("tab_alpha"));
    let mut flagged = strings(&["agent", "list", "--terminal=beta"]);
    let found = targets(&flagged);
    let target = &found[0];
    let id = lookup(&snapshot, target).unwrap().unwrap();
    replace(&mut flagged, target, &id);
    assert_eq!(flagged, strings(&["agent", "list", &format!("--terminal={BETA}")]));
    // A pane name is the daemon's call (rewrite_words asks it); the lookup
    // gives the named tab's pane. A missing name stays as it is.
    let pane = positional(Scope::Pane, "left", 1);
    assert_eq!(lookup(&snapshot, &pane).unwrap().as_deref(), Some("pane_2"));
    let terminal = positional(Scope::Terminal, "left", 1);
    assert_eq!(lookup(&snapshot, &terminal).unwrap().as_deref(), Some(SHELL));
    let missing = positional(Scope::Terminal, "nobody", 1);
    assert_eq!(lookup(&snapshot, &missing).unwrap(), None);
    let ambiguous = positional(Scope::Terminal, "dup", 1);
    let error = lookup(&snapshot, &ambiguous).unwrap_err();
    assert_eq!(error["code"], "selector.ambiguous");
    assert_eq!(error["details"]["candidates"], json!(["tab_dup1", "tab_dup2"]));
}

/// W3-H review: a word the daemon's own selector rules find (here: in the
/// caller's current tab or pane) stays as it is, also when a tab elsewhere
/// has that name or the name is shared (no new `selector.ambiguous`). The
/// rules are asked only for a word that a name matches.
#[test]
fn w3h_a_selector_the_daemon_finds_is_never_rewritten() {
    let snapshot = snapshot();
    let words = strings(&["terminal", "alpha", "write", "--text", "hi"]);
    let mut asked = Vec::new();
    let mut finds = |target: &Target| {
        asked.push(target.word.clone());
        true
    };
    assert_eq!(rewrite_words(&words, &snapshot, &mut finds).unwrap(), None);
    let shared = strings(&["tab", "dup", "focus"]);
    assert_eq!(rewrite_words(&shared, &snapshot, &mut finds).unwrap(), None);
    let unnamed = strings(&["tab", "nobody", "focus"]);
    assert_eq!(rewrite_words(&unnamed, &snapshot, &mut finds).unwrap(), None);
    assert_eq!(asked, ["alpha", "dup"]);

    // Only a word the rules do not find becomes the named tab's id.
    let mut not_found = |_: &Target| false;
    assert_eq!(
        rewrite_words(&words, &snapshot, &mut not_found).unwrap(),
        Some(strings(&["terminal", ALPHA, "write", "--text", "hi"]))
    );
    let error = rewrite_words(&shared, &snapshot, &mut not_found).unwrap_err();
    assert_eq!(error["code"], "selector.ambiguous");

    // `agent` and `notification` flags take a term_ id only: a name there
    // always becomes its id, whatever the daemon finds.
    let listed = strings(&["agent", "list", "--terminal", "alpha"]);
    assert_eq!(
        rewrite_words(&listed, &snapshot, &mut |_: &Target| true).unwrap(),
        Some(strings(&["agent", "list", "--terminal", ALPHA]))
    );
}

/// W3-H review: a terminal title wins over a tab name, in the rewrite and in
/// `terminal <t> resume` (agent_start/daemon.rs), as titles did before names existed.
/// In the rewrite the daemon decides (it matches a title under the current tab
/// only), so a title in another tab does not hide the name.
#[test]
fn w3h_a_terminal_title_wins_over_a_tab_name() {
    let mut snapshot = snapshot();
    snapshot["terminals"][2]["title"] = json!("alpha");
    let words = strings(&["terminal", "alpha", "write", "--text", "hi"]);
    assert_eq!(rewrite_words(&words, &snapshot, &mut |_: &Target| true).unwrap(), None);
    assert_eq!(
        rewrite_words(&words, &snapshot, &mut |_: &Target| false).unwrap(),
        Some(strings(&["terminal", ALPHA, "write", "--text", "hi"]))
    );
    let found = super::super::agent_start::daemon::find_terminal(&snapshot, "alpha")
        .ok()
        .map(|t| t["id"].clone());
    assert_eq!(found, Some(json!(BETA)));
    // Two terminals with the title stay ambiguous, as before.
    snapshot["terminals"][3]["title"] = json!("alpha");
    let error = super::super::agent_start::daemon::find_terminal(&snapshot, "alpha")
        .expect_err("ambiguous title");
    assert!(format!("{error:?}").contains("selector.ambiguous"), "{error:?}");
    // With no title, the name still selects its terminal.
    let found = super::super::agent_start::daemon::find_terminal(&self::snapshot(), "alpha")
        .ok()
        .map(|t| t["id"].clone());
    assert_eq!(found, Some(json!(ALPHA)));
}

/// W3-H review: a command word of the parser (`create` in `tab create
/// terminal`, `write` in `terminal <t> write`) is never a selector, and no
/// agent can take it as a name.
#[test]
fn w3h_subcommand_words_are_not_rewritten_or_valid_names() {
    for words in [&["tab", "create", "terminal"][..], &["pane", "list"][..]] {
        assert!(targets(&strings(words)).is_empty(), "{words:?}");
    }
    for word in ["write", "keys", "screen", "process", "neighbor", "zoom"] {
        assert!(valid_agent_name(word).is_err(), "{word}");
    }
}

/// W3-H review: the scan reads flag values as the parser does: a flag that
/// is not a boolean flag takes the next word, even one that starts with
/// `--`, so `foo` below is a word, not the value of `--pane`.
#[test]
fn w3h_the_scan_skips_the_values_of_flags_that_take_one() {
    let words = strings(&["terminal", "alpha", "write", "--text", "--pane", "foo"]);
    assert_eq!(targets(&words), vec![positional(Scope::Terminal, "alpha", 1)]);
    let flagged = strings(&["agent", "list", "--text", "--tab", "--terminal", "beta"]);
    assert_eq!(
        targets(&flagged),
        vec![Target {
            scope: Scope::Terminal,
            word: "beta".into(),
            flag: Some("--terminal"),
            index: 5,
            inline: false,
        }]
    );
    // A boolean flag takes no value: the word after it is still read.
    let boolean = strings(&["agent", "list", "--details", "--pane", "beta"]);
    assert_eq!(targets(&boolean).len(), 1);
}

/// The changed words go back into the full arguments at the place the
/// global options leave them, never into a global option's value.
#[test]
fn w3h_rewritten_words_never_change_a_global_option_value() {
    let args = strings(&["--session", "alpha", "terminal", "alpha", "write", "--text", "alpha"]);
    let words = strings(&["terminal", "alpha", "write", "--text", "alpha"]);
    let rewritten = strings(&["terminal", ALPHA, "write", "--text", "alpha"]);
    assert_eq!(
        args_with_words(&args, &words, &rewritten),
        Some(strings(&["--session", "alpha", "terminal", ALPHA, "write", "--text", "alpha"]))
    );
}

/// Review (lead's reviewer, #38436): a live shell tab and a live agent tab with
/// one name are two candidates. The CLI does not prefer the agent tab: the
/// daemon's tab-name scope does not, so `tab alpha close` and `terminal alpha
/// write` could pick different objects. Live tabs still win over exited ones.
#[test]
fn w3h_two_live_tabs_with_one_name_are_ambiguous_even_when_one_runs_an_agent() {
    let mut named = snapshot();
    if let Some(tabs) = named["tabs"].as_array_mut() {
        tabs.push(json!({"id": "tab_alpha_shell", "name": "alpha", "content_id": SHELL,
                         "pane_id": "pane_2"}));
    }
    let both = vec!["tab_alpha".to_owned(), "tab_alpha_shell".to_owned()];
    assert_eq!(resolve(&named, "alpha"), Found::Ambiguous(both));

    let pane = super::super::agent_start::placement::target_pane(&named, Some("alpha"), None)
        .expect_err("two live tabs are named alpha");
    assert_eq!(pane.error["code"], "selector.ambiguous", "{}", pane.error);

    let terminal = super::super::agent_start::daemon::find_terminal(&named, "alpha")
        .expect_err("two live tabs are named alpha");
    assert_eq!(terminal.error["code"], "selector.ambiguous", "{}", terminal.error);

    // One live tab and one exited tab: the live one, as before.
    assert!(matches!(resolve(&snapshot(), "alpha"), Found::One(place) if place.terminal == ALPHA));
}
