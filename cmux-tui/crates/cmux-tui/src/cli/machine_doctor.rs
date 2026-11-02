//! `cmux machine doctor [MACHINE] [--fix]` for machines that joined with a
//! pasted line, on both ends.
//!
//! - No machine: this machine's own join (`acpmux host doctor --here`, run
//!   in-process): binary, service, daemon, credential, revoked, hub,
//!   heartbeat and consent.
//! - A joined machine's id or name: the minting end, from the platform's
//!   lists: signed in, platform on, listed and not revoked, heartbeat, mesh.
//! - Anything else is the app's ssh Check Machine (`machine.doctor`), as
//!   before; with no app to run it, the minting end's checklist says why the
//!   machine is not a joined one.
//!
//! Every mode prints the Add Machine checklist's lines: aligned text for a
//! person, `{"step","state","detail","fix"}` lines and a `{"report":…}` line
//! for `--json`/`--jsonl`, nothing for `--quiet`. The exit code is 0 when
//! every step is healthy, else 1.

use std::io::Write;

use acpmux::cli::host_join_doctor::{self as doctor, JoinStep, Print};
use acpmux::cli::host_steps::StepState;
use serde_json::Value;

use super::OutputMode;
use super::machine_join::{self, CallError, Platform};

const USAGE: &str = "usage: cmux machine doctor [MACHINE] [--fix]
  with no MACHINE, checks this machine's join; with a joined machine's id or name, checks it from here
  (--platform URL, --cloud-token-file PATH, --cloud-token-stdin or CMUX_CLOUD_ACCESS_TOKEN)";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Command {
    pub machine: Option<String>,
    pub fix: bool,
    pub auth: machine_join::Auth,
}

/// `Some(exit code)` when `args` is `machine doctor …` for a joined machine or this one.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let parsed = parse(&command_args)?;
    let command = match parsed {
        Ok(command) => command,
        Err(message) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}\n{USAGE}"),
                global.output,
                2,
            ));
        }
    };
    let print = match global.output {
        OutputMode::Human => Print::Human,
        OutputMode::Json | OutputMode::JsonLines => Print::Lines,
        OutputMode::Quiet => Print::Quiet,
    };
    let stdout = &mut std::io::stdout();
    let Some(key) = &command.machine else {
        return Some(doctor::run_here(command.fix, print, stdout));
    };
    let env = |key: &str| std::env::var(key).ok();
    let credential =
        machine_join::read_credential(&command.auth, &env, &mut std::io::stdin().lock())
            .ok()
            .flatten();
    let origin = match machine_join::platform_origin(command.auth.platform.as_deref(), &env) {
        Ok(origin) => origin,
        Err(message) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}"),
                global.output,
                2,
            ));
        }
    };
    let platform = credential.and_then(|credential| {
        Platform::new(origin.clone(), credential, machine_join::LIST_TIMEOUT).ok()
    });
    let list = platform.as_ref().map(Platform::credentials);
    let found = list
        .as_ref()
        .and_then(|list| list.as_ref().ok())
        .and_then(|entries| machine_join::find(entries, key).ok());
    // Not a joined machine: the app's ssh Check Machine, as before (an ssh host is no joined
    // machine on any platform, signed in or not). A pasted secret is never handed on.
    if found.is_none()
        && plain_name(key)
        && let Some(code) = super::run_app_action_fallback(args)
    {
        // Not a joined machine: the app's ssh Check Machine, as before. When the joined list
        // could not be read, say so: the checks above did not run.
        if let Some(note) = fallback_note(global.output, key, list.as_ref()) {
            eprintln!("{note}");
        }
        return Some(code);
    }
    let mesh = match (&platform, &found) {
        (Some(platform), Some(machine)) => {
            machine.mesh_peer_id.as_deref().map(|peer| platform.mesh_daemons(peer))
        }
        _ => None,
    };
    let checked = remote_steps(&origin, key, list, mesh, machine_join::now_ms());
    let name = match &found {
        Some(machine) => machine.name.as_str(),
        None if plain_name(key) => key.as_str(),
        None => "NAME",
    };
    let (text, ok) = doctor::render(name, "joined machine", &checked, print);
    let _ = stdout.write_all(text.as_bytes());
    let _ = stdout.flush();
    Some(i32::from(!ok))
}

/// `machine doctor …` as this module's command; `None` for another verb, or
/// for a flag only the app's Check Machine takes.
pub(super) fn parse(args: &[String]) -> Option<Result<Command, String>> {
    let [scope, verb, rest @ ..] = args else { return None };
    if scope != "machine" || verb != "doctor" {
        return None;
    }
    parse_rest(rest).transpose()
}

fn parse_rest(rest: &[String]) -> Result<Option<Command>, String> {
    let mut command = Command { machine: None, fix: false, auth: machine_join::Auth::default() };
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let takes_value = matches!(flag, "--platform" | "--cloud-token-file");
        let value = match (takes_value, inline) {
            (true, Some(value)) => Some(value),
            (true, None) => {
                Some(words.next().cloned().ok_or_else(|| format!("{flag} needs a value"))?)
            }
            (false, Some(_)) => return Ok(None),
            (false, None) => None,
        };
        match flag {
            "--fix" => command.fix = true,
            "--cloud-token-stdin" => command.auth.token_stdin = true,
            "--platform" => command.auth.platform = value,
            "--cloud-token-file" => command.auth.token_file = value.map(Into::into),
            _ if !word.starts_with('-') && command.machine.is_none() => {
                command.machine = Some(word.clone());
            }
            // Another flag or word is the app's Check Machine's.
            _ => return Ok(None),
        }
    }
    Ok(Some(command))
}

/// The minting end's checklist for `key`, from the platform's credentials
/// list (`None`: no sign-in) and, for a listed machine with a mesh id, the
/// mesh's daemon ids.
pub(super) fn remote_steps(
    origin: &str,
    key: &str,
    list: Option<Result<Vec<Value>, CallError>>,
    mesh: Option<Result<Vec<String>, CallError>>,
    now: u64,
) -> Vec<JoinStep> {
    let skip = |step: &'static str, why: &str| JoinStep::new(step, StepState::Skip, why);
    let mut steps = Vec::new();
    let list = match list {
        None => {
            steps.push(JoinStep::fail(
                "signed-in",
                "no cmux sign-in for your team",
                "Sign in in cmux, or pass --cloud-token-file",
            ));
            steps.push(skip("platform", "not signed in"));
            Err(())
        }
        Some(Err(CallError::Status { status: 401, .. })) => {
            steps.push(JoinStep::fail(
                "signed-in",
                "the cmux platform did not accept your sign-in",
                "Sign in in cmux, or pass --cloud-token-file",
            ));
            steps.push(skip("platform", "not signed in"));
            Err(())
        }
        Some(result) => {
            steps.push(JoinStep::new("signed-in", StepState::Ok, "signed in"));
            match result {
                Ok(entries) => {
                    steps.push(JoinStep::new(
                        "platform",
                        StepState::Ok,
                        format!("{origin} answers"),
                    ));
                    Ok(entries)
                }
                Err(CallError::Status { status: 404, .. }) => {
                    steps.push(JoinStep::fail(
                        "platform",
                        format!("joining is off on {origin}"),
                        format!("Point at development: --platform {}", machine_join::DEV_ORIGIN),
                    ));
                    Err(())
                }
                Err(error) => {
                    let why = match error {
                        CallError::Status { status, code } => {
                            format!("{status} {code}").trim_end().to_owned()
                        }
                        CallError::Unreachable(_) => "no answer".to_owned(),
                        CallError::Unreadable(status) => format!("{status}, unreadable"),
                    };
                    steps.push(JoinStep::fail(
                        "platform",
                        format!("{origin} did not list the machines ({why})"),
                        "Check this computer's network, or pass --platform URL",
                    ));
                    Err(())
                }
            }
        }
    };
    let Ok(entries) = list else {
        for step in ["listed", "heartbeat", "mesh"] {
            steps.push(skip(step, "the platform's list was not read"));
        }
        return steps;
    };
    let found = machine_join::find(&entries, key);
    // The name a fix prints: the listed machine's, else what was typed when it is a plain
    // name (never a pasted secret or terminal controls).
    let name = match &found {
        Ok(machine) => machine.name.clone(),
        Err(_) if plain_name(key) => key.to_owned(),
        Err(_) => "NAME".to_owned(),
    };
    let on_it = format!("Run cmux machine doctor (or acpmux host doctor --here) on {name}");
    let machine = match found {
        Ok(machine) if !machine.revoked => machine,
        found => {
            let detail = match found {
                Ok(machine) => format!("{} is revoked", machine.name),
                Err(failure) => failure.message,
            };
            steps.push(JoinStep::fail(
                "listed",
                detail,
                format!("Not joined (or revoked): cmux machine add --name {name}"),
            ));
            steps.push(skip("heartbeat", "not listed"));
            steps.push(skip("mesh", "not listed"));
            return steps;
        }
    };
    steps.push(JoinStep::new("listed", StepState::Ok, format!("listed as {}", machine.machine_id)));
    steps.push(match machine.last_heartbeat_ms {
        Some(at) if now.saturating_sub(at) < machine_join::ONLINE_WITHIN_MS => JoinStep::new(
            "heartbeat",
            StepState::Ok,
            format!("last heartbeat {} ago", doctor::age_words(now.saturating_sub(at))),
        ),
        Some(at) => JoinStep::fail(
            "heartbeat",
            format!("last heartbeat {} ago", doctor::age_words(now.saturating_sub(at))),
            on_it.clone(),
        ),
        None => JoinStep::fail("heartbeat", "no heartbeat yet", on_it.clone()),
    });
    let peer = machine.mesh_peer_id.as_deref();
    steps.push(match (peer, mesh) {
        (None, _) | (_, None) => skip("mesh", "the platform does not name its mesh id"),
        (Some(peer), Some(Ok(daemons))) if daemons.iter().any(|d| d == peer) => {
            JoinStep::new("mesh", StepState::Ok, format!("the mesh lists daemon {peer}"))
        }
        (Some(peer), Some(Ok(_))) => {
            JoinStep::fail("mesh", format!("the mesh does not list daemon {peer}"), on_it)
        }
        (Some(_), Some(Err(CallError::Status { status: 404, .. }))) => {
            JoinStep::fail("mesh", format!("the mesh is off on {origin}"), on_it)
        }
        (Some(_), Some(Err(_))) => {
            JoinStep::fail("mesh", "the mesh's sessions could not be read", on_it)
        }
    });
    steps
}

/// The stderr line after the ssh check ran for `key` because the joined list was not read;
/// `None` when it was read, or in quiet mode, which prints nothing.
fn fallback_note(
    output: OutputMode,
    key: &str,
    list: Option<&Result<Vec<Value>, CallError>>,
) -> Option<String> {
    if output == OutputMode::Quiet {
        return None;
    }
    let why = unread(list)?;
    Some(format!(
        "cmux machine doctor: {key} was checked as an ssh machine; joined machines were not \
         checked ({why})"
    ))
}

/// Why the joined list was not read: `None` when it was.
fn unread(list: Option<&Result<Vec<Value>, CallError>>) -> Option<String> {
    match list {
        None => Some("not signed in: sign in in cmux, or pass --cloud-token-file".to_owned()),
        Some(Ok(_)) => None,
        Some(Err(CallError::Status { status: 404, .. })) => {
            Some("joining isn't available on this server yet (it answered 404)".to_owned())
        }
        Some(Err(CallError::Status { status, .. } | CallError::Unreadable(status))) => {
            Some(format!("the platform answered {status}"))
        }
        Some(Err(CallError::Unreachable(_))) => Some("the platform did not answer".to_owned()),
    }
}

/// A machine name safe to print in a fix or hand to the app: letters, digits, `.`, `-`, `_`,
/// `@` and `:` (an ssh destination), and no secret prefix.
fn plain_name(text: &str) -> bool {
    (1..=253).contains(&text.len())
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b'@' | b':'))
        && !text.contains("cmj_")
        && !text.contains("cmm_")
}

#[cfg(test)]
mod tests;
