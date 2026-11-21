use serde_json::{Value, json};

use super::{Scope, Target, args_with_words, replace, rewrite_words, targets, valid_agent_name};

const ALPHA: &str = "term_a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const BETA: &str = "term_b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
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
