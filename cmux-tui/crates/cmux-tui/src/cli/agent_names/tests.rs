use serde_json::{Value, json};

use super::{
    Found, Place, Scope, Target, args_with_words, replace, resolve, rewrite_words, targets,
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
        "send",
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
    let words = strings(&["terminal", "alpha", "send", "--text", "hi", "--wait", "idle"]);
    let found = targets(&words);
    assert_eq!(found, vec![positional(Scope::Terminal, "alpha", 1)]);
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
            Target {
                scope: Scope::Terminal,
                word: "alpha".into(),
                flag: Some("--terminal"),
                index: 3,
                inline: false,
            },
            Target {
                scope: Scope::Tab,
                word: "beta".into(),
                flag: Some("--tab"),
                index: 4,
                inline: true,
            },
        ]
    );

    let mut words = strings(&["terminal", "alpha", "send", "--text", "alpha"]);
    let found = targets(&words);
    let target = &found[0];
    replace(&mut words, target, ALPHA);
    assert_eq!(words, strings(&["terminal", ALPHA, "send", "--text", "alpha"]));
    let mut flagged = strings(&["agent", "list", "--terminal=beta"]);
    let found = targets(&flagged);
    let target = &found[0];
    replace(&mut flagged, target, BETA);
    assert_eq!(flagged, strings(&["agent", "list", &format!("--terminal={BETA}")]));
}

/// The daemon's answer for a `<scope> <word> show` probe, as the W5-P
/// resolver gives it for [`snapshot`]'s session.
fn daemon(target: &Target) -> Result<Option<String>, Value> {
    let id = match (target.scope, target.word.as_str()) {
        (Scope::Terminal, "alpha" | "term_a1a1") => ALPHA,
        (Scope::Terminal, "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2") => BETA,
        (Scope::Tab, "alpha") => "tab_alpha",
        (Scope::Pane, "alpha") => "pane_1",
        (_, "dup") => {
            return Err(json!({"code": "selector.ambiguous",
                              "details": {"candidates": ["tab_dup1", "tab_dup2"]}}));
        }
        _ => return Ok(None),
    };
    Ok(Some(id.to_owned()))
}

/// W5-P: the daemon is the one resolver. Each selector word that may be a
/// name, an id prefix or a bare (or host) id becomes the id the daemon
/// resolves it to, so `--terminal alpha` gives the full `term_` id that
/// `notification create` and `agent report` need, and a word the daemon
/// does not find stays for the command to report.
#[test]
fn w5p_the_daemon_resolves_every_selector_word_the_cli_rewrites() {
    let mut asked = Vec::new();
    let mut resolve = |target: &Target| {
        asked.push(target.word.clone());
        daemon(target)
    };
    let words = strings(&["terminal", "alpha", "send", "--text", "hi"]);
    assert_eq!(
        rewrite_words(&words, &mut resolve).unwrap(),
        Some(strings(&["terminal", ALPHA, "send", "--text", "hi"]))
    );
    let notify = strings(&["notification", "create", "--terminal", "alpha", "--title", "t"]);
    assert_eq!(
        rewrite_words(&notify, &mut resolve).unwrap(),
        Some(strings(&["notification", "create", "--terminal", ALPHA, "--title", "t"]))
    );
    let prefix = strings(&["agent", "report", "--terminal=term_a1a1", "--state", "idle"]);
    assert_eq!(
        rewrite_words(&prefix, &mut resolve).unwrap(),
        Some(strings(&["agent", "report", &format!("--terminal={ALPHA}"), "--state", "idle"]))
    );
    let host = strings(&["terminal", "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2", "screen", "read"]);
    assert_eq!(
        rewrite_words(&host, &mut resolve).unwrap(),
        Some(strings(&["terminal", BETA, "screen", "read"]))
    );
    // `tab alpha` and `pane alpha` select alpha's tab and pane.
    let tab = strings(&["tab", "alpha", "focus"]);
    assert_eq!(
        rewrite_words(&tab, &mut resolve).unwrap(),
        Some(strings(&["tab", "tab_alpha", "focus"]))
    );
    let pane = strings(&["pane", "alpha", "split"]);
    assert_eq!(
        rewrite_words(&pane, &mut resolve).unwrap(),
        Some(strings(&["pane", "pane_1", "split"]))
    );
    // Not found: the word stays. A full id is never asked about.
    let unnamed = strings(&["tab", "nobody", "focus"]);
    assert_eq!(rewrite_words(&unnamed, &mut resolve).unwrap(), None);
    let full = strings(&["terminal", ALPHA, "send", "--text", "hi"]);
    assert_eq!(rewrite_words(&full, &mut resolve).unwrap(), None);
    // The daemon's ambiguity is the CLI's error.
    let shared = strings(&["tab", "dup", "focus"]);
    let error = rewrite_words(&shared, &mut resolve).unwrap_err();
    assert_eq!(error["code"], "selector.ambiguous");
    assert_eq!(error["details"]["candidates"], json!(["tab_dup1", "tab_dup2"]));
    assert!(!asked.contains(&ALPHA.to_owned()), "{asked:?}");
}

/// W3-H review: a terminal title wins over a tab name in `terminal … send`
/// (send.rs), as titles did before names existed. (The daemon's resolver has
/// the same order; see cmux-tui-core `resource_selector/name_scope.rs`.)
#[test]
fn w3h_a_terminal_title_wins_over_a_tab_name() {
    use super::super::terminal_talk::send::find_terminal;
    let mut snapshot = snapshot();
    snapshot["terminals"][2]["title"] = json!("alpha");
    let found = find_terminal(&snapshot, "alpha").ok().map(|t| t["id"].clone());
    assert_eq!(found, Some(json!(BETA)));
    // Two terminals with the title stay ambiguous, as before.
    snapshot["terminals"][3]["title"] = json!("alpha");
    let error = find_terminal(&snapshot, "alpha").expect_err("ambiguous title");
    assert!(format!("{error:?}").contains("selector.ambiguous"), "{error:?}");
    // With no title, the name still selects its terminal.
    let found = find_terminal(&self::snapshot(), "alpha").ok().map(|t| t["id"].clone());
    assert_eq!(found, Some(json!(ALPHA)));
}

/// W3-H review: a subcommand word of the parser (`group` in `tab group
/// list`) is never a selector, and no agent can take it as a name.
#[test]
fn w3h_subcommand_words_are_not_rewritten_or_valid_names() {
    for words in [&["tab", "group", "list"][..], &["workspace", "group", "list"][..]] {
        assert!(targets(&strings(words)).is_empty(), "{words:?}");
    }
    assert!(valid_agent_name("group").is_err());
}

/// W3-H review: the scan reads flag values as the parser does: a flag that
/// is not a boolean flag takes the next word, even one that starts with
/// `--`, so `foo` below is a word, not the value of `--pane`.
#[test]
fn w3h_the_scan_skips_the_values_of_flags_that_take_one() {
    let words = strings(&["terminal", "alpha", "send", "--text", "--pane", "foo"]);
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
    let boolean = strings(&["agent", "list", "--details", "--tab", "beta"]);
    assert_eq!(targets(&boolean).len(), 1);
}

/// The changed words go back into the full arguments at the place the
/// global options leave them, never into a global option's value.
#[test]
fn w3h_rewritten_words_never_change_a_global_option_value() {
    let args = strings(&["--session", "alpha", "terminal", "alpha", "send", "--text", "alpha"]);
    let words = strings(&["terminal", "alpha", "send", "--text", "alpha"]);
    let rewritten = strings(&["terminal", ALPHA, "send", "--text", "alpha"]);
    assert_eq!(
        args_with_words(&args, &words, &rewritten),
        Some(strings(&["--session", "alpha", "terminal", ALPHA, "send", "--text", "alpha"]))
    );
}

/// Review (lead's reviewer, #38436): a live shell tab and a live agent tab with
/// one name are two candidates. The CLI does not prefer the agent tab: the
/// daemon's tab-name scope does not, so `tab alpha close` and `terminal alpha
/// send` could pick different objects. Live tabs still win over exited ones.
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

    let terminal = super::super::terminal_talk::send::find_terminal(&named, "alpha")
        .expect_err("two live tabs are named alpha");
    assert_eq!(terminal.failure.error["code"], "selector.ambiguous", "{}", terminal.failure.error);

    // One live tab and one exited tab: the live one, as before.
    assert!(matches!(resolve(&snapshot(), "alpha"), Found::One(place) if place.terminal == ALPHA));
}
