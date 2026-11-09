use super::*;
use crate::cli::{ParsedCommand, Surface};

const TERM: &str = "term_0123456789abcdef0123456789abcdef";
const PANE: &str = "pane_0123456789abcdef0123456789abcdef";
const TAB: &str = "tab_0123456789abcdef0123456789abcdef";
const WS: &str = "ws_0123456789abcdef0123456789abcdef";

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
        .replace("<ws>", WS);
    let mut words = words(&command);
    assert_eq!(words.remove(0), "cmux", "a recipe runs cmux: {command}");
    words
}

/// Every recipe command is one this build's `cmux` accepts: the parser that
/// would run it (the terminal talk and wait verbs, identify, the resource
/// grammar) takes it without a usage error. A renamed flag or verb fails here
/// instead of in an agent's session.
#[cfg(unix)]
#[test]
fn every_recipe_command_parses_with_this_cli() {
    let mut checked = 0;
    for recipe in RECIPES {
        assert!(!recipe.commands.is_empty(), "{}", recipe.ask);
        for command in recipe.commands {
            let args = argv(command);
            let (_, words) = crate::cli::parse_globals(&args).unwrap_or_else(|(error, _)| {
                panic!("{command}: {error}");
            });
            let strs = words.iter().map(String::as_str).collect::<Vec<_>>();
            match strs.as_slice() {
                ["identify"] => assert!(crate::cli::app::is_classic_identify(&words)),
                ["terminal", "list", flags @ ..] if flags.contains(&"--agents") => {
                    let flags = words[2..].to_vec();
                    assert!(crate::cli::terminal_talk::parse_list(&flags).is_ok(), "{command}");
                }
                ["terminal", target, "send", ..] => {
                    let flags = words[3..].to_vec();
                    if let Err(error) = crate::cli::terminal_talk::parse_send(target, &flags) {
                        panic!("{command}: {error}");
                    }
                }
                ["terminal", target, "run", ..] => {
                    let flags = words[3..].to_vec();
                    if let Err(error) = crate::cli::terminal_talk::parse_run(target, &flags) {
                        panic!("{command}: {error}");
                    }
                }
                ["workspace", "create", flags @ ..] if flags.contains(&"--worktree") => {
                    let flags = words[2..].to_vec();
                    if let Err(error) = crate::cli::worktree_workspace::parse_create(&flags) {
                        panic!("{command}: {error}");
                    }
                }
                ["workspace", target, "close", flags @ ..]
                    if flags.contains(&"--remove-worktree") =>
                {
                    let flags = words[3..].to_vec();
                    if let Err(error) = crate::cli::worktree_workspace::parse_close(target, &flags)
                    {
                        panic!("{command}: {error}");
                    }
                }
                ["pane", target, "move", ..] => {
                    let flags = words[3..].to_vec();
                    if let Err(error) = crate::cli::pane_move::parse(target, &flags) {
                        panic!("{command}: {error}");
                    }
                }
                ["agents", "events", ..] => {
                    if let Err(error) = crate::cli::agents::command(&words[1..]) {
                        panic!("{command}: {}", error.0);
                    }
                }
                ["events", ..] => match crate::cli::app::parse(&words) {
                    Ok(Some(_)) => {}
                    Ok(None) => panic!("{command}: not an app command"),
                    Err(error) => panic!("{command}: {}", error.0),
                },
                ["agent", "start" | "resume", ..] | ["terminal", _, "resume", ..] => {
                    match crate::cli::agent_start::parse(&words) {
                        Some(Ok(_)) => {}
                        other => panic!("{command}: {other:?}"),
                    }
                }
                ["terminal", _, "wait", ..] => {
                    assert!(
                        crate::cli::status::terminal_wait_flags_parse(&words[3..]),
                        "{command}"
                    );
                }
                _ => match crate::cli::parse(&args, Surface::Cmux) {
                    Ok(ParsedCommand::Command { .. }) => {}
                    Ok(_) => panic!("{command}: parsed as help, not a command"),
                    Err(failure) => panic!("{command}: {}", failure.error),
                },
            }
            checked += 1;
        }
    }
    assert!(checked >= 25, "only {checked} recipe commands");
}

/// The guide's scope table lists every scope `cmux` accepts, with the root
/// help's own description, and its usage blocks are the scopes' help text.
#[test]
fn the_guide_renders_from_the_cli_metadata() {
    let guide = render(&None);
    for scope in crate::cli::surface::CMUX_SCOPES {
        let row = guide
            .lines()
            .find(|line| line.starts_with(&format!("| `{scope}` |")))
            .unwrap_or_else(|| panic!("no row for {scope}"));
        assert!(row.len() > format!("| `{scope}` |  |").len(), "{scope} has no description");
    }
    assert!(guide.contains("| `session` | This session: snapshot"), "{guide}");
    for help in [crate::cli::TERMINAL_HELP, crate::cli::PANE_HELP, crate::cli::TAB_HELP] {
        let block = usage_block(help);
        assert!(block.lines().count() > 5, "{block}");
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
fn the_guide_covers_identity_targeting_waits_errors_and_cleanup() {
    let guide = render(&None);
    for needle in [
        "cmux --json identify",
        "caller.pane",
        "caller.terminal_id",
        "session current snapshot",
        "`current` and `caller` are your own",
        "Never move the person's focus",
        "--wait prompt",
        "screen wait",
        "process wait",
        "outcome.code",
        "retryable",
        "--idempotency-key",
        "124",
        "Close only what you created",
        "value.terminal_id",
    ] {
        assert!(guide.contains(needle), "the guide lacks {needle:?}");
    }
    assert!(guide.contains("does not run in a cmux terminal"));
}

/// Run in a pane, the guide starts with the caller's live ids.
#[test]
fn the_guide_names_the_callers_place() {
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

/// W5-Q (bench round 4 orchestration #3): in a pane the guide says to run
/// the session's own cmux as `"$CMUX_TUI_CLI"`, since the `cmux` on PATH can
/// be an older install without `skill show`. Outside a pane it does not.
#[test]
fn w5q_the_guide_in_a_pane_runs_the_sessions_own_cmux() {
    let identity = json!({
        "session": {"id": "session_1", "name": "bench"},
        "caller": {"found": true, "terminal_id": "term_1"},
    });
    let section = |pane_cli: Option<&str>| {
        let guide = render_with(&Some(identity.clone()), pane_cli);
        let place = guide.find("## Where you are").unwrap_or_default();
        let rules = guide.find("## Rules").unwrap_or_default();
        guide.get(place..rules).unwrap_or_default().to_owned()
    };
    let own = section(Some("/opt/cmux/bin/cmux"));
    assert!(own.contains("\"$CMUX_TUI_CLI\""), "{own}");
    assert!(!own.contains("`cmux` on your PATH talks to this session"), "{own}");
    let outside = render_with(&None, Some("/opt/cmux/bin/cmux"));
    assert!(!outside.contains("$CMUX_TUI_CLI"), "{outside}");
}

/// W5-Q review (PR B finding 4): a pane without an absolute `CMUX_TUI_CLI`
/// (an older daemon's pane, a build that could not link its own `cmux`)
/// gets `cmux`, never `"$CMUX_TUI_CLI"`, which would run `""` there.
#[test]
fn w5q_the_guide_says_cmux_without_cmux_tui_cli() {
    let identity = json!({
        "session": {"id": "session_1", "name": "bench"},
        "caller": {"found": true, "terminal_id": "term_1"},
    });
    for pane_cli in [None, Some(""), Some("cmux")] {
        let guide = render_with(&Some(identity.clone()), pane_cli);
        assert!(!guide.contains("CMUX_TUI_CLI"), "{pane_cli:?}: {guide}");
    }
}

#[test]
fn skill_parses_show_help_and_refuses_other_verbs() {
    let args = |words: &[&str]| words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    assert_eq!(run_if_requested(&args(&["workspace", "list"])), None);
    assert_eq!(run_if_requested(&args(&["skill", "show", "--help"])), Some(0));
    assert_eq!(run_if_requested(&args(&["skill", "install"])), Some(2));
}
