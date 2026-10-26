//! Access to a VM's guest: `ssh`, client `session create|list|revoke`, and
//! `terminal list|close`.
//!
//! `ssh VM` mints a client session for one Linux user, runs the system `ssh`
//! against the session's SSH host and login, and revokes the session when
//! `ssh` exits. The session token is the SSH password: it reaches `ssh` only
//! through this binary acting as its askpass helper (an environment variable
//! of the child), never through the command line, stdout or stderr.

use std::ffi::OsString;
use std::io::Write;
use std::path::Path;

use clap::{Args, Subcommand};
use cmux_vm_client::raw::{Client, types};
use serde_json::{Value, json};

use crate::error::{self, CliError};
use crate::output::Printer;
use crate::prompt::Prompt;
use crate::{Destroy, call, confirm, fetch_body, request_body};

/// Set on the `ssh` child: the token this binary prints when `ssh` runs it as
/// its askpass helper.
pub(crate) const ASKPASS_TOKEN_ENV: &str = "CMUX_VM_ASKPASS_TOKEN";

#[derive(Args, Debug)]
pub(crate) struct SshArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Guest Linux user [default: the VM's work user]
    #[arg(long, value_name = "USER")]
    linux_user: Option<String>,
    /// Keep the client session after ssh exits (revoke it later with `session revoke`)
    #[arg(long)]
    keep_session: bool,
    /// Command to run instead of a login shell (put it after `--`)
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    command: Vec<String>,
}

#[derive(Subcommand, Debug)]
pub(crate) enum SessionCommand {
    /// Mint a client session (SSH login and token) for one Linux user; the token is printed only with --json
    Create(SessionCreateArgs),
    /// List a VM's live client sessions (never their tokens)
    List(VmOnly),
    /// Revoke a client session; its token stops working (asks to type the session id, or needs --yes)
    Revoke(SessionRevokeArgs),
}

#[derive(Args, Debug)]
pub(crate) struct SessionCreateArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Guest Linux user [default: the VM's work user]
    #[arg(long, value_name = "USER")]
    linux_user: Option<String>,
}

#[derive(Args, Debug)]
pub(crate) struct VmOnly {
    /// VM id (vm_...)
    vm_id: String,
}

#[derive(Args, Debug)]
pub(crate) struct SessionRevokeArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Client session id (vcs_...)
    session_id: String,
    /// Revoke without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

#[derive(Subcommand, Debug)]
pub(crate) enum TerminalCommand {
    /// List a VM's terminal sessions, running and recently exited
    List(TerminalListArgs),
    /// Kill a terminal session and remove it (asks to type the terminal id, or needs --yes)
    Close(TerminalCloseArgs),
}

#[derive(Args, Debug)]
pub(crate) struct TerminalListArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Only this guest user's terminals
    #[arg(long, value_name = "USER")]
    user: Option<String>,
}

#[derive(Args, Debug)]
pub(crate) struct TerminalCloseArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Terminal session id or name
    terminal: String,
    /// The guest user that owns the terminal
    #[arg(long, value_name = "USER")]
    user: Option<String>,
    /// Close without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
}

/// The `ssh` invocation for one client session.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SshPlan {
    pub args: Vec<String>,
    pub env: Vec<(String, OsString)>,
}

/// Builds the `ssh` arguments and environment from a session. The token goes
/// only into the environment, read back by `askpass` below.
pub(crate) fn ssh_plan(host: &str, login: &str, token: &str, askpass: &Path, command: &[String]) -> SshPlan {
    let mut args: Vec<String> = [
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "PreferredAuthentications=password,keyboard-interactive",
        "-o",
        "NumberOfPasswordPrompts=1",
        "-l",
        login,
        "--",
        host,
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    args.extend(command.iter().cloned());
    SshPlan {
        args,
        env: vec![
            ("SSH_ASKPASS".to_owned(), askpass.as_os_str().to_owned()),
            ("SSH_ASKPASS_REQUIRE".to_owned(), OsString::from("force")),
            (ASKPASS_TOKEN_ENV.to_owned(), OsString::from(token)),
        ],
    }
}

/// When `ssh` runs this binary as its askpass helper, answers a password
/// prompt with the session token and refuses anything else (a host key
/// question is not a password). Returns the exit code, or `None` when this is
/// not an askpass run.
pub fn askpass(
    env: &dyn Fn(&str) -> Option<String>,
    prompt: Option<&str>,
    stdout: &mut dyn Write,
) -> Option<i32> {
    let token = env(ASKPASS_TOKEN_ENV)?;
    if env("SSH_ASKPASS_REQUIRE").as_deref() != Some("force") {
        return None;
    }
    let is_password = prompt.is_some_and(|p| p.to_ascii_lowercase().contains("password"));
    if !is_password {
        return Some(1);
    }
    match writeln!(stdout, "{token}") {
        Ok(()) => Some(0),
        Err(_) => Some(1),
    }
}

pub(crate) async fn ssh(
    client: &Client,
    args: SshArgs,
    json: bool,
    stderr: &mut dyn Write,
) -> Result<(), CliError> {
    if json {
        return Err(CliError::usage(
            "ssh is interactive and prints no JSON; use `session create VM --json` for the connection details",
        ));
    }
    let id = crate::files::vm_id(&args.vm_id)?;
    let body: types::CreateClientSessionRequest =
        request_body(json!({ "linuxUser": args.linux_user }))?;
    let session = fetch_body(client.agents_create_client_session(id.as_str(), None, &body)).await?;
    let session: Value = serde_json::from_slice(&session)
        .map_err(|_| CliError::unexpected("the cmux VM API sent an unreadable client session"))?;
    let field = |pointer: &str| session.pointer(pointer).and_then(Value::as_str).map(str::to_owned);
    let (Some(session_id), Some(token), Some(host), Some(login)) = (
        field("/id"),
        field("/token"),
        field("/ssh/host"),
        field("/ssh/user"),
    ) else {
        return Err(CliError::unexpected(
            "the client session has no SSH login; nothing to connect to",
        ));
    };
    let askpass_program = std::env::current_exe()
        .map_err(|e| CliError::unexpected(format!("cannot locate cmux-vm for ssh: {e}")))?;
    let plan = ssh_plan(&host, &login, &token, &askpass_program, &args.command);
    let status = std::process::Command::new("ssh")
        .args(&plan.args)
        .envs(plan.env.iter().map(|(k, v)| (k.as_str(), v.as_os_str())))
        .status();
    if !args.keep_session {
        let revoked = call(client.agents_revoke_client_session(id.as_str(), &session_id, None)).await;
        if revoked.is_err() {
            error::report_warning(
                &format!(
                    "could not revoke client session {session_id}; run `cmux-vm session revoke {} {session_id} --yes`",
                    id.as_str()
                ),
                false,
                stderr,
            );
        }
    }
    match status {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => Err(CliError::child_exit(
            status.code().unwrap_or(1),
            format!("ssh exited with {status}"),
        )),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(CliError::unexpected(
            "the ssh client was not found; install OpenSSH and put `ssh` on PATH",
        )),
        Err(e) => Err(CliError::unexpected(format!("could not start ssh: {e}"))),
    }
}

pub(crate) async fn session(
    client: &Client,
    command: SessionCommand,
    prompt: &mut dyn Prompt,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        SessionCommand::Create(args) => {
            let id = crate::files::vm_id(&args.vm_id)?;
            let body: types::CreateClientSessionRequest =
                request_body(json!({ "linuxUser": args.linux_user }))?;
            let session =
                fetch_body(client.agents_create_client_session(id.as_str(), None, &body)).await?;
            if out.is_json() {
                return out.raw_json(&session);
            }
            let value: Value = serde_json::from_slice(&session)
                .map_err(|_| CliError::unexpected("the cmux VM API sent an unreadable client session"))?;
            // Human output never shows the token or the SSH login it pairs with.
            for (label, pointer) in [
                ("id", "/id"),
                ("vm", "/vmId"),
                ("linux user", "/linuxUser"),
                ("created", "/createdAt"),
            ] {
                let text = value.pointer(pointer).and_then(Value::as_str).unwrap_or("unknown");
                out.line(&format!("{label:<11}{}", text.escape_debug()))?;
            }
            out.line("The token is shown only with --json. Connect with `cmux-vm ssh VM`.")
        }
        SessionCommand::List(VmOnly { vm_id }) => {
            let id = crate::files::vm_id(&vm_id)?;
            let body = fetch_body(client.agents_list_client_sessions(id.as_str(), None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let list: Value = serde_json::from_slice(&body)
                .map_err(|_| CliError::unexpected("the cmux VM API sent an unreadable session list"))?;
            let sessions = list["sessions"].as_array().cloned().unwrap_or_default();
            if sessions.is_empty() {
                return out.line("no client sessions");
            }
            out.line(&format!("{:<31} {:<16} CREATED", "ID", "LINUX_USER"))?;
            for s in sessions {
                out.line(&format!(
                    "{:<31} {:<16} {}",
                    s["id"].as_str().unwrap_or("?"),
                    s["linuxUser"].as_str().unwrap_or("?").escape_debug(),
                    s["createdAt"].as_str().unwrap_or("?"),
                ))?;
            }
            Ok(())
        }
        SessionCommand::Revoke(args) => {
            let id = crate::files::vm_id(&args.vm_id)?;
            if !args.yes {
                confirm(prompt, Destroy::RevokeSession, &args.session_id)?;
            }
            call(client.agents_revoke_client_session(id.as_str(), &args.session_id, None)).await?;
            out.revoked(&args.session_id)
        }
    }
}

pub(crate) async fn terminal(
    client: &Client,
    command: TerminalCommand,
    prompt: &mut dyn Prompt,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    match command {
        TerminalCommand::List(args) => {
            let id = crate::files::vm_id(&args.vm_id)?;
            let user = crate::parse_opt::<types::TerminalsListTerminalsUser>("--user", args.user)?;
            let body =
                fetch_body(client.terminals_list_terminals(id.as_str(), user.as_ref(), None)).await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let list: Value = serde_json::from_slice(&body)
                .map_err(|_| CliError::unexpected("the cmux VM API sent an unreadable terminal list"))?;
            let items = list["items"].as_array().cloned().unwrap_or_default();
            if items.is_empty() {
                return out.line("no terminals");
            }
            out.line(&format!("{:<8} {:<9} {:<12} {:<9} NAME", "ID", "STATE", "USER", "SIZE"))?;
            for t in items {
                let id = t["sessionId"].to_string();
                let size = format!("{}x{}", t["cols"], t["rows"]);
                out.line(&format!(
                    "{id:<8} {:<9} {:<12} {size:<9} {}",
                    t["state"].as_str().unwrap_or("?"),
                    t["user"].as_str().unwrap_or("-").escape_debug(),
                    t["name"].as_str().unwrap_or("").escape_debug(),
                ))?;
            }
            Ok(())
        }
        TerminalCommand::Close(args) => {
            let id = crate::files::vm_id(&args.vm_id)?;
            let user = crate::parse_opt::<types::TerminalsCloseTerminalUser>("--user", args.user)?;
            if !args.yes {
                confirm(prompt, Destroy::CloseTerminal, &args.terminal)?;
            }
            let body = fetch_body(client.terminals_close_terminal(
                id.as_str(),
                &args.terminal,
                user.as_ref(),
                None,
            ))
            .await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let closed: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            let code = match &closed["exitCode"] {
                Value::Null => "none".to_owned(),
                other => other.to_string(),
            };
            out.line(&format!("closed terminal {} (exit code {code})", args.terminal.escape_debug()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_token_reaches_ssh_only_through_the_environment() {
        let plan = ssh_plan(
            "ssh.example",
            "host+dev",
            "secret-token",
            Path::new("/bin/cmux-vm"),
            &["uname".to_owned(), "-a".to_owned()],
        );
        assert!(plan.args.iter().all(|a| !a.contains("secret-token")));
        let tail = &plan.args[plan.args.len() - 5..];
        assert_eq!(tail, ["host+dev", "--", "ssh.example", "uname", "-a"]);
        assert!(plan.args.contains(&"StrictHostKeyChecking=accept-new".to_owned()));
        assert!(plan.env.contains(&(ASKPASS_TOKEN_ENV.to_owned(), OsString::from("secret-token"))));
        assert!(plan.env.contains(&("SSH_ASKPASS_REQUIRE".to_owned(), OsString::from("force"))));
        assert!(plan.env.contains(&("SSH_ASKPASS".to_owned(), OsString::from("/bin/cmux-vm"))));
    }

    #[test]
    fn askpass_answers_only_password_prompts_of_an_ssh_child() {
        let child = |name: &str| match name {
            ASKPASS_TOKEN_ENV => Some("tok".to_owned()),
            "SSH_ASKPASS_REQUIRE" => Some("force".to_owned()),
            _ => None,
        };
        let mut out = Vec::new();
        assert_eq!(askpass(&child, Some("host+dev@ssh.example's password: "), &mut out), Some(0));
        assert_eq!(out, b"tok\n");
        let mut out = Vec::new();
        assert_eq!(
            askpass(&child, Some("Are you sure you want to continue connecting (yes/no)?"), &mut out),
            Some(1)
        );
        assert!(out.is_empty());
        let plain = |_: &str| None;
        assert_eq!(askpass(&plain, Some("password"), &mut Vec::new()), None);
        let no_force = |name: &str| (name == ASKPASS_TOKEN_ENV).then(|| "tok".to_owned());
        assert_eq!(askpass(&no_force, Some("password"), &mut Vec::new()), None);
    }
}
