//! `cmux server …`: the machine server verbs (plans/cmux-next/server.md,
//! crate `cmux-server`), mounted on the `cmux` surface only (decision D1).
//! There the session daemon's lifecycle is `cmux daemon …`; the `cmux-tui`
//! surface keeps `server` for that lifecycle (its callers: the app's daemon
//! launcher, iOS remotes, scripts and Cloud guests) and accepts `daemon`
//! too. On `cmux`, the pre-D1 lifecycle spellings (`server start|ensure|
//! stats|stop|reload-config`, and `server status` with --session or
//! --socket) are rewritten to `daemon` and run, with a deprecation hint in
//! human output, so released scripts keep working.

use super::command::ParsedCommand;
use super::{OutputMode, Surface, UsageError};

/// The help topic of `cmux help server` on the `cmux` surface.
pub(super) const HELP_TOPIC: &str = "machine-server";

/// Words of the old lifecycle under `server` that are not machine server
/// verbs. On `cmux` they run as `cmux daemon <verb>` with a deprecation
/// hint. `status` is both; the machine server owns it unless --session or
/// --socket names a daemon.
const MOVED_LIFECYCLE_VERBS: &[&str] = &["start", "ensure", "stats", "stop", "reload-config"];

/// Where `cmux … server …` goes on the `cmux` surface.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ServerRoute {
    /// `cmux_server` with these arguments.
    Machine(Vec<String>),
    /// A pre-D1 lifecycle spelling: the same words with the noun `server`
    /// replaced by `daemon`, and the lifecycle verb for the hint.
    DeprecatedLifecycle { args: Vec<String>, verb: String },
}

/// Whether `word` names the session daemon's lifecycle scope for this
/// invocation: `daemon` on both surfaces; `server` and `srv` on the
/// `cmux-tui` surface only (on `cmux`, `server` is the machine server and
/// `srv` is not a shorthand).
pub(crate) fn is_lifecycle_scope(word: &str) -> bool {
    lifecycle_scope_for(word, Surface::current())
}

pub(super) fn lifecycle_scope_for(word: &str, surface: Surface) -> bool {
    super::canonical_scope(word) == "server"
        && !(surface == Surface::Cmux && matches!(word, "server" | "srv"))
}

/// On `cmux`, the words as typed (before shorthands lower `daemon` and
/// `srv` to the internal lifecycle scope `server`): `help server` is the
/// machine server's help, `server …` that reached the parser is refused (so
/// `server` is never the lifecycle there), and `srv` is not a scope.
/// `None`: not decided here.
pub(super) fn cmux_words(
    command_args: &[String],
    surface: Surface,
) -> Option<Result<ParsedCommand, UsageError>> {
    if surface != Surface::Cmux {
        return None;
    }
    match (command_args.first().map(String::as_str), command_args.get(1).map(String::as_str)) {
        (Some("help"), Some("server")) => {
            Some(Ok(ParsedCommand::Help(Some(HELP_TOPIC.to_owned()))))
        }
        (Some("server"), _) => {
            Some(Err(UsageError::new(crate::localization::server_mount().server_is_machine_server)))
        }
        (Some("srv"), _) | (Some("help"), Some("srv")) => {
            Some(Err(super::unknown_scope("srv", surface)))
        }
        _ => None,
    }
}

/// What `cmux [global options] server …` on the `cmux` surface runs: the
/// arguments for `cmux_server`, the rewritten daemon lifecycle words for a
/// pre-D1 spelling, or a usage error with the output mode to print it in.
/// `None`: not `cmux server`. For the machine server only `--json` and
/// `--idempotency-key` apply (the global parser takes them from any
/// position); every other global option is refused, never dropped.
pub(super) fn args_for(
    args: &[String],
    surface: Surface,
) -> Option<Result<ServerRoute, (UsageError, OutputMode)>> {
    if surface != Surface::Cmux {
        return None;
    }
    let (global, command_args) = match super::parse_globals(args) {
        Ok(parsed) => parsed,
        Err(failure) => return Some(Err(failure)).filter(|_| names_server(args)),
    };
    let (first, rest) = command_args.split_first()?;
    if first != "server" {
        return None;
    }
    let lifecycle_verb = rest.first().filter(|verb| {
        MOVED_LIFECYCLE_VERBS.contains(&verb.as_str())
            || (verb.as_str() == "status" && (global.session.is_some() || global.socket.is_some()))
    });
    if let Some(verb) = lifecycle_verb {
        return Some(Ok(ServerRoute::DeprecatedLifecycle {
            args: with_daemon_noun(args),
            verb: verb.clone(),
        }));
    }
    let catalog = crate::localization::server_mount();
    let refuse = |error: String| Some(Err((UsageError::new(error), global.output)));
    let refused = [
        (global.socket.is_some(), "--socket"),
        (global.session.is_some(), "--session"),
        (global.machine.is_some(), "--machine"),
        (global.app_socket.is_some(), "--app-socket"),
        (global.all_sessions, "--all-sessions"),
        (global.output == OutputMode::JsonLines, "--jsonl"),
        (global.output == OutputMode::Quiet, "--quiet"),
    ];
    if let Some((_, option)) = refused.iter().find(|(set, _)| *set) {
        return refuse(catalog.server_global_option_refused.replace("{option}", option));
    }
    let mut out = rest.to_vec();
    if global.output == OutputMode::Json {
        out.push("--json".to_owned());
    }
    if let Some(key) = &global.idempotency_key {
        out.push(format!("--idempotency-key={key}"));
    }
    Some(Ok(ServerRoute::Machine(out)))
}

/// `args` with the noun (the first word that is neither an option nor an
/// option's value, as in [`names_server`]) replaced by `daemon`.
fn with_daemon_noun(args: &[String]) -> Vec<String> {
    let mut out = args.to_vec();
    let mut index = 0;
    while index < out.len() {
        let word = out[index].as_str();
        if VALUE_OPTIONS.contains(&word) {
            index += 2;
        } else if word.starts_with('-') {
            index += 1;
        } else {
            out[index] = "daemon".to_owned();
            break;
        }
    }
    out
}

/// Global options whose value is the next word (`--session NAME`).
const VALUE_OPTIONS: &[&str] =
    &["--socket", "--session", "--machine", "--app-socket", "--idempotency-key"];

/// Whether the first word that is neither an option nor an option's value
/// is `server` (for a global option error before the noun is known).
fn names_server(args: &[String]) -> bool {
    let mut words = args.iter();
    while let Some(word) = words.next() {
        if VALUE_OPTIONS.contains(&word.as_str()) {
            words.next();
        } else if !word.starts_with('-') {
            return word == "server";
        }
    }
    false
}

/// For `main`, before `server start` becomes the headless startup: a
/// pre-D1 lifecycle spelling on `cmux` becomes the same words with
/// `daemon`, after the deprecation hint. `None`: nothing to rewrite.
pub(super) fn deprecated_lifecycle(args: &[String], surface: Surface) -> Option<Vec<String>> {
    match args_for(args, surface)? {
        Ok(ServerRoute::DeprecatedLifecycle { args, verb }) => {
            Some(announce_deprecated(args, &verb))
        }
        _ => None,
    }
}

/// Prints the deprecation hint (human output only, so JSON stays machine
/// readable) and returns `args`.
fn announce_deprecated(args: Vec<String>, verb: &str) -> Vec<String> {
    let human =
        super::parse_globals(&args).map_or(true, |(global, _)| global.output == OutputMode::Human);
    if human {
        let hint = crate::localization::server_mount().daemon_lifecycle_deprecated;
        eprintln!("cmux: {}", hint.replace("{verb}", verb));
    }
    args
}

/// What [`run_if_requested`] did with `cmux server …`.
pub(super) enum Mount {
    /// The machine server ran, or a usage error was printed: exit with it.
    Exit(i32),
    /// A pre-D1 lifecycle spelling: run these words as the CLI instead.
    Lifecycle(Vec<String>),
}

/// Runs `cmux server …`. A usage error is printed where every `cmux` scope
/// prints it (stderr; JSON with `--json`). A pre-D1 lifecycle spelling
/// prints the deprecation hint (human output only, so JSON stays machine
/// readable) and returns the rewritten words.
pub(super) fn run_if_requested(args: &[String], surface: Surface) -> Option<Mount> {
    match args_for(args, surface)? {
        Ok(ServerRoute::Machine(server_args)) => {
            if let Err(code) = end_on_termination_signals() {
                return Some(Mount::Exit(code));
            }
            let guard = std::env::var(cmux_server_core::reexec::GUARD_ENV).ok();
            let code = cmux_server::cli::run_code(&server_args, guard, release_version());
            Some(Mount::Exit(i32::from(code)))
        }
        Ok(ServerRoute::DeprecatedLifecycle { args, verb }) => {
            Some(Mount::Lifecycle(announce_deprecated(args, &verb)))
        }
        Err((error, output)) => {
            let message = match output {
                OutputMode::Quiet | OutputMode::Human => format!("cmux: {error}"),
                OutputMode::Json | OutputMode::JsonLines => error.to_string(),
            };
            let body = serde_json::json!({
                "code": "usage.invalid", "message": message, "details": {}, "retryable": false,
            });
            Some(Mount::Exit(super::wire::print_local_error(&body, output, 2)))
        }
    }
}

/// `main` has set SIGTERM, SIGINT and SIGHUP to only request a mux
/// shutdown, and `cmux_server` never reads that request. Give them back
/// their default action so Ctrl-C or a service manager's SIGTERM ends an
/// install, upgrade or backup. `Err`: the exit code when a signal already
/// arrived (130) or the reset failed (1).
pub(super) fn end_on_termination_signals() -> Result<(), i32> {
    #[cfg(unix)]
    match crate::restore_default_termination_signals() {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => return Err(130),
        Err(error) => {
            eprintln!("cmux: {error}");
            return Err(1);
        }
    }
    Ok(())
}

/// This binary's release version, compared with a manifest's
/// `min_cmux_version`: this crate's version, the `cmux` version scale
/// (`cmux_server_core::manifest::CMUX_VERSION`, kept equal by a test).
pub(super) fn release_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// `cmux help server` on the `cmux` surface.
pub(super) fn help() -> String {
    cmux_server::cli::args::help()
}
