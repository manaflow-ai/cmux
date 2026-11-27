use super::*;
<<<<<<< ours
use crate::cli::{ParsedCommand, Surface};

const TERM: &str = "term_0123456789abcdef0123456789abcdef";
const PANE: &str = "pane_0123456789abcdef0123456789abcdef";
const TAB: &str = "tab_0123456789abcdef0123456789abcdef";
const WS: &str = "ws_0123456789abcdef0123456789abcdef";
=======
use crate::cli::command::{CommandPlan, ParsedCommand};

const TERM: &str = "term_0123456789abcdef0123456789abcdef";
const PANE: &str = "pane_0123456789abcdef0123456789abcdef";
const NEW_PANE: &str = "pane_fedcba9876543210fedcba9876543210";
const TAB: &str = "tab_0123456789abcdef0123456789abcdef";
const WORKSPACE: &str = "ws_0123456789abcdef0123456789abcdef";
>>>>>>> theirs

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
<<<<<<< ours
        .replace("<pane>", PANE)
        .replace("<tab>", TAB)
        .replace("<ws>", WS);
=======
        .replace("<new-pane>", NEW_PANE)
        .replace("<pane>", PANE)
        .replace("<tab>", TAB)
        .replace("<ws>", WORKSPACE);
>>>>>>> theirs
    let mut words = words(&command);
    assert_eq!(words.remove(0), "cmux", "a recipe runs cmux: {command}");
    words
}

<<<<<<< ours
/// Every recipe command is one this build's `cmux` accepts: the parser that
/// would run it (the terminal talk and wait verbs, identify, the resource
/// grammar) takes it without a usage error. A renamed flag or verb fails here
/// instead of in an agent's session.
#[cfg(unix)]
#[test]
fn every_recipe_command_parses_with_this_cli() {
=======
/// Every recipe command is one this build's `cmux` accepts: the public
/// parser takes it as a command, not help and not a usage error. A renamed
/// flag or verb fails here instead of in an agent's session.
#[test]
fn pane_cli_skill_every_recipe_command_parses_with_this_cli() {
>>>>>>> theirs
    let mut checked = 0;
    for recipe in RECIPES {
        assert!(!recipe.commands.is_empty(), "{}", recipe.ask);
        for command in recipe.commands {
            let args = argv(command);
<<<<<<< ours
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
=======
            match crate::cli::parse(&args) {
                Ok(ParsedCommand::Command { .. }) => {}
                Ok(ParsedCommand::Help(topic)) => {
                    panic!("{command}: parsed as help {topic:?}, not a command")
                }
                Err(failure) => panic!("{command}: {}", failure.error),
>>>>>>> theirs
            }
            checked += 1;
        }
    }
<<<<<<< ours
    assert!(checked >= 25, "only {checked} recipe commands");
}

/// The guide's scope table lists every scope `cmux` accepts, with the root
/// help's own description, and its usage blocks are the scopes' help text.
#[test]
fn the_guide_renders_from_the_cli_metadata() {
    let guide = render(&None);
    for scope in crate::cli::surface::CMUX_SCOPES {
=======
    assert!(checked >= 20, "only {checked} recipe commands");
}

/// No recipe runs a command in the caller's own pane: `run` shows its new tab
/// in the pane it names, so it goes to a pane the recipe split.
#[test]
fn pane_cli_skill_no_recipe_runs_in_the_callers_pane() {
    // `pane <id> run`, not a shell command such as `npm run dev` in a write.
    let runs: Vec<_> = RECIPES
        .iter()
        .flat_map(|recipe| recipe.commands)
        .filter(|command| argv(command).windows(3).any(|w| w[0] == "pane" && w[2] == "run"))
        .collect();
    assert!(!runs.is_empty());
    for command in runs {
        assert!(command.contains("pane <new-pane> run"), "{command}");
    }
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
    let (en, ja) = (&english.pane_cli, &japanese.pane_cli);
    for (english, japanese) in [
        (en.identify_help, ja.identify_help),
        (en.session, ja.session),
        (en.outside_terminal, ja.outside_terminal),
        (en.not_in_workspace, ja.not_in_workspace),
        (en.unreachable, ja.unreachable),
        (en.identify_arguments, ja.identify_arguments),
        (en.skill_arguments, ja.skill_arguments),
        (en.root_agent_commands, ja.root_agent_commands),
    ] {
        assert_ne!(english, japanese);
    }
    for messages in [en, ja] {
        assert!(messages.not_in_workspace.contains("{terminal}"));
        assert!(
            messages.unreachable.contains("{socket}") && messages.unreachable.contains("{error}")
        );
        assert!(messages.identify_arguments.contains("{words}"));
        assert!(messages.skill_arguments.contains("{words}"));
        assert!(messages.root_agent_commands.contains("skill show"));
    }
    for catalog in [english, japanese] {
        let help = crate::cli::root_help(catalog);
        assert!(help.contains(catalog.pane_cli.root_agent_commands), "{help}");
    }
}

/// The guide's scope table lists every public scope with the root help's
/// own description, and its usage blocks are the scopes' help text.
#[test]
fn pane_cli_skill_the_guide_renders_from_the_cli_metadata() {
    let guide = render(&None, None);
    for scope in crate::cli::PUBLIC_SCOPES {
>>>>>>> theirs
        let row = guide
            .lines()
            .find(|line| line.starts_with(&format!("| `{scope}` |")))
            .unwrap_or_else(|| panic!("no row for {scope}"));
        assert!(row.len() > format!("| `{scope}` |  |").len(), "{scope} has no description");
    }
<<<<<<< ours
    assert!(guide.contains("| `session` | This session: snapshot"), "{guide}");
    for help in [crate::cli::TERMINAL_HELP, crate::cli::PANE_HELP, crate::cli::TAB_HELP] {
        let block = usage_block(help);
        assert!(block.lines().count() > 5, "{block}");
=======
    assert!(guide.contains("| `session` | Inspect and control a session |"), "{guide}");
    assert!(
        guide.contains("| `server` | Manage one named local durable session owner |"),
        "{guide}"
    );
    for help in [crate::cli::TERMINAL_HELP, crate::cli::PANE_HELP, crate::cli::TAB_HELP] {
        let block = usage_block(help);
        assert!(block.lines().count() >= 5, "{block}");
>>>>>>> theirs
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
<<<<<<< ours
fn the_guide_covers_identity_targeting_waits_errors_and_cleanup() {
    let guide = render(&None);
=======
fn pane_cli_skill_the_guide_covers_identity_targeting_waits_errors_and_cleanup() {
    let guide = render(&None, None);
>>>>>>> theirs
    for needle in [
        "cmux --json identify",
        "caller.pane",
        "caller.terminal_id",
        "session current snapshot",
<<<<<<< ours
        "`current` and `caller` are your own",
        "Never move the person's focus",
        "--wait prompt",
=======
        "`current` is the session's focused object",
        "Never move the person's focus",
>>>>>>> theirs
        "screen wait",
        "process wait",
        "outcome.code",
        "retryable",
        "--idempotency-key",
<<<<<<< ours
        "124",
        "Every wait whose time ran out prints `timed_out: true` and exits 124",
=======
>>>>>>> theirs
        "Close only what you created",
        "value.terminal_id",
    ] {
        assert!(guide.contains(needle), "the guide lacks {needle:?}");
    }
<<<<<<< ours
    assert!(guide.contains("does not run in a cmux terminal"));
}

/// Run in a pane, the guide starts with the caller's live ids.
#[test]
fn the_guide_names_the_callers_place() {
=======
    assert!(guide.contains("does not run in a cmux-tui terminal"));
}

/// Run in a terminal, the guide starts with the caller's live ids.
#[test]
fn pane_cli_skill_the_guide_names_the_callers_place() {
>>>>>>> theirs
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
<<<<<<< ours
    let guide = render(&Some(identity));
=======
    let guide = render(&Some(identity), Some(Path::new("/opt/cmux/cmux-tui")));
    assert!(guide.contains("this build's CLI, `/opt/cmux/cmux-tui`"), "{guide}");
>>>>>>> theirs
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
<<<<<<< ours

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
=======
>>>>>>> theirs
