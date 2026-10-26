//! Access to a VM's guest: `ssh`, client `session …` (also the
//! `identity <subcommand>` group: a cmux identity is one client session, one
//! VM and one Linux user), and `terminal list|close`.
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

/// Client sessions. `identity <subcommand>` is the same group under the
/// provider's name: one session is one VM plus one Linux user, so its
/// "permissions" are the session itself (`get`).
#[derive(Subcommand, Debug)]
pub(crate) enum SessionCommand {
    /// Mint a client session (SSH login and token) for one Linux user; the token is printed only with --json
    Create(SessionCreateArgs),
    /// List a VM's live client sessions, or with --all every session the key reaches (never tokens)
    List(SessionListArgs),
    /// Show one client session: its VM and its one Linux user
    #[command(visible_alias = "permissions")]
    Get(SessionArgs),
    /// Replace the session's Linux user (a session grants exactly one)
    SetUser(SessionSetUserArgs),
    /// List a session's access tokens (ids only, never the secrets)
    Tokens(SessionArgs),
    /// Mint another access token for a session; the token is printed only with --json
    TokenCreate(SessionArgs),
    /// Revoke one access token of a session (asks to type the token id, or needs --yes)
    TokenRevoke(TokenRevokeArgs),
    /// Revoke a client session; its tokens stop working (asks to type the session id, or needs --yes)
    #[command(visible_alias = "delete")]
    Revoke(SessionRevokeArgs),
}

#[derive(Args, Debug)]
pub(crate) struct SessionListArgs {
    /// VM id (vm_...); omit with --all
    #[arg(required_unless_present = "all", conflicts_with = "all")]
    vm_id: Option<String>,
    /// Every live client session on the VMs this key reaches, across the team
    #[arg(long)]
    all: bool,
    /// Page size with --all (1-200)
    #[arg(long, requires = "all", value_parser = clap::value_parser!(u32).range(1..=200))]
    limit: Option<u32>,
    /// Continue an --all listing from a previous page's next cursor
    #[arg(long, requires = "all")]
    cursor: Option<String>,
}

#[derive(Args, Debug)]
pub(crate) struct SessionArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Client session id (vcs_...)
    session_id: String,
}

#[derive(Args, Debug)]
pub(crate) struct SessionSetUserArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Client session id (vcs_...)
    session_id: String,
    /// The guest Linux user the session grants from now on
    linux_user: String,
}

#[derive(Args, Debug)]
pub(crate) struct TokenRevokeArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// Client session id (vcs_...)
    session_id: String,
    /// Access token id (vct_...)
    token_id: String,
    /// Revoke without asking; required when stdin is not a terminal
    #[arg(long)]
    yes: bool,
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
pub(crate) fn ssh_plan(
    host: &str,
    login: &str,
    token: &str,
    askpass: &Path,
    command: &[String],
) -> SshPlan {
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

/// The environment variable that names the ssh client to run instead of
/// `ssh` from PATH (an OpenSSH-compatible program).
pub(crate) const SSH_PROGRAM_ENV: &str = "CMUX_VM_SSH";

/// How long `ssh` may take to exit after a SIGHUP or SIGTERM revoked its
/// session before it is killed.
const SSH_EXIT_GRACE: std::time::Duration = std::time::Duration::from_secs(2);

/// How long the revoke at the end of `ssh` may take. Once ssh ran, SIGINT and
/// SIGTERM no longer end this process by default, so the revoke must not wait
/// for the full API timeout; past this bound the exact revoke command is
/// printed instead.
pub(crate) const REVOKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

pub(crate) async fn ssh(
    client: &Client,
    args: SshArgs,
    ssh_program: &str,
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
    let field = |pointer: &str| {
        session
            .pointer(pointer)
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let Some(session_id) = field("/id") else {
        return Err(CliError::unexpected(
            "the cmux VM API sent a client session without an id",
        ));
    };
    // From here on the session is revoked on every way out: the normal end,
    // an error, a signal, or (best effort) an unwinding panic.
    let mut guard = SessionGuard::new(client, id.as_str(), &session_id, args.keep_session);
    let result = connect(&session, &args, ssh_program, &mut guard).await;
    // A second SIGINT, SIGTERM or SIGHUP while the final revoke runs abandons
    // it at once (it is bounded by REVOKE_TIMEOUT either way).
    let revoked = tokio::select! {
        revoked = guard.revoke() => revoked,
        () = interrupted() => {
            guard.abandon();
            false
        }
    };
    if !revoked {
        error::report_warning(
            &format!(
                "could not revoke client session {session_id}; run `cmux-vm session revoke {} {session_id} --yes`",
                id.as_str()
            ),
            false,
            stderr,
        );
    }
    result
}

/// Runs `ssh` for one session and maps how it ended.
async fn connect(
    session: &Value,
    args: &SshArgs,
    ssh_program: &str,
    guard: &mut SessionGuard<'_>,
) -> Result<(), CliError> {
    let field = |pointer: &str| {
        session
            .pointer(pointer)
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let (Some(token), Some(host), Some(login)) =
        (field("/token"), field("/ssh/host"), field("/ssh/user"))
    else {
        return Err(CliError::unexpected(
            "the client session has no SSH login; nothing to connect to",
        ));
    };
    let askpass_program = std::env::current_exe()
        .map_err(|e| CliError::unexpected(format!("cannot locate cmux-vm for ssh: {e}")))?;
    let plan = ssh_plan(&host, &login, &token, &askpass_program, &args.command);
    // Listen before ssh starts: from now on SIGINT and SIGQUIT no longer end
    // this process (ssh gets them from the terminal and decides), and SIGHUP
    // or SIGTERM end it only after the session is revoked.
    let signals = ParentSignals::listen()?;
    let child = tokio::process::Command::new(ssh_program)
        .args(&plan.args)
        .envs(plan.env.iter().map(|(k, v)| (k.as_str(), v.as_os_str())))
        .spawn();
    let mut child = match child {
        Ok(child) => child,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(CliError::unexpected(
                "the ssh client was not found; install OpenSSH and put `ssh` on PATH",
            ));
        }
        Err(e) => return Err(CliError::unexpected(format!("could not start ssh: {e}"))),
    };
    let end = supervise(child.wait(), signals.terminate()).await;
    match end {
        SshEnd::Exited(Ok(status)) if status.success() => Ok(()),
        SshEnd::Exited(Ok(status)) => Err(CliError::child_exit(
            status.code().unwrap_or(1),
            format!("ssh exited with {status}"),
        )),
        SshEnd::Exited(Err(e)) => Err(CliError::unexpected(format!("could not wait for ssh: {e}"))),
        SshEnd::Signalled(signal) => {
            // Revoke first (it ends the connection), give ssh a moment to
            // restore the terminal, then stop it.
            let revoked = guard.revoke().await;
            if tokio::time::timeout(SSH_EXIT_GRACE, child.wait())
                .await
                .is_err()
            {
                let _ = child.kill().await;
            }
            let outcome = if revoked {
                "the client session was revoked"
            } else {
                "the client session could not be revoked"
            };
            Err(CliError::child_exit(
                128 + signal,
                format!("cmux-vm ssh was ended by signal {signal}; {outcome}"),
            ))
        }
    }
}

/// Resolves on the next SIGINT, SIGTERM or SIGHUP (never when listening fails).
async fn interrupted() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let (Ok(mut interrupt), Ok(mut terminate), Ok(mut hangup)) = (
            signal(SignalKind::interrupt()),
            signal(SignalKind::terminate()),
            signal(SignalKind::hangup()),
        ) else {
            return std::future::pending().await;
        };
        tokio::select! {
            _ = interrupt.recv() => {}
            _ = terminate.recv() => {}
            _ = hangup.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

/// How an `ssh` run ended: ssh exited, or this process was told to stop.
#[derive(Debug)]
pub(crate) enum SshEnd {
    Exited(std::io::Result<std::process::ExitStatus>),
    /// SIGHUP or SIGTERM (the signal number) arrived first.
    Signalled(i32),
}

/// Waits for ssh to exit or for a terminating signal, whichever comes first.
pub(crate) async fn supervise(
    exited: impl std::future::Future<Output = std::io::Result<std::process::ExitStatus>>,
    terminate: impl std::future::Future<Output = i32>,
) -> SshEnd {
    tokio::select! {
        status = exited => SshEnd::Exited(status),
        signal = terminate => SshEnd::Signalled(signal),
    }
}

/// The parent's signal handling while ssh runs. Registering a listener
/// replaces the default action, so SIGINT and SIGQUIT (listened to and never
/// acted on) no longer end this process; the terminal still delivers them to
/// ssh, which shares its process group. SIGHUP and SIGTERM end the wait.
struct ParentSignals {
    #[cfg(unix)]
    _interrupt: tokio::signal::unix::Signal,
    #[cfg(unix)]
    _quit: tokio::signal::unix::Signal,
    #[cfg(unix)]
    hangup: tokio::signal::unix::Signal,
    #[cfg(unix)]
    terminate: tokio::signal::unix::Signal,
}

impl ParentSignals {
    fn listen() -> Result<Self, CliError> {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{SignalKind, signal};
            let listen = |kind| {
                signal(kind).map_err(|e| {
                    CliError::unexpected(format!("could not set up signal handling for ssh: {e}"))
                })
            };
            Ok(Self {
                _interrupt: listen(SignalKind::interrupt())?,
                _quit: listen(SignalKind::quit())?,
                hangup: listen(SignalKind::hangup())?,
                terminate: listen(SignalKind::terminate())?,
            })
        }
        #[cfg(not(unix))]
        {
            Ok(Self {})
        }
    }

    /// Resolves with the signal number of the first SIGHUP or SIGTERM.
    async fn terminate(mut self) -> i32 {
        #[cfg(unix)]
        {
            const SIGHUP: i32 = 1;
            const SIGTERM: i32 = 15;
            tokio::select! {
                _ = self.hangup.recv() => SIGHUP,
                _ = self.terminate.recv() => SIGTERM,
            }
        }
        #[cfg(not(unix))]
        {
            // Ctrl-C reaches ssh through the console; nothing ends the wait.
            std::future::pending().await
        }
    }
}

/// Revokes a client session when its `ssh` run ends. [`SessionGuard::revoke`]
/// is the normal path; if the guard is dropped without it (an unwinding
/// panic), `Drop` revokes it synchronously on the multi-threaded runtime.
pub(crate) struct SessionGuard<'a> {
    client: &'a Client,
    vm_id: String,
    session_id: String,
    /// `Some(true)` once revoked or kept (`--keep-session`), `Some(false)`
    /// once a revoke failed; `None` while the session is live.
    outcome: Option<bool>,
    /// The bound on one revoke request.
    timeout: std::time::Duration,
}

impl<'a> SessionGuard<'a> {
    pub(crate) fn new(client: &'a Client, vm_id: &str, session_id: &str, keep: bool) -> Self {
        Self {
            client,
            vm_id: vm_id.to_owned(),
            session_id: session_id.to_owned(),
            outcome: keep.then_some(true),
            timeout: REVOKE_TIMEOUT,
        }
    }

    /// The same guard with another bound on the revoke request.
    #[cfg(test)]
    pub(crate) fn with_timeout(mut self, timeout: std::time::Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Revokes the session once; later calls repeat the first answer. False
    /// when the revoke failed or took longer than the guard's timeout.
    pub(crate) async fn revoke(&mut self) -> bool {
        if let Some(outcome) = self.outcome {
            return outcome;
        }
        let request = call(self.client.agents_revoke_client_session(
            &self.vm_id,
            &self.session_id,
            None,
        ));
        let outcome = matches!(tokio::time::timeout(self.timeout, request).await, Ok(Ok(_)));
        self.outcome = Some(outcome);
        outcome
    }

    /// Gives up on revoking (the caller prints the revoke command), so `Drop`
    /// does not try again.
    pub(crate) fn abandon(&mut self) {
        if self.outcome.is_none() {
            self.outcome = Some(false);
        }
    }
}

impl Drop for SessionGuard<'_> {
    fn drop(&mut self) {
        if self.outcome.is_some() {
            return;
        }
        self.outcome = Some(false);
        let revoke = self
            .client
            .agents_revoke_client_session(&self.vm_id, &self.session_id, None);
        let revoked = match tokio::runtime::Handle::try_current() {
            Ok(handle) if handle.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread => {
                let timeout = self.timeout;
                tokio::task::block_in_place(|| {
                    handle.block_on(async {
                        matches!(tokio::time::timeout(timeout, revoke).await, Ok(Ok(_)))
                    })
                })
            }
            _ => false,
        };
        if !revoked {
            eprintln!(
                "cmux-vm: warning: could not revoke client session {}; run `cmux-vm session revoke {} {} --yes`",
                self.session_id, self.vm_id, self.session_id
            );
        }
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
            let value: Value = serde_json::from_slice(&session).map_err(|_| {
                CliError::unexpected("the cmux VM API sent an unreadable client session")
            })?;
            // Human output never shows the token or the SSH login it pairs with.
            for (label, pointer) in [
                ("id", "/id"),
                ("vm", "/vmId"),
                ("token id", "/tokenId"),
                ("linux user", "/linuxUser"),
                ("created", "/createdAt"),
            ] {
                let text = value
                    .pointer(pointer)
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                out.line(&format!("{label:<11}{}", text.escape_debug()))?;
            }
            out.line("The token is shown only with --json. Connect with `cmux-vm ssh VM`.")
        }
        SessionCommand::List(args) => {
            let body = match args.vm_id {
                Some(vm_id) => {
                    let id = crate::files::vm_id(&vm_id)?;
                    fetch_body(client.agents_list_client_sessions(id.as_str(), None)).await?
                }
                None => {
                    let cursor = crate::parse_opt::<
                        types::ClientSessionsListTenantClientSessionsCursor,
                    >("--cursor", args.cursor)?;
                    let limit = args.limit.map(|n| n.to_string());
                    fetch_body(client.client_sessions_list_tenant_client_sessions(
                        cursor.as_ref(),
                        limit.as_deref(),
                        None,
                    ))
                    .await?
                }
            };
            if out.is_json() {
                return out.raw_json(&body);
            }
            let list: Value = serde_json::from_slice(&body).map_err(|_| {
                CliError::unexpected("the cmux VM API sent an unreadable session list")
            })?;
            let sessions = list["sessions"].as_array().cloned().unwrap_or_default();
            if sessions.is_empty() {
                return out.line("no client sessions");
            }
            out.line(&format!(
                "{:<31} {:<30} {:<16} CREATED",
                "ID", "VM", "LINUX_USER"
            ))?;
            for s in sessions {
                out.line(&format!(
                    "{:<31} {:<30} {:<16} {}",
                    s["id"].as_str().unwrap_or("?"),
                    s["vmId"].as_str().unwrap_or("?"),
                    s["linuxUser"].as_str().unwrap_or("?").escape_debug(),
                    s["createdAt"].as_str().unwrap_or("?"),
                ))?;
            }
            if let Some(cursor) = list["nextCursor"].as_str() {
                out.line(&format!(
                    "more: cmux-vm session list --all --cursor {cursor}"
                ))?;
            }
            Ok(())
        }
        SessionCommand::Get(args) => {
            let (id, session) = session_ids(&args.vm_id, &args.session_id)?;
            let body =
                fetch_body(client.client_sessions_get_client_session(id.as_str(), session, None))
                    .await?;
            out.session_summary(&body)
        }
        SessionCommand::SetUser(args) => {
            let (id, session) = session_ids(&args.vm_id, &args.session_id)?;
            let body: types::SetClientSessionLinuxUserRequest =
                request_body(json!({ "linuxUser": args.linux_user }))?;
            let body = fetch_body(client.client_sessions_set_client_session_linux_user(
                id.as_str(),
                session,
                None,
                &body,
            ))
            .await?;
            out.session_summary(&body)
        }
        SessionCommand::Tokens(args) => {
            let (id, session) = session_ids(&args.vm_id, &args.session_id)?;
            let body = fetch_body(client.client_sessions_list_client_session_tokens(
                id.as_str(),
                session,
                None,
            ))
            .await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let list: Value = serde_json::from_slice(&body).map_err(|_| {
                CliError::unexpected("the cmux VM API sent an unreadable token list")
            })?;
            let tokens = list["tokens"].as_array().cloned().unwrap_or_default();
            if tokens.is_empty() {
                return out.line("no access tokens");
            }
            for token in tokens {
                out.line(token["id"].as_str().unwrap_or("?"))?;
            }
            Ok(())
        }
        SessionCommand::TokenCreate(args) => {
            let (id, session) = session_ids(&args.vm_id, &args.session_id)?;
            let body = fetch_body(client.client_sessions_create_client_session_token(
                id.as_str(),
                session,
                None,
            ))
            .await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let value: Value = serde_json::from_slice(&body).map_err(|_| {
                CliError::unexpected("the cmux VM API sent an unreadable access token")
            })?;
            // Human output never shows the token or the SSH login it pairs with.
            for (label, pointer) in [
                ("token id", "/id"),
                ("session", "/sessionId"),
                ("linux user", "/linuxUser"),
                ("created", "/createdAt"),
            ] {
                let text = value
                    .pointer(pointer)
                    .and_then(Value::as_str)
                    .unwrap_or("unknown");
                out.line(&format!("{label:<11}{}", text.escape_debug()))?;
            }
            out.line("The token is shown only with --json.")
        }
        SessionCommand::TokenRevoke(args) => {
            let (id, session) = session_ids(&args.vm_id, &args.session_id)?;
            let token = checked_id(&args.token_id, "vct_", "access token id")?;
            if !args.yes {
                confirm(prompt, Destroy::RevokeToken, token)?;
            }
            call(client.client_sessions_revoke_client_session_token(
                id.as_str(),
                session,
                token,
                None,
            ))
            .await?;
            out.revoked(token)
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
                fetch_body(client.terminals_list_terminals(id.as_str(), user.as_ref(), None))
                    .await?;
            if out.is_json() {
                return out.raw_json(&body);
            }
            let list: Value = serde_json::from_slice(&body).map_err(|_| {
                CliError::unexpected("the cmux VM API sent an unreadable terminal list")
            })?;
            let items = list["items"].as_array().cloned().unwrap_or_default();
            if items.is_empty() {
                return out.line("no terminals");
            }
            out.line(&format!(
                "{:<8} {:<9} {:<12} {:<9} NAME",
                "ID", "STATE", "USER", "SIZE"
            ))?;
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
            out.line(&format!(
                "closed terminal {} (exit code {code})",
                args.terminal.escape_debug()
            ))
        }
    }
}

/// A checked VM id and client session id.
fn session_ids<'a>(vm: &str, session: &'a str) -> Result<(types::VmId, &'a str), CliError> {
    Ok((
        crate::files::vm_id(vm)?,
        checked_id(session, "vcs_", "client session id")?,
    ))
}

/// `text` when it is `prefix` followed by 1-64 lowercase letters or digits.
pub(crate) fn checked_id<'a>(text: &'a str, prefix: &str, what: &str) -> Result<&'a str, CliError> {
    match text.strip_prefix(prefix) {
        Some(rest)
            if !rest.is_empty()
                && rest.len() <= 64
                && rest
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit()) =>
        {
            Ok(text)
        }
        _ => Err(CliError::usage(format!(
            "invalid {what} (expected {prefix}...)"
        ))),
    }
}

impl Printer<'_> {
    fn session_summary(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.is_json() {
            return self.raw_json(body);
        }
        let value: Value = serde_json::from_slice(body).map_err(|_| {
            CliError::unexpected("the cmux VM API sent an unreadable client session")
        })?;
        for (label, pointer) in [
            ("id", "/id"),
            ("vm", "/vmId"),
            ("linux user", "/linuxUser"),
            ("created", "/createdAt"),
        ] {
            let text = value
                .pointer(pointer)
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            self.line(&format!("{label:<11}{}", text.escape_debug()))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GUARD_VM: &str = "vm_0123456789abcdefghjkmnpqrs";
    const GUARD_SESSION: &str = "vcs_0123456789abcdefghjkmnpqrs";

    async fn revoke_server(delay: std::time::Duration) -> wiremock::MockServer {
        use wiremock::matchers::{method, path};
        let server = wiremock::MockServer::start().await;
        wiremock::Mock::given(method("DELETE"))
            .and(path(format!(
                "/v1/vms/{GUARD_VM}/client-sessions/{GUARD_SESSION}"
            )))
            .respond_with(wiremock::ResponseTemplate::new(204).set_delay(delay))
            .mount(&server)
            .await;
        server
    }

    #[tokio::test]
    async fn a_slow_revoke_gives_up_at_the_guard_timeout_and_is_not_retried() {
        let server = revoke_server(std::time::Duration::from_secs(30)).await;
        let client =
            cmux_vm_client::authenticated_raw_client(&server.uri(), "cmuxvm_sk_test", None, "test")
                .unwrap();
        let mut guard = SessionGuard::new(&client, GUARD_VM, GUARD_SESSION, false)
            .with_timeout(std::time::Duration::from_millis(200));
        let started = std::time::Instant::now();
        assert!(!guard.revoke().await);
        assert!(
            started.elapsed() < std::time::Duration::from_secs(5),
            "{:?}",
            started.elapsed()
        );
        // The answer is remembered: a second call (or Drop) sends nothing more.
        assert!(!guard.revoke().await);
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
        drop(guard);
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn a_prompt_revoke_within_the_timeout_succeeds() {
        let server = revoke_server(std::time::Duration::ZERO).await;
        let client =
            cmux_vm_client::authenticated_raw_client(&server.uri(), "cmuxvm_sk_test", None, "test")
                .unwrap();
        let mut guard = SessionGuard::new(&client, GUARD_VM, GUARD_SESSION, false);
        assert_eq!(guard.timeout, REVOKE_TIMEOUT);
        assert!(guard.revoke().await);
    }

    #[test]
    fn ids_need_their_prefix_and_a_plain_suffix() {
        assert!(checked_id("vcs_abc123", "vcs_", "session").is_ok());
        assert!(checked_id("vcs_", "vcs_", "session").is_err());
        assert!(checked_id("vct_abc", "vcs_", "session").is_err());
        assert!(checked_id("vcs_a/b", "vcs_", "session").is_err());
        assert!(checked_id("vcs_ABC", "vcs_", "session").is_err());
    }

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
        assert!(
            plan.args
                .contains(&"StrictHostKeyChecking=accept-new".to_owned())
        );
        assert!(
            plan.env
                .contains(&(ASKPASS_TOKEN_ENV.to_owned(), OsString::from("secret-token")))
        );
        assert!(
            plan.env
                .contains(&("SSH_ASKPASS_REQUIRE".to_owned(), OsString::from("force")))
        );
        assert!(
            plan.env
                .contains(&("SSH_ASKPASS".to_owned(), OsString::from("/bin/cmux-vm")))
        );
    }

    #[test]
    fn askpass_answers_only_password_prompts_of_an_ssh_child() {
        let child = |name: &str| match name {
            ASKPASS_TOKEN_ENV => Some("tok".to_owned()),
            "SSH_ASKPASS_REQUIRE" => Some("force".to_owned()),
            _ => None,
        };
        let mut out = Vec::new();
        assert_eq!(
            askpass(&child, Some("host+dev@ssh.example's password: "), &mut out),
            Some(0)
        );
        assert_eq!(out, b"tok\n");
        let mut out = Vec::new();
        assert_eq!(
            askpass(
                &child,
                Some("Are you sure you want to continue connecting (yes/no)?"),
                &mut out
            ),
            Some(1)
        );
        assert!(out.is_empty());
        let plain = |_: &str| None::<String>;
        assert_eq!(askpass(&plain, Some("password"), &mut Vec::new()), None);
        let no_force = |name: &str| (name == ASKPASS_TOKEN_ENV).then(|| "tok".to_owned());
        assert_eq!(askpass(&no_force, Some("password"), &mut Vec::new()), None);
    }
}
