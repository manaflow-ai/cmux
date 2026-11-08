use super::*;
use crate::cli::command::{CommandPlan, ParsedCommand};

const TERM: &str = "term_0123456789abcdef0123456789abcdef";
const PANE: &str = "pane_0123456789abcdef0123456789abcdef";
const TAB: &str = "tab_0123456789abcdef0123456789abcdef";
const WORKSPACE: &str = "ws_0123456789abcdef0123456789abcdef";

/// Shell words with single quotes, the only quoting the recipes use.
fn words(command: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quoted = false;
    let mut started = false;
    for character in command.chars() {
        match character {
            '\'' => {
                quoted = !quoted;
                started = true;
            }
            ' ' if !quoted => {
                if started {
                    words.push(std::mem::take(&mut word));
                    started = false;
                }
            }
            other => {
                word.push(other);
                started = true;
            }
        }
    }
    assert!(!quoted, "unbalanced quote: {command}");
    if started {
        words.push(word);
    }
    words
}

/// The recipe's argv after `cmux`, with real-looking ids for the placeholders.
fn argv(command: &str) -> Vec<String> {
    let command = command
        .replace("<term>", TERM)
        .replace("<pane>", PANE)
        .replace("<tab>", TAB)
        .replace("<ws>", WORKSPACE);
    let mut words = words(&command);
    assert_eq!(words.remove(0), "cmux", "a recipe runs cmux: {command}");
    words
}

/// Every recipe command is one this build's `cmux` accepts: the public
/// parser takes it as a command, not help and not a usage error. A renamed
/// flag or verb fails here instead of in an agent's session.
#[test]
fn pane_cli_skill_every_recipe_command_parses_with_this_cli() {
    let mut checked = 0;
    for recipe in RECIPES {
        assert!(!recipe.commands.is_empty(), "{}", recipe.ask);
        for command in recipe.commands {
            let args = argv(command);
            match crate::cli::parse(&args) {
                Ok(ParsedCommand::Command { .. }) => {}
                Ok(ParsedCommand::Help(topic)) => {
                    panic!("{command}: parsed as help {topic:?}, not a command")
                }
                Err(failure) => panic!("{command}: {}", failure.error),
            }
            checked += 1;
        }
    }
    assert!(checked >= 20, "only {checked} recipe commands");
}

/// `identify` and `skill show` are commands; their `--help` is their own
/// topic; other words after them are usage errors.
#[test]
fn pane_cli_skill_and_identify_parse_as_commands_and_help() {
    let parse = |words: &[&str]| {
        crate::cli::parse(&words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>())
    };
    assert!(matches!(
        parse(&["--json", "identify"]),
        Ok(ParsedCommand::Command { plan: CommandPlan::Identify, .. })
    ));
    for words in [&["skill"][..], &["skill", "show"], &["--json", "skill", "show"]] {
        assert!(
            matches!(parse(words), Ok(ParsedCommand::Command { plan: CommandPlan::SkillShow, .. })),
            "{words:?}"
        );
    }
    for (words, topic) in [
        (&["identify", "--help"][..], "identify"),
        (&["help", "identify"], "identify"),
        (&["skill", "show", "--help"], "skill"),
        (&["skill", "-h"], "skill"),
        (&["help", "skill"], "skill"),
    ] {
        match parse(words) {
            Ok(ParsedCommand::Help(Some(found))) => assert_eq!(found, topic, "{words:?}"),
            _ => panic!("{words:?} is not help for {topic}"),
        }
    }
    assert!(parse(&["identify", "now"]).is_err());
    assert!(parse(&["skill", "install"]).is_err());
}

/// The help topics have text in both locales.
#[test]
fn pane_cli_skill_and_identify_help_is_localized() {
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let catalog = crate::localization::catalog_for_locale(locale);
        let identify = crate::cli::scope_help_for("identify", catalog);
        let skill = crate::cli::scope_help_for("skill", catalog);
        assert!(identify.contains("cmux identify"), "{locale}: {identify}");
        assert!(skill.contains("cmux skill show"), "{locale}: {skill}");
    }
    let english = crate::localization::catalog_for_locale("en_US.UTF-8");
    let japanese = crate::localization::catalog_for_locale("ja_JP.UTF-8");
    assert_ne!(english.pane_cli.identify_help, japanese.pane_cli.identify_help);
    assert_ne!(english.pane_cli.session, japanese.pane_cli.session);
}

/// The guide's scope table lists every public scope with the root help's
/// own description, and its usage blocks are the scopes' help text.
#[test]
fn pane_cli_skill_the_guide_renders_from_the_cli_metadata() {
    let guide = render(&None);
    for scope in crate::cli::PUBLIC_SCOPES {
        let row = guide
            .lines()
            .find(|line| line.starts_with(&format!("| `{scope}` |")))
            .unwrap_or_else(|| panic!("no row for {scope}"));
        assert!(row.len() > format!("| `{scope}` |  |").len(), "{scope} has no description");
    }
    assert!(guide.contains("| `session` | Inspect and control a session |"), "{guide}");
    for help in [crate::cli::TERMINAL_HELP, crate::cli::PANE_HELP, crate::cli::TAB_HELP] {
        let block = usage_block(help);
        assert!(block.lines().count() >= 5, "{block}");
        assert!(guide.contains(&block), "usage block missing:\n{block}");
    }
    assert!(guide.contains(&crate::version_string()));
    for recipe in RECIPES {
        assert!(guide.contains(&format!("### \"{}\"", recipe.ask)));
    }
}

/// The guide names the JSON fields an agent reads and the rules that keep it
/// off the person's pane.
#[test]
fn pane_cli_skill_the_guide_covers_identity_targeting_waits_errors_and_cleanup() {
    let guide = render(&None);
    for needle in [
        "cmux --json identify",
        "caller.pane",
        "caller.terminal_id",
        "session current snapshot",
        "`current` is the session's focused object",
        "Never move the person's focus",
        "screen wait",
        "process wait",
        "outcome.code",
        "retryable",
        "--idempotency-key",
        "Close only what you created",
        "value.terminal_id",
    ] {
        assert!(guide.contains(needle), "the guide lacks {needle:?}");
    }
    assert!(guide.contains("does not run in a cmux-tui terminal"));
}

/// Run in a terminal, the guide starts with the caller's live ids.
#[test]
fn pane_cli_skill_the_guide_names_the_callers_place() {
    let identity = json!({
        "session": {"id": "session_1", "name": "bench"},
        "caller": {
            "found": true,
            "workspace": "ws_1",
            "screen": "screen_1",
            "pane": "pane_1",
            "tab": "tab_1",
            "terminal_id": "term_1",
        },
    });
    let guide = render(&Some(identity));
    for row in [
        "| session | `session_1` (name `bench`) |",
        "| workspace | `ws_1` |",
        "| pane | `pane_1` |",
        "| terminal | `term_1` |",
    ] {
        assert!(guide.contains(row), "{row}\n{guide}");
    }
    let location = guide.find("## Where you are").unwrap();
    assert!(location < guide.find("## Rules").unwrap());
}
