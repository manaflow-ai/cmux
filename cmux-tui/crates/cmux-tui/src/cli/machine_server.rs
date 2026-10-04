//! `cmux server …`: the machine server verbs (plans/cmux-next/server.md,
//! crate `cmux-server`), mounted on the `cmux` surface only (decision D1).
//! There the session daemon's lifecycle is `cmux daemon …`; the `cmux-tui`
//! surface keeps `server` for that lifecycle (its callers: the app's daemon
//! launcher, iOS remotes, scripts and Cloud guests) and accepts `daemon`
//! too. Nothing on `cmux` reaches the lifecycle through `server`.

use super::command::ParsedCommand;
use super::{OutputMode, Surface, UsageError};

/// The help topic of `cmux help server` on the `cmux` surface.
pub(super) const HELP_TOPIC: &str = "machine-server";

/// Words of the old lifecycle under `server` that are not machine server
/// verbs. On `cmux` they fail with a hint to `cmux daemon <verb>` (exit 2),
/// with no alias. `status` is both; the machine server owns it.
const MOVED_LIFECYCLE_VERBS: &[&str] = &["start", "ensure", "stats", "stop", "reload-config"];

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
/// arguments for `cmux_server`, or a usage error with the output mode to
/// print it in. `None`: not `cmux server`. Only `--json` and
/// `--idempotency-key` apply (the global parser takes them from any
/// position); every other global option is refused, never dropped. An old
/// lifecycle verb that the machine server does not have is refused with a
/// hint to `cmux daemon`.
pub(super) fn args_for(
    args: &[String],
    surface: Surface,
) -> Option<Result<Vec<String>, (UsageError, OutputMode)>> {
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
        let mut error = catalog.server_global_option_refused.replace("{option}", option);
        // `--session`/`--socket` with an old lifecycle verb (`cmux --session
        // agents server status`) meant the daemon: say where it moved.
        if matches!(*option, "--session" | "--socket")
            && let Some(verb) = rest.first().filter(|verb| {
                verb.as_str() == "status" || MOVED_LIFECYCLE_VERBS.contains(&verb.as_str())
            })
        {
            error.push_str("; ");
            error.push_str(&catalog.daemon_lifecycle_moved.replace("{verb}", verb));
        }
        return refuse(error);
    }
    if let Some(verb) = rest.first().filter(|verb| MOVED_LIFECYCLE_VERBS.contains(&verb.as_str())) {
        return refuse(catalog.daemon_lifecycle_moved.replace("{verb}", verb));
    }
    let mut out = rest.to_vec();
    if global.output == OutputMode::Json {
        out.push("--json".to_owned());
    }
    if let Some(key) = &global.idempotency_key {
        out.push(format!("--idempotency-key={key}"));
    }
    Some(Ok(out))
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

/// Runs `cmux server …` and returns its exit code. A usage error is
/// printed where every `cmux` scope prints it (stderr; JSON with `--json`).
pub(super) fn run_if_requested(args: &[String], surface: Surface) -> Option<i32> {
    match args_for(args, surface)? {
        Ok(server_args) => {
            if let Err(code) = end_on_termination_signals() {
                return Some(code);
            }
            let guard = std::env::var(cmux_server_core::reexec::GUARD_ENV).ok();
            Some(i32::from(cmux_server::cli::run_code(&server_args, guard, release_version())))
        }
        Err((error, output)) => {
            let message = match output {
                OutputMode::Quiet | OutputMode::Human => format!("cmux: {error}"),
                OutputMode::Json | OutputMode::JsonLines => error.to_string(),
            };
            let body = serde_json::json!({
                "code": "usage.invalid", "message": message, "details": {}, "retryable": false,
            });
            Some(super::wire::print_local_error(&body, output, 2))
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
