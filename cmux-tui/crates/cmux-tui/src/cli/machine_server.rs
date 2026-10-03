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

/// Whether `word` names the session daemon's lifecycle scope for this
/// invocation: `daemon` (or `srv`) on both surfaces, and `server` on the
/// `cmux-tui` surface only (on `cmux`, `server` is the machine server).
pub(crate) fn is_lifecycle_scope(word: &str) -> bool {
    lifecycle_scope_for(word, Surface::current())
}

pub(super) fn lifecycle_scope_for(word: &str, surface: Surface) -> bool {
    super::canonical_scope(word) == "server" && !(surface == Surface::Cmux && word == "server")
}

/// On `cmux`, the words as typed (before shorthands lower `daemon` and
/// `srv` to the internal lifecycle scope `server`): `help server` is the
/// machine server's help, and `server …` that reached the parser is
/// refused, so `server` is never the lifecycle there. `None`: not decided
/// here.
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
        (Some("server"), _) => Some(Err(UsageError::new(
            crate::localization::catalog().local_server.server_is_machine_server,
        ))),
        _ => None,
    }
}

/// The arguments for `cmux_server` when `args` (after the program name) is
/// `cmux [global options] server …` on the `cmux` surface; `None` otherwise.
/// `--json` and `--idempotency-key`, which the global parser takes from any
/// position, are passed on; the other global options do not apply.
pub(super) fn args_for(args: &[String], surface: Surface) -> Option<Vec<String>> {
    if surface != Surface::Cmux {
        return None;
    }
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "server" {
        return None;
    }
    let mut out = rest.to_vec();
    if global.output == OutputMode::Json {
        out.push("--json".to_owned());
    }
    if let Some(key) = &global.idempotency_key {
        out.push(format!("--idempotency-key={key}"));
    }
    Some(out)
}

/// Runs `cmux server …` and returns its exit code.
pub(super) fn run_if_requested(args: &[String], surface: Surface) -> Option<i32> {
    let server_args = args_for(args, surface)?;
    let guard = std::env::var(cmux_server_core::reexec::GUARD_ENV).ok();
    Some(i32::from(cmux_server::cli::run_code(&server_args, guard, release_version())))
}

/// This binary's release version, compared with a manifest's
/// `min_cmux_version`: `CMUX_VERSION` stamped at build time, else the
/// crate version. Release builds must stamp it.
pub(super) fn release_version() -> &'static str {
    option_env!("CMUX_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

/// `cmux help server` on the `cmux` surface.
pub(super) fn help() -> String {
    cmux_server::cli::args::help()
}
