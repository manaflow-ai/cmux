//! A local chat's Seatbelt boundary (`local_sandbox.rs`) carried across daemon delegation
//! (cmuxterm-hq#32166).
//!
//! The agent runs under `sandbox-exec`, but the daemon does not: whatever the daemon executes on
//! the agent's behalf (a background task, a workflow's task) would run with the daemon's full
//! authority. The profile deliberately does not grant the agent direct access to the daemon's
//! unix socket. The daemon instead derives a chat's boundary itself, from the launch it would
//! make for that chat now (the same builder, `agent::harness_command_ready`, with the final env
//! the other lane hardened), never from anything the agent sends, and runs what it executes for
//! the chat inside that boundary.
//!
//! Only the person (`hub/person.rs`: a connection that proved the app's per-launch key) starts a
//! task outside it; the chat's own agent, its subagents and the workflows it starts never do.

use std::path::Path;

/// The `sandbox-exec` arguments up to the program (`-p PROFILE` then `-D KEY=VALUE` pairs) of a
/// launch `program args...`, or `None` when the launch is not wrapped in the local sandbox.
pub(crate) fn launch_prefix(program: &Path, args: &[String]) -> Option<Vec<String>> {
    if program != Path::new(crate::local_sandbox::SANDBOX_EXEC) {
        return None;
    }
    let mut it = args.iter();
    let (Some(flag), Some(profile)) = (it.next(), it.next()) else { return None };
    if flag != "-p" {
        return None;
    }
    let mut out = vec![flag.clone(), profile.clone()];
    let mut rest = it.as_slice();
    while let [d, param, tail @ ..] = rest {
        if d != "-D" {
            break;
        }
        out.push(d.clone());
        out.push(param.clone());
        rest = tail;
    }
    // A wrapped launch always names the program after its parameters.
    if rest.is_empty() {
        return None;
    }
    Some(out)
}

/// The boundary a std `Command` (a built harness launch) runs in.
pub(crate) fn command_prefix(cmd: &std::process::Command) -> Option<Vec<String>> {
    let args: Vec<String> = cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect();
    launch_prefix(Path::new(cmd.get_program()), &args)
}

/// `program` and its arguments for running `shell -c command` inside `sandbox` (when set).
pub(crate) fn wrap_shell(
    sandbox: Option<&[String]>,
    shell: &str,
    command: &str,
) -> (String, Vec<String>) {
    let inner = [shell.to_owned(), "-c".to_owned(), command.to_owned()];
    match sandbox {
        Some(prefix) => {
            let mut args = prefix.to_vec();
            args.extend(inner);
            (crate::local_sandbox::SANDBOX_EXEC.to_owned(), args)
        }
        None => (inner[0].clone(), inner[1..].to_vec()),
    }
}

#[cfg(test)]
#[path = "sandbox_authority_tests.rs"]
mod tests;
