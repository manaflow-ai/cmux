//! cmux-tui: a tmux-like terminal multiplexer TUI.
//!
//! Runs the mux core (workspaces → split panes → tabs on real PTYs,
//! terminal state from libghostty-vt) with a Ratatui frontend, and always
//! exposes the JSON control socket so external frontends can attach.
//! `cmux-tui attach` connects the same TUI to an existing (usually
//! headless) session over that socket, which is how detach/reattach works.

#[cfg(unix)]
mod agent_browser_provider;
mod agent_hook_install;
mod app;
mod browser_input;
mod cli;
mod client_log;
mod config;
mod host_colors;
mod keys;
mod layout_undo;
mod local_owner;
mod localization;
mod machine;
#[cfg(unix)]
mod machine_agent;
mod machine_provider_client;
#[cfg(unix)]
mod machine_provider_runtime;
mod machine_runtime;
mod plugin_manager;
mod process_diagnostics;
#[cfg(target_os = "linux")]
mod provider_authority;
#[cfg(unix)]
mod provider_notice_identity;
mod pty_input;
#[cfg(unix)]
mod remote_cli;
#[cfg(not(unix))]
mod remote_cli {
    pub fn is_remote_invocation(args: &[String]) -> bool {
        crate::cli::is_remote_invocation(args)
    }

    pub fn run(_: &[String], _: &str) -> i32 {
        crate::client_log::stderr_log!(
            "startup",
            "cmux-tui: remote daemon commands require Unix sockets and are unsupported on {}",
            std::env::consts::OS
        );
        1
    }
}
#[cfg(unix)]
mod remote_runtime;
mod session;
mod sidebar_files;
mod sidebar_projection;
mod ui;

#[cfg(target_os = "linux")]
use std::ffi::CStr;
use std::ffi::OsString;
use std::io::{self, BufRead, BufReader, IsTerminal, Read, Write};
use std::net::Shutdown;
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
#[cfg(unix)]
use std::sync::atomic::AtomicI32;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Context;
use cmux_tui_core::resource::TerminalPublicId;
use cmux_tui_core::{Mux, ProviderWorkspaceAuthority, SurfaceOptions};
#[cfg(unix)]
use cmux_tui_machine_protocol::BearerToken;
use machine::{
    MachineActionResult, MachineConnectRoute, MachineController, MachineRequest, MachineUiState,
};
#[cfg(unix)]
use machine_provider_client::{
    CommandProviderConnector, MachineProviderConnector, SshProviderConnector, UnixProviderConnector,
};
#[cfg(unix)]
use machine_provider_runtime::ProviderMachineController;
use machine_runtime::{
    MachineConnection, MachineConnectionHub, MachineConnectionLease, MachineRuntime,
};
use session::{RemoteSession, Session};
use zeroize::Zeroize;

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);
#[cfg(unix)]
static SIGNAL_WAKE_READER: AtomicI32 = AtomicI32::new(-1);
#[cfg(unix)]
static SIGNAL_WAKE_WRITER: AtomicI32 = AtomicI32::new(-1);
#[cfg(unix)]
const MACHINE_PROVIDER_TOKEN_ENV: &str = "CMUX_MACHINE_PROVIDER_TOKEN";
const PROVIDER_WORKSPACE_AUTHORITY_ENV: &str = "CMUX_PROVIDER_WORKSPACE_AUTHORITY";

#[cfg(target_os = "linux")]
unsafe extern "C" {
    static mut environ: *mut *mut libc::c_char;
}

#[cfg(unix)]
extern "C" fn handle_signal(_: libc::c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::Release);
    let writer = SIGNAL_WAKE_WRITER.load(Ordering::Relaxed);
    if writer >= 0 {
        let byte = 1_u8;
        // SAFETY: write(2) is async-signal-safe, `writer` is a process-lifetime
        // socket descriptor, and the one-byte source remains valid for the call.
        unsafe {
            let _ = libc::write(writer, std::ptr::from_ref(&byte).cast(), 1);
        }
    }
}

pub(crate) fn shutdown_requested() -> bool {
    SHUTDOWN_REQUESTED.load(Ordering::Acquire)
}

#[cfg(unix)]
fn install_signal_handlers() -> io::Result<()> {
    let (wake_reader, wake_writer) = UnixStream::pair()?;
    for descriptor in [wake_reader.as_raw_fd(), wake_writer.as_raw_fd()] {
        // UnixStream currently creates close-on-exec descriptors, but enforce
        // the ownership contract before these descriptors become process-wide.
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
        if flags < 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) } != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    wake_writer.set_nonblocking(true)?;
    SIGNAL_WAKE_READER.store(wake_reader.as_raw_fd(), Ordering::Release);
    SIGNAL_WAKE_WRITER.store(wake_writer.as_raw_fd(), Ordering::Release);
    unsafe {
        let mut action = std::mem::zeroed::<libc::sigaction>();
        action.sa_sigaction = handle_signal as *const () as libc::sighandler_t;
        if libc::sigemptyset(&mut action.sa_mask) != 0 {
            SIGNAL_WAKE_READER.store(-1, Ordering::Release);
            SIGNAL_WAKE_WRITER.store(-1, Ordering::Release);
            return Err(io::Error::last_os_error());
        }
        // Termination must interrupt startup and teardown syscalls. In
        // particular, reopening `/dev/tty` can block forever after the host
        // PTY disappears if the handler is installed with SA_RESTART.
        action.sa_flags = 0;
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            if libc::sigaction(signal, &action, std::ptr::null_mut()) != 0 {
                SIGNAL_WAKE_READER.store(-1, Ordering::Release);
                SIGNAL_WAKE_WRITER.store(-1, Ordering::Release);
                return Err(io::Error::last_os_error());
            }
        }
    }
    // The signal handler and one cancellation watcher own these descriptors
    // for the process lifetime. CLI exit and daemon shutdown reclaim them.
    std::mem::forget(wake_reader);
    std::mem::forget(wake_writer);
    Ok(())
}

#[cfg(unix)]
pub(crate) fn wait_for_shutdown_signal() {
    if shutdown_requested() {
        return;
    }
    let reader = SIGNAL_WAKE_READER.load(Ordering::Acquire);
    if reader < 0 {
        return;
    }
    let mut byte = 0_u8;
    loop {
        // SAFETY: `reader` is the process-lifetime socket descriptor installed
        // before signal handlers, and the one-byte destination is writable.
        let result = unsafe { libc::read(reader, std::ptr::from_mut(&mut byte).cast(), 1) };
        if result > 0 || shutdown_requested() {
            return;
        }
        if result < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return;
    }
}

#[cfg(unix)]
pub(crate) async fn wait_for_shutdown_signal_async() {
    if shutdown_requested() {
        return;
    }
    let reader = SIGNAL_WAKE_READER.load(Ordering::Acquire);
    if reader < 0 {
        return;
    }
    let duplicate = unsafe { libc::dup(reader) };
    if duplicate < 0 {
        return;
    }
    let stream = unsafe { UnixStream::from_raw_fd(duplicate) };
    if stream.set_nonblocking(true).is_err() {
        return;
    }
    let stream = match tokio::net::UnixStream::from_std(stream) {
        Ok(stream) => stream,
        Err(_) => return,
    };
    loop {
        if shutdown_requested() {
            return;
        }
        if stream.readable().await.is_err() {
            return;
        }
        let mut byte = [0_u8; 1];
        match stream.try_read(&mut byte) {
            Ok(_) => return,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
            Err(_) => return,
        }
    }
}

#[cfg(not(unix))]
pub(crate) async fn wait_for_shutdown_signal_async() {
    std::future::pending::<()>().await;
}

// No POSIX signals on Windows; Ctrl-C arrives as console input and the
// TUI's normal quit path handles shutdown.
#[cfg(not(unix))]
fn install_signal_handlers() -> io::Result<()> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn linux_environment_variable_present(name: &[u8]) -> bool {
    unsafe {
        let mut cursor = environ;
        while !cursor.is_null() && !(*cursor).is_null() {
            let entry = CStr::from_ptr(*cursor).to_bytes();
            if entry.get(..name.len()) == Some(name) && entry.get(name.len()) == Some(&b'=') {
                return true;
            }
            cursor = cursor.add(1);
        }
    }
    false
}

#[cfg(target_os = "linux")]
fn harden_provider_secret_process() -> io::Result<()> {
    if !linux_environment_variable_present(MACHINE_PROVIDER_TOKEN_ENV.as_bytes())
        && !linux_environment_variable_present(PROVIDER_WORKSPACE_AUTHORITY_ENV.as_bytes())
    {
        return Ok(());
    }
    let result = unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
    if result == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

#[cfg(target_os = "linux")]
fn require_non_dumpable_provider_process() -> anyhow::Result<()> {
    let dumpable = unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) };
    if dumpable == 0 {
        Ok(())
    } else if dumpable < 0 {
        Err(io::Error::last_os_error().into())
    } else {
        anyhow::bail!("provider workspace authority requires a non-dumpable mux process")
    }
}

#[cfg(not(target_os = "linux"))]
fn require_non_dumpable_provider_process() -> anyhow::Result<()> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn scrub_initial_environment_variable(name: &str) {
    let prefix = format!("{name}=");
    // Linux exposes the initial environment block through /proc even after
    // unsetenv. Clear the value in that original block before removing the
    // entry from the process environment.
    unsafe {
        let mut cursor = environ;
        while !cursor.is_null() && !(*cursor).is_null() {
            let entry = *cursor;
            let value_length = {
                let bytes = CStr::from_ptr(entry).to_bytes();
                bytes.strip_prefix(prefix.as_bytes()).map(<[u8]>::len)
            };
            if let Some(value_length) = value_length {
                std::ptr::write_bytes(entry.add(prefix.len()).cast::<u8>(), 0, value_length);
            }
            cursor = cursor.add(1);
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn scrub_initial_environment_variable(_: &str) {}

fn remove_secret_environment_variable(name: &str) {
    scrub_initial_environment_variable(name);
    // Startup calls this before creating runtime threads. The connector or
    // provider-managed mux already owns any credential selected for this mode.
    unsafe { std::env::remove_var(name) };
}

fn take_secret_environment_variable(name: &str) -> Option<OsString> {
    let value = std::env::var_os(name);
    remove_secret_environment_variable(name);
    value
}

fn zeroize_os_string(value: OsString) {
    let mut bytes = value.into_encoded_bytes();
    bytes.zeroize();
}

#[cfg(unix)]
struct CapturedProviderToken(Option<OsString>);

#[cfg(unix)]
impl CapturedProviderToken {
    fn capture() -> Self {
        Self(take_secret_environment_variable(MACHINE_PROVIDER_TOKEN_ENV))
    }

    #[cfg(test)]
    fn from_value(value: OsString) -> Self {
        Self(Some(value))
    }

    fn into_bearer(mut self) -> anyhow::Result<Option<BearerToken>> {
        self.0.take().map(parse_provider_token).transpose()
    }
}

#[cfg(unix)]
impl Drop for CapturedProviderToken {
    fn drop(&mut self) {
        if let Some(value) = self.0.take() {
            zeroize_os_string(value);
        }
    }
}

struct CapturedProviderWorkspaceAuthority(Option<OsString>);

impl CapturedProviderWorkspaceAuthority {
    fn capture() -> Self {
        Self(take_secret_environment_variable(PROVIDER_WORKSPACE_AUTHORITY_ENV))
    }

    fn into_authority(mut self) -> anyhow::Result<Option<ProviderWorkspaceAuthority>> {
        if self.0.is_none() {
            return Ok(None);
        }
        require_non_dumpable_provider_process()?;
        let mut bytes = self.0.take().expect("presence checked").into_encoded_bytes();
        let value = std::str::from_utf8(&bytes)
            .map(str::to_owned)
            .map_err(|_| anyhow::anyhow!("provider workspace authority is not valid UTF-8"));
        bytes.zeroize();
        let value = value?;
        ProviderWorkspaceAuthority::new(value).map(Some)
    }
}

impl Drop for CapturedProviderWorkspaceAuthority {
    fn drop(&mut self) {
        if let Some(value) = self.0.take() {
            zeroize_os_string(value);
        }
    }
}

fn discard_provider_secret_environment() {
    #[cfg(unix)]
    remove_secret_environment_variable(MACHINE_PROVIDER_TOKEN_ENV);
    remove_secret_environment_variable(PROVIDER_WORKSPACE_AUTHORITY_ENV);
}

#[cfg(not(target_os = "linux"))]
fn harden_provider_secret_process() -> io::Result<()> {
    Ok(())
}

const USAGE: &str = "\
cmux - terminal multiplexer and resource client

USAGE
  cmux [OPTIONS]           Start a session
{lifecycle_usage}
  cmux attach [OPTIONS]    Attach to a session or one terminal
  cmux relay [OPTIONS]     Relay protocol bytes over stdio
  {machine_agent_usage}
  cmux <scope> --help      Discover resource commands

START OPTIONS
  --session <name>   Session name (default: main). Determines the socket path.
  --socket <path>    Explicit control socket path.
  --terminal <id>    With attach, show only this terminal (use `cmux terminal list`).
  --state <path>     Durable session-state root (default: platform state dir).
  --ephemeral        Keep workspace state in memory for this run only.
  --machine-provider <path>
                     Use a dynamic machine provider Unix socket.
  --machine-provider-command <program> [arg ...] --
                     Run a provider command directly, appending control or stream.
  --cloud            Connect through the built-in cmux.cloud SSH provider.
  --cloud-host <host>       Cloud SSH host (default: cmux.cloud).
  --cloud-user <user>       Cloud SSH user.
  --cloud-port <port>       Cloud SSH port.
  --cloud-identity <path>   Cloud SSH identity file.
  --headless         Run only the control socket, no TUI.
  --ws <addr>        Also listen for WebSocket clients (default: off).
  --ws-token <token> Allow a static-token bypass for interactive pairing.
  --ws-insecure-bind Allow a non-loopback WebSocket bind (no TLS; use a proxy).
  --remote          Run the authenticated remote daemon with this session.
  --remote-ws <addr> Listen for direct remote WebSocket links.
  --remote-ws-insecure-bind  Allow plaintext remote WebSocket off loopback.
  --remote-http <addr> Listen for bearer-authenticated workspace HTTP RPC on loopback.
  --remote-state-dir <path>  Override remote identity and runtime state.
  --remote-link-socket <path> Override the local authenticated link socket.
  --remote-admin-socket <path> Override the owner-only admin socket.
  --remote-resume-lease-seconds <seconds>
                    Retain crashed-client replay state for 1-86400 seconds.
  --relay <url> --relay-slot <routing-key>
                    Register with a relay; repeat up to four groups.
  --relay-ticket-file <path>  Refresh the relay ticket from a file.
  --relay-ticket-command <program> [--relay-ticket-command-arg <arg>]
                    Refresh the relay ticket from an argv-based command.
  --iroh            Publish an Iroh route for NAT traversal and mobile use.
  --advertise <url> Add a non-secret route hint to enrollment invitations.
  --term <value>     TERM for child shells (default: keep the outer terminal's
                     xterm-ghostty, else xterm-256color).
  -h, --help         Show this help.
  -V, --version      Print the cmux version.
";

fn usage_for(catalog: &localization::Catalog) -> String {
    usage_for_platform(catalog, cfg!(unix))
}

fn usage_for_platform(catalog: &localization::Catalog, supports_machine_agent: bool) -> String {
    let usage = USAGE.replace(
        "{lifecycle_usage}\n",
        &format!("{}\n", catalog.local_server.startup_lifecycle_usage),
    );
    if supports_machine_agent {
        usage.replace("  {machine_agent_usage}\n", &format!("  {}\n", catalog.machine_agent.usage))
    } else {
        usage.replace("  {machine_agent_usage}\n", "")
    }
}

fn usage() -> String {
    usage_for(localization::catalog())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Args {
    attach: bool,
    session: String,
    socket: Option<PathBuf>,
    terminal: Option<String>,
    state: Option<PathBuf>,
    ephemeral: bool,
    machine_provider: Option<PathBuf>,
    machine_provider_command: Option<Vec<String>>,
    cloud: bool,
    cloud_host: Option<String>,
    cloud_user: Option<String>,
    cloud_port: Option<u16>,
    cloud_identity: Option<PathBuf>,
    headless: bool,
    ws: Option<String>,
    ws_token: Option<String>,
    ws_insecure_bind: bool,
    remote: bool,
    remote_ws: Option<String>,
    remote_ws_insecure_bind: bool,
    remote_http: Option<String>,
    remote_state_dir: Option<PathBuf>,
    remote_link_socket: Option<PathBuf>,
    remote_admin_socket: Option<PathBuf>,
    remote_resume_lease_seconds: u64,
    relay_endpoints: Vec<String>,
    relay_slots: Vec<String>,
    relay_credentials: Vec<RelayCredentialArg>,
    iroh: bool,
    advertised_routes: Vec<String>,
    term: Option<String>,
    agent_browser_provider: bool,
}

#[derive(Clone, PartialEq, Eq)]
enum RelayCredentialArg {
    File(PathBuf),
    Command { program: String, args: Vec<String> },
}

impl std::fmt::Debug for RelayCredentialArg {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::File(path) => formatter.debug_tuple("File").field(path).finish(),
            Self::Command { program, args } => formatter
                .debug_struct("Command")
                .field("program", program)
                .field("argument_count", &args.len())
                .finish(),
        }
    }
}

impl Args {
    fn should_attach_existing(&self, ws_addr: &Option<String>, ws_token: &Option<String>) -> bool {
        !self.headless
            && ws_addr.is_none()
            && ws_token.is_none()
            && !self.ws_insecure_bind
            && !self.remote
            && self.term.is_none()
    }
}

fn parse_args(args: impl IntoIterator<Item = String>) -> Args {
    parse_args_result(args).unwrap_or_else(|message| usage_exit(&message))
}

fn parse_args_result(args: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let args = args.into_iter().collect::<Vec<_>>();
    if has_inline_relay_ticket_argument(&args) {
        return Err(localization::catalog().remote_client.inline_relay_ticket_rejected.to_string());
    }
    let mut out = Args {
        attach: false,
        session: "main".to_string(),
        socket: None,
        terminal: None,
        state: None,
        ephemeral: false,
        machine_provider: None,
        machine_provider_command: None,
        cloud: false,
        cloud_host: None,
        cloud_user: None,
        cloud_port: None,
        cloud_identity: None,
        headless: false,
        ws: None,
        ws_token: None,
        ws_insecure_bind: false,
        remote: false,
        remote_ws: None,
        remote_ws_insecure_bind: false,
        remote_http: None,
        remote_state_dir: None,
        remote_link_socket: None,
        remote_admin_socket: None,
        remote_resume_lease_seconds: 120,
        relay_endpoints: Vec::new(),
        relay_slots: Vec::new(),
        relay_credentials: Vec::new(),
        iroh: false,
        advertised_routes: Vec::new(),
        term: None,
        agent_browser_provider: false,
    };
    let mut args = args.into_iter().peekable();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            // Accept the attach verb wherever startup options are accepted.
            // This matches the usual CLI convention that global options may
            // precede a subcommand, while preserving the existing
            // `cmux attach ...` spelling.
            "attach" => {
                if out.attach {
                    return Err(localization::catalog().startup.duplicate_attach.to_string());
                }
                out.attach = true;
            }
            "--session" => {
                out.session = args.next().ok_or_else(|| "--session needs a value".to_string())?;
            }
            "--socket" => {
                out.socket =
                    Some(args.next().ok_or_else(|| "--socket needs a value".to_string())?.into());
            }
            "--terminal" => {
                out.terminal =
                    Some(args.next().ok_or_else(|| "--terminal needs a value".to_string())?);
            }
            "--machine-provider" => {
                if out.machine_provider.is_some() {
                    return Err("--machine-provider may be supplied only once".to_string());
                }
                out.machine_provider = Some(
                    args.next()
                        .ok_or_else(|| "--machine-provider needs a value".to_string())?
                        .into(),
                );
            }
            "--machine-provider-command" => {
                if out.machine_provider_command.is_some() {
                    return Err("--machine-provider-command may be supplied only once".to_string());
                }
                let mut command = Vec::new();
                loop {
                    match args.next() {
                        Some(value) if value == "--" => break,
                        Some(value) => command.push(value),
                        None => {
                            return Err(
                                "--machine-provider-command values must end with --".to_string()
                            );
                        }
                    }
                }
                if command.is_empty() {
                    return Err("--machine-provider-command needs a program".to_string());
                }
                out.machine_provider_command = Some(command);
            }
            "--cloud" => out.cloud = true,
            "--cloud-host" => {
                out.cloud_host =
                    Some(args.next().ok_or_else(|| "--cloud-host needs a value".to_string())?);
            }
            "--cloud-user" => {
                out.cloud_user =
                    Some(args.next().ok_or_else(|| "--cloud-user needs a value".to_string())?);
            }
            "--cloud-port" => {
                let value = args.next().ok_or_else(|| "--cloud-port needs a value".to_string())?;
                let port =
                    value.parse::<u16>().map_err(|_| format!("invalid --cloud-port {value:?}"))?;
                if port == 0 {
                    return Err("--cloud-port cannot be zero".to_string());
                }
                out.cloud_port = Some(port);
            }
            "--cloud-identity" => {
                out.cloud_identity = Some(
                    args.next().ok_or_else(|| "--cloud-identity needs a value".to_string())?.into(),
                );
            }
            "--state" => {
                out.state =
                    Some(args.next().unwrap_or_else(|| usage_exit("--state needs a value")).into());
            }
            "--ephemeral" => out.ephemeral = true,
            "--headless" => out.headless = true,
            "--ws" => {
                out.ws = Some(args.next().ok_or_else(|| "--ws needs a value".to_string())?);
            }
            "--ws-token" => {
                out.ws_token =
                    Some(args.next().ok_or_else(|| "--ws-token needs a value".to_string())?);
            }
            "--ws-insecure-bind" => out.ws_insecure_bind = true,
            "--remote" => out.remote = true,
            "--remote-ws" => {
                out.remote_ws =
                    Some(args.next().unwrap_or_else(|| usage_exit("--remote-ws needs a value")));
                out.remote = true;
            }
            "--remote-ws-insecure-bind" => {
                out.remote_ws_insecure_bind = true;
                out.remote = true;
            }
            "--remote-http" => {
                out.remote_http =
                    Some(args.next().unwrap_or_else(|| usage_exit("--remote-http needs a value")));
                out.remote = true;
            }
            "--remote-state-dir" => {
                out.remote_state_dir = Some(
                    args.next()
                        .unwrap_or_else(|| usage_exit("--remote-state-dir needs a value"))
                        .into(),
                );
                out.remote = true;
            }
            "--remote-link-socket" => {
                out.remote_link_socket = Some(
                    args.next()
                        .unwrap_or_else(|| usage_exit("--remote-link-socket needs a value"))
                        .into(),
                );
                out.remote = true;
            }
            "--remote-admin-socket" => {
                out.remote_admin_socket = Some(
                    args.next()
                        .unwrap_or_else(|| usage_exit("--remote-admin-socket needs a value"))
                        .into(),
                );
                out.remote = true;
            }
            "--remote-resume-lease-seconds" => {
                let value = args
                    .next()
                    .unwrap_or_else(|| usage_exit("--remote-resume-lease-seconds needs a value"));
                out.remote_resume_lease_seconds = value.parse().unwrap_or_else(|_| {
                    usage_exit("--remote-resume-lease-seconds must be an integer")
                });
                if !(1..=86_400).contains(&out.remote_resume_lease_seconds) {
                    usage_exit("--remote-resume-lease-seconds must be between 1 and 86400");
                }
                out.remote = true;
            }
            "--relay" => {
                out.relay_endpoints
                    .push(args.next().unwrap_or_else(|| usage_exit("--relay needs a value")));
                out.remote = true;
            }
            "--relay-slot" => {
                out.relay_slots
                    .push(args.next().unwrap_or_else(|| usage_exit("--relay-slot needs a value")));
                out.remote = true;
            }
            option if option == "--relay-ticket" || option.starts_with("--relay-ticket=") => {
                return Err(localization::catalog()
                    .remote_client
                    .inline_relay_ticket_rejected
                    .to_string());
            }
            "--relay-ticket-file" => {
                out.relay_credentials.push(RelayCredentialArg::File(
                    args.next()
                        .unwrap_or_else(|| usage_exit("--relay-ticket-file needs a value"))
                        .into(),
                ));
                out.remote = true;
            }
            "--relay-ticket-command" => {
                out.relay_credentials.push(RelayCredentialArg::Command {
                    program: args
                        .next()
                        .unwrap_or_else(|| usage_exit("--relay-ticket-command needs a value")),
                    args: Vec::new(),
                });
                out.remote = true;
            }
            "--relay-ticket-command-arg" => {
                let argument = args
                    .next()
                    .unwrap_or_else(|| usage_exit("--relay-ticket-command-arg needs a value"));
                match out.relay_credentials.last_mut() {
                    Some(RelayCredentialArg::Command { args, .. }) => args.push(argument),
                    _ => {
                        usage_exit("--relay-ticket-command-arg must follow --relay-ticket-command")
                    }
                }
                out.remote = true;
            }
            "--iroh" => {
                out.iroh = true;
                out.remote = true;
            }
            "--advertise" => {
                out.advertised_routes
                    .push(args.next().unwrap_or_else(|| usage_exit("--advertise needs a value")));
                out.remote = true;
            }
            "--term" => {
                out.term = Some(args.next().ok_or_else(|| "--term needs a value".to_string())?);
            }
            // Private launch contract used by cmux-browser. It configures
            // Vercel agent-browser to attach through the local provider
            // adapter instead of starting an unrelated Chrome process.
            "--agent-browser-provider" => out.agent_browser_provider = true,
            "-h" | "--help" => {
                print!("{}", usage());
                client_log::exit(0);
            }
            "-V" | "--version" => {
                println!("cmux {}", version_string());
                client_log::exit(0);
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    if out.terminal.is_some() && !out.attach {
        return Err("--terminal requires `cmux attach`".to_string());
    }
    #[cfg(not(unix))]
    if out.agent_browser_provider {
        return Err(format!("--agent-browser-provider is unsupported on {}", std::env::consts::OS));
    }
    Ok(out)
}

pub(crate) fn version_string() -> String {
    // Packaged builds stamp both source identities so artifact validation can
    // reject a cmux binary built against a different Ghostty checkout before
    // it enters an app bundle. Local builds report the crate version alone.
    let commit = option_env!("CMUX_TUI_BUILD_COMMIT")
        .or(option_env!("CMUX_MUX_BUILD_COMMIT"))
        .filter(|commit| !commit.is_empty());
    let ghostty = option_env!("CMUX_TUI_GHOSTTY_COMMIT").filter(|commit| !commit.is_empty());
    match (commit, ghostty) {
        (Some(commit), Some(ghostty)) => {
            format!("{} ({commit}; ghostty {ghostty})", env!("CARGO_PKG_VERSION"))
        }
        (Some(commit), None) => format!("{} ({commit})", env!("CARGO_PKG_VERSION")),
        (None, _) => env!("CARGO_PKG_VERSION").to_string(),
    }
}

#[cfg(unix)]
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

#[cfg(windows)]
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(unix)]
fn shell_prompt() -> &'static str {
    ""
}

#[cfg(windows)]
fn shell_prompt() -> &'static str {
    "PowerShell> "
}

#[derive(Debug, PartialEq, Eq)]
enum SchemaSocketOwner {
    Absent,
    Matching { pid: u32, generation: String },
    ForcedHandoffUnsupported,
    Different,
    Unverified,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResetStateRecoverySupport {
    Supported,
    #[cfg_attr(
        any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"),
        allow(dead_code)
    )]
    Unsupported,
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
fn reset_state_recovery_support() -> ResetStateRecoverySupport {
    ResetStateRecoverySupport::Supported
}

#[cfg(not(any(
    target_os = "ios",
    target_os = "macos",
    target_os = "linux",
    target_os = "android"
)))]
fn reset_state_recovery_support() -> ResetStateRecoverySupport {
    ResetStateRecoverySupport::Unsupported
}

fn schema_socket_owner(
    socket_path: &Path,
    expected_session: &str,
    expected_registry_id: Option<&str>,
) -> SchemaSocketOwner {
    let stream = match cmux_tui_core::platform::transport::connect(socket_path) {
        Ok(stream) => stream,
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
            ) =>
        {
            return SchemaSocketOwner::Absent;
        }
        Err(_) => return SchemaSocketOwner::Unverified,
    };
    let timeout = Some(std::time::Duration::from_millis(500));
    if stream.set_read_timeout(timeout).is_err() || stream.set_write_timeout(timeout).is_err() {
        return SchemaSocketOwner::Unverified;
    }
    let Ok(mut writer) = stream.try_clone_box() else {
        return SchemaSocketOwner::Unverified;
    };
    if writer.write_all(b"{\"id\":0,\"cmd\":\"identify\"}\n").and_then(|()| writer.flush()).is_err()
    {
        return SchemaSocketOwner::Unverified;
    }
    let mut reader = BufReader::new(stream).take(64 * 1024);
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() || !line.ends_with('\n') {
        return SchemaSocketOwner::Unverified;
    }
    let Ok(response) = serde_json::from_str::<serde_json::Value>(&line) else {
        return SchemaSocketOwner::Unverified;
    };
    let data = &response["data"];
    if response["id"] != 0 || response["ok"] != true || data["app"] != "cmux-tui" {
        return SchemaSocketOwner::Unverified;
    }
    let Some(expected_registry_id) = expected_registry_id else {
        return SchemaSocketOwner::Unverified;
    };
    if data["session"] != expected_session || data["registry_id"] != expected_registry_id {
        return SchemaSocketOwner::Different;
    }
    if !data["capabilities"].as_array().is_some_and(|capabilities| {
        capabilities
            .iter()
            .any(|capability| capability == cmux_tui_core::server::DAEMON_HANDOFF_FORCE_CAPABILITY)
    }) {
        return SchemaSocketOwner::ForcedHandoffUnsupported;
    }
    let Some(pid) = data["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()) else {
        return SchemaSocketOwner::Unverified;
    };
    let Some(generation) = data["generation"].as_str().filter(|generation| !generation.is_empty())
    else {
        return SchemaSocketOwner::Unverified;
    };
    SchemaSocketOwner::Matching { pid, generation: generation.to_string() }
}

fn workspace_schema_startup_error(
    error: anyhow::Error,
    session: &str,
    socket_path: &Path,
    state_root: Option<&Path>,
) -> anyhow::Error {
    let Some(schema) = error.downcast_ref::<cmux_tui_core::UnsupportedWorkspaceRegistrySchema>()
    else {
        return error;
    };
    let messages = &localization::catalog().startup;
    let socket = socket_path.display().to_string();
    let socket_recovery = match schema_socket_owner(socket_path, session, schema.registry_id()) {
        SchemaSocketOwner::Matching { pid, generation } => {
            let request = serde_json::to_string(&serde_json::json!({
                "cmd": "shutdown-daemon",
                "force": true,
                "generation": generation,
                "id": 1,
                "pid": pid,
            }))
            .expect("daemon shutdown request is serializable");
            let stop_command = format!(
                "{}cmux --socket {} raw command --request-json {}",
                shell_prompt(),
                shell_quote(&socket),
                shell_quote(&request),
            );
            format!("{}\n  {stop_command}", messages.stop_newer_server)
        }
        SchemaSocketOwner::Absent => absent_socket_schema_recovery(
            messages,
            session,
            state_root,
            reset_state_recovery_support(),
        ),
        SchemaSocketOwner::ForcedHandoffUnsupported => {
            messages.forced_handoff_unsupported.to_string()
        }
        SchemaSocketOwner::Different => messages.different_server.to_string(),
        SchemaSocketOwner::Unverified => messages.server_not_verified.to_string(),
    };
    let separate_session = format!("{session}-separate");
    let separate_command =
        format!("{}cmux --session {}", shell_prompt(), shell_quote(&separate_session));
    anyhow::anyhow!(format!(
        "{}\n{}: {}\n{}\n{}\n{}\n  {}",
        messages.schema_too_new(session, &version_string()),
        messages.session_socket,
        socket,
        socket_recovery,
        messages.saved_state_requires_newer,
        messages.start_separate_session,
        separate_command,
    ))
}

fn absent_socket_schema_recovery(
    messages: &localization::StartupMessages,
    session: &str,
    state_root: Option<&Path>,
    support: ResetStateRecoverySupport,
) -> String {
    match support {
        ResetStateRecoverySupport::Supported => {
            let reset_command = session_reset_state_command(session, state_root);
            format!(
                "{}\n{}\n  {}",
                messages.no_server_listening, messages.reset_saved_state, reset_command
            )
        }
        ResetStateRecoverySupport::Unsupported => {
            format!("{}\n{}", messages.no_server_listening, messages.reset_saved_state_unsupported)
        }
    }
}

fn session_reset_state_command(session: &str, state_root: Option<&Path>) -> String {
    let selector = session_selector_for_command(session);
    let mut command =
        format!("{}cmux session {} reset-state", shell_prompt(), shell_quote(&selector));
    if let Some(state_root) = state_root {
        command.push_str(" --state ");
        command.push_str(&shell_quote(&state_root.display().to_string()));
    }
    command
}

fn session_selector_for_command(session: &str) -> String {
    match cmux_tui_core::resource::Selector::parse(session) {
        Ok(cmux_tui_core::resource::Selector::Name(name))
            if name == session && !session.starts_with('-') =>
        {
            session.to_string()
        }
        _ => format!("name:{session}"),
    }
}

impl Args {
    fn cloud_cli_requested(&self) -> bool {
        self.cloud
            || self.cloud_host.is_some()
            || self.cloud_user.is_some()
            || self.cloud_port.is_some()
            || self.cloud_identity.is_some()
    }

    fn provider_cli_requested(&self) -> bool {
        self.machine_provider.is_some()
            || self.machine_provider_command.is_some()
            || self.cloud_cli_requested()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ProviderLaunch {
    Unix(PathBuf),
    Command(Vec<OsString>),
    Cloud(CloudLaunch),
}

impl ProviderLaunch {
    /// Only a locally initiated Cloud client may use the caller's SSH config,
    /// agent, and known_hosts for ad-hoc machines. A Unix provider can be the
    /// native `ssh cmux.cloud` edge process and must remain provider-only.
    fn enables_client_machine_connect(&self) -> bool {
        matches!(self, Self::Cloud(_))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CloudLaunch {
    host: String,
    user: Option<String>,
    port: Option<u16>,
    identity_file: Option<PathBuf>,
}

fn resolve_provider_launch(
    args: &Args,
    config: &config::Config,
) -> anyhow::Result<Option<ProviderLaunch>> {
    let explicit_modes = usize::from(args.machine_provider.is_some())
        + usize::from(args.machine_provider_command.is_some())
        + usize::from(args.cloud_cli_requested());
    if explicit_modes > 1 {
        anyhow::bail!(
            "choose only one provider mode: --machine-provider, --machine-provider-command, or --cloud"
        );
    }

    let launch = if let Some(socket) = &args.machine_provider {
        Some(ProviderLaunch::Unix(socket.clone()))
    } else if let Some(command) = &args.machine_provider_command {
        Some(ProviderLaunch::Command(command.iter().map(OsString::from).collect()))
    } else if let Some(command) =
        // Config parity with --machine-provider-command. Any explicit CLI
        // provider mode above wins; an explicit --cloud also wins below, so
        // the config command only applies when the CLI chose nothing.
        config
            .machine_provider
            .command
            .as_ref()
            .filter(|_| !args.cloud_cli_requested())
    {
        Some(ProviderLaunch::Command(command.iter().map(OsString::from).collect()))
    } else if args.cloud_cli_requested() || config.machine_provider.cloud.enabled {
        let cloud = &config.machine_provider.cloud;
        Some(ProviderLaunch::Cloud(CloudLaunch {
            host: args.cloud_host.clone().unwrap_or_else(|| cloud.host.clone()),
            user: args.cloud_user.clone().or_else(|| cloud.user.clone()),
            port: args.cloud_port.or(cloud.port),
            identity_file: args.cloud_identity.clone().or_else(|| cloud.identity_file.clone()),
        }))
    } else {
        None
    };
    if !config.machines.is_empty()
        && matches!(launch, Some(ProviderLaunch::Unix(_) | ProviderLaunch::Command(_)))
    {
        anyhow::bail!("static machines can only be combined with the local cloud provider client");
    }
    Ok(launch)
}

#[cfg(unix)]
fn provider_connector_with_unix_token(
    launch: ProviderLaunch,
    unix_token: CapturedProviderToken,
) -> anyhow::Result<Arc<dyn MachineProviderConnector>> {
    let connector: Arc<dyn MachineProviderConnector> = match launch {
        ProviderLaunch::Unix(socket) => match unix_token.into_bearer()? {
            Some(token) => Arc::new(UnixProviderConnector::new(socket, token)),
            None => Arc::new(UnixProviderConnector::generated(socket)),
        },
        ProviderLaunch::Command(command) => Arc::new(CommandProviderConnector::new(command)?),
        ProviderLaunch::Cloud(cloud) => Arc::new(SshProviderConnector::cloud(
            &cloud.host,
            cloud.user.as_deref(),
            cloud.port,
            cloud.identity_file,
        )?),
    };
    Ok(connector)
}

#[cfg(unix)]
fn parse_provider_token(value: OsString) -> anyhow::Result<BearerToken> {
    let mut bytes = value.into_encoded_bytes();
    let value = std::str::from_utf8(&bytes)
        .map(str::to_owned)
        .map_err(|_| anyhow::anyhow!("machine-provider credential is not valid UTF-8"));
    bytes.zeroize();
    let value = value?;
    BearerToken::new(value).map_err(|_| anyhow::anyhow!("machine-provider credential is invalid"))
}

fn validate_provider_process_args(args: &Args) -> anyhow::Result<()> {
    let mut conflicts = Vec::new();
    if args.attach {
        conflicts.push("attach");
    }
    if args.session != "main" {
        conflicts.push("--session");
    }
    if args.socket.is_some() {
        conflicts.push("--socket");
    }
    if args.state.is_some() {
        conflicts.push("--state");
    }
    if args.ephemeral {
        conflicts.push("--ephemeral");
    }
    if args.headless {
        conflicts.push("--headless");
    }
    if args.ws.is_some() {
        conflicts.push("--ws");
    }
    if args.ws_token.is_some() {
        conflicts.push("--ws-token");
    }
    if args.ws_insecure_bind {
        conflicts.push("--ws-insecure-bind");
    }
    if args.remote {
        conflicts.push("remote daemon options");
    }
    if args.term.is_some() {
        conflicts.push("--term");
    }
    if args.agent_browser_provider {
        conflicts.push("--agent-browser-provider");
    }
    if !conflicts.is_empty() {
        anyhow::bail!("machine provider mode cannot be combined with {}", conflicts.join(", "));
    }
    Ok(())
}

fn rewrite_server_start(args: &mut Vec<String>) {
    let mut index = 0;
    let mut output_mode = false;
    while index < args.len() {
        match args[index].as_str() {
            "--socket" | "--session" | "--machine" => {
                if args.get(index + 1).is_none() {
                    return;
                }
                index = startup_option_value_end(args, index).unwrap_or(args.len());
            }
            "--json" | "--jsonl" | "--quiet" => {
                output_mode = true;
                index += 1;
            }
            "-h" | "--help" => return,
            "server" if args.get(index + 1).map(String::as_str) == Some("start") => {
                let start_args = &args[index + 2..];
                if (output_mode && !has_inline_relay_ticket_argument(start_args))
                    || server_start_has_cli_routing_flag(start_args)
                {
                    return;
                }
                args.drain(index..index + 2);
                args.insert(0, "--headless".to_string());
                return;
            }
            _ => return,
        }
    }
}

const STARTUP_VALUE_OPTIONS: &[&str] = &[
    "--socket",
    "--session",
    "--machine",
    "--terminal",
    "--state",
    "--machine-provider",
    "--cloud-host",
    "--cloud-user",
    "--cloud-port",
    "--cloud-identity",
    "--ws",
    "--ws-token",
    "--remote-ws",
    "--remote-http",
    "--remote-state-dir",
    "--remote-link-socket",
    "--remote-admin-socket",
    "--remote-resume-lease-seconds",
    "--relay",
    "--relay-slot",
    "--relay-ticket",
    "--relay-ticket-file",
    "--relay-ticket-command",
    "--relay-ticket-command-arg",
    "--advertise",
    "--term",
];

/// Return the first argument after a startup option and its value.
///
/// Startup routing, relay-ticket protection, and lifecycle rewriting all need
/// to skip the same value-bearing options. Keeping the spans in one helper
/// prevents a new startup option from being handled by only one scanner.
fn startup_option_value_end(args: &[String], index: usize) -> Option<usize> {
    let option = args.get(index)?.as_str();
    if STARTUP_VALUE_OPTIONS.contains(&option) {
        return args.get(index + 1).map(|_| index + 2);
    }
    if option == "--machine-provider-command" {
        let mut end = index + 1;
        while end < args.len() && args[end] != "--" {
            end += 1;
        }
        return Some(end + 1);
    }
    None
}

fn is_inline_relay_ticket(value: &str) -> bool {
    value == "--relay-ticket" || value.starts_with("--relay-ticket=")
}

fn has_inline_relay_ticket_argument(args: &[String]) -> bool {
    let mut index = 0;
    while index < args.len() {
        let option = args[index].as_str();
        if is_inline_relay_ticket(option) {
            return true;
        }
        if let Some(end) = startup_option_value_end(args, index) {
            // A helper argument or provider command may intentionally contain
            // the literal `--relay-ticket`; those payloads are not startup
            // credentials and must remain untouched.
            if option != "--relay-ticket-command-arg"
                && option != "--machine-provider-command"
                && args.get(index + 1).is_some_and(|value| is_inline_relay_ticket(value))
            {
                return true;
            }
            index = end;
        } else {
            index += 1;
        }
    }
    false
}

fn server_start_has_cli_routing_flag(args: &[String]) -> bool {
    if has_inline_relay_ticket_argument(args) {
        return false;
    }
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "-h" | "--help" | "--json" | "--jsonl" | "--quiet" => return true,
            _ => index = startup_option_value_end(args, index).unwrap_or(index + 1),
        }
    }
    false
}

fn is_cli_invocation(args: &[String]) -> bool {
    if args.first().map(String::as_str) == Some("--headless")
        && has_inline_relay_ticket_argument(args)
    {
        return false;
    }
    let mut index = 0;
    while index < args.len() {
        let value = args[index].as_str();
        if value == "--machine-provider-command" {
            return false;
        }
        match value {
            "--json" | "--jsonl" | "--quiet" => index += 1,
            "--ephemeral"
            | "--cloud"
            | "--headless"
            | "--ws-insecure-bind"
            | "--remote"
            | "--remote-ws-insecure-bind"
            | "--iroh" => index += 1,
            "-h" | "--help" | "help" => return true,
            "attach" => return false,
            value if cli::is_public_scope(value) => return true,
            _ => {
                if let Some(end) = startup_option_value_end(args, index) {
                    index = end;
                } else if value.starts_with('-') {
                    index += 1;
                } else {
                    // Session startup has no positional arguments. Route
                    // unknown top-level words through the public parser so
                    // typos cannot fall into the unrelated legacy startup
                    // help.
                    return true;
                }
            }
        }
    }
    false
}

fn normalize_remote_resource_args(raw_args: &mut Vec<String>) -> Result<(), String> {
    if raw_args.first().map(String::as_str) != Some("remote") {
        return Ok(());
    }
    match raw_args.get(1).map(String::as_str) {
        Some("stop") => {
            raw_args.drain(..2);
            raw_args.insert(0, "remote-stop".to_string());
        }
        Some("connect" | "ssh" | "forward" | "rpc" | "enroll" | "known-daemons") => {
            raw_args.remove(0);
        }
        Some("-h" | "--help") | None => {}
        Some(_)
            if raw_args[2..]
                .iter()
                .any(|argument| matches!(argument.as_str(), "-h" | "--help")) => {}
        Some(action) => {
            return Err(localization::catalog().remote_client.unknown_action("remote", action));
        }
    }
    Ok(())
}

fn main() {
    run_main();
    // Reached only by the normal return paths, which never call
    // client_log::exit; flush so the last queued records (final status,
    // shutdown diagnostics) reach the client log on every platform.
    client_log::flush_for_exit();
}

fn run_main() {
    // Pin the launch directory before any subsystem can move the process:
    // new terminals default to it (not $HOME) for the daemon's lifetime.
    cmux_tui_core::platform::capture_launch_cwd();
    let mut raw_args = std::env::args().skip(1).collect::<Vec<_>>();
    #[cfg(unix)]
    if raw_args.first().map(String::as_str) == Some("__agent-browser-provider") {
        client_log::exit(agent_browser_provider::run());
    }
    // Private process mode used by the daemon when it launches one durable
    // terminal host per PTY. Keep this out of public help and dispatch it
    // before installing the interactive daemon's signal handlers: the host
    // owns its own lifecycle and must not inherit "request mux shutdown"
    // semantics.
    if raw_args.first().map(String::as_str) == Some("__terminal-host") {
        if let Err(error) = run_terminal_host_process(&raw_args[1..]) {
            crate::client_log::stderr_log!("startup", "cmux-tui terminal host: {error}");
            client_log::exit(1);
        }
        return;
    }
    if config::is_ghostty_config_helper_invocation(&raw_args) {
        if let Err(error) = harden_provider_secret_process() {
            crate::client_log::stderr_log!(
                "startup",
                "cmux-tui: cannot protect machine-provider credentials: {error}"
            );
            client_log::exit(1);
        }
        discard_provider_secret_environment();
        client_log::exit(config::run_ghostty_config_helper());
    }
    if let Err(error) = harden_provider_secret_process() {
        crate::client_log::stderr_log!(
            "startup",
            "cmux-tui: cannot protect machine-provider credentials: {error}"
        );
        client_log::exit(1);
    }
    if let Err(error) = install_signal_handlers() {
        crate::client_log::stderr_log!(
            "startup",
            "cmux-tui: {}",
            localization::catalog().runtime.signal_handlers_failed(&error.to_string())
        );
        client_log::exit(1);
    }
    #[cfg(target_os = "linux")]
    if let Some(exit_code) = provider_authority::try_run(&raw_args) {
        client_log::exit(exit_code);
    }
    if let Err(error) = normalize_remote_resource_args(&mut raw_args) {
        crate::client_log::stderr_log!("startup", "cmux-tui: {error}");
        client_log::exit(1);
    }
    if remote_cli::is_remote_invocation(&raw_args) {
        discard_provider_secret_environment();
        client_log::exit(remote_cli::run(&raw_args, &usage()));
    }
    if raw_args.first().map(|arg| arg.as_str()) == Some("relay") {
        let args = parse_args(raw_args.into_iter().skip(1));
        discard_provider_secret_environment();
        if let Err(error) = run_relay(args) {
            crate::client_log::stderr_log!("startup", "cmux-tui: {error}");
            client_log::exit(1);
        }
        return;
    }
    #[cfg(unix)]
    if raw_args.first().map(|arg| arg.as_str()) == Some("machine-agent") {
        discard_provider_secret_environment();
        if let Err(error) = machine_agent::run(&raw_args[1..]) {
            crate::client_log::stderr_log!("startup", "cmux-tui: {error}");
            if error.show_help() {
                crate::client_log::stderr_log!(
                    "startup",
                    "{}",
                    localization::catalog().machine_agent.help
                );
            }
            client_log::exit(1);
        }
        return;
    }
    // `server start` is the canonical spelling for the existing foreground
    // headless owner. Keep startup in the established Args/run_server path so
    // lifecycle aliases cannot drift into a second server launcher.
    rewrite_server_start(&mut raw_args);
    if is_cli_invocation(&raw_args) {
        discard_provider_secret_environment();
        client_log::exit(cli::run(&raw_args, &usage()));
    }
    let args = parse_args(raw_args);
    #[cfg(unix)]
    let provider_token = CapturedProviderToken::capture();
    let provider_workspace_authority = CapturedProviderWorkspaceAuthority::capture();
    let config = config::load();
    let provider = resolve_provider_launch(&args, &config)
        .unwrap_or_else(|error| usage_exit(&error.to_string()));
    #[cfg(unix)]
    let provider = provider
        .map(|launch| -> anyhow::Result<_> {
            validate_provider_process_args(&args)?;
            let connect_external = launch.enables_client_machine_connect();
            let local_machines =
                if connect_external { config.machines.clone() } else { Vec::new() };
            Ok((
                provider_connector_with_unix_token(launch, provider_token)?,
                local_machines,
                connect_external,
            ))
        })
        .transpose()
        .unwrap_or_else(|error| usage_exit(&error.to_string()));
    let provider_workspace_authority = if provider.is_none() && !args.attach {
        provider_workspace_authority
            .into_authority()
            .unwrap_or_else(|error| usage_exit(&error.to_string()))
    } else {
        None
    };
    #[cfg(not(unix))]
    if provider.is_some() {
        validate_provider_process_args(&args)
            .unwrap_or_else(|error| usage_exit(&error.to_string()));
    }
    #[cfg(unix)]
    let result = match provider {
        Some((provider, local_machines, connect_external)) => {
            run_provider_machine_client(provider, local_machines, connect_external)
        }
        None if args.attach => run_attach(args),
        None => run_server(args, provider_workspace_authority),
    };
    #[cfg(not(unix))]
    let result = match provider {
        Some(_) => Err(anyhow::anyhow!("dynamic machine providers require Unix")),
        None if args.attach => run_attach(args),
        None => run_server(args, provider_workspace_authority),
    };
    if let Err(e) = result {
        crate::client_log::stderr_log!("startup", "cmux-tui: {e}");
        client_log::exit(1);
    }
}

fn run_terminal_host_process(args: &[String]) -> anyhow::Result<()> {
    cmux_tui_core::terminal_host_runtime::isolate_terminal_host_process_fds()?;
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();
    cmux_tui_core::terminal_host_runtime::serve_terminal_host_stdio(args, &mut reader, &mut writer)
}

fn run_attach(args: Args) -> anyhow::Result<()> {
    let socket_path = match args.socket {
        Some(path) => path,
        None => cmux_tui_core::server::try_default_socket_path(&args.session)?,
    };
    let config = config::load();
    let messages = &localization::catalog().attach;
    let terminal = args
        .terminal
        .as_deref()
        .map(|reference| {
            TerminalPublicId::parse(reference.to_string())
                .map_err(|_| anyhow::anyhow!(messages.unknown_terminal(reference)))
        })
        .transpose()?;
    let remote = if terminal.is_some() {
        RemoteSession::connect_for_terminal_attach(&socket_path)?
    } else {
        RemoteSession::connect(&socket_path)?
    };
    let surface_only = if let Some(terminal) = terminal.as_ref() {
        let tree = remote.refresh_tree()?;
        let surface = tree
            .resolve_terminal(terminal)
            .ok_or_else(|| anyhow::anyhow!(messages.unknown_terminal(terminal.as_str())))?;
        if !remote.supports_surface_subscription_filter() {
            anyhow::bail!(messages.filtered_subscription_unavailable);
        }
        remote.scope_events_to_surface(surface)?;
        let tree = remote.refresh_tree()?;
        if tree.resolve_terminal(terminal) != Some(surface) {
            anyhow::bail!(messages.unknown_terminal(terminal.as_str()));
        }
        Some(surface)
    } else {
        None
    };
    run_connected_session_client(
        socket_path,
        args.session,
        config,
        Session::Remote(remote),
        surface_only,
    )
}

#[cfg(unix)]
fn relay_daemon_options(
    endpoints: Vec<String>,
    slots: Vec<String>,
    credentials: Vec<RelayCredentialArg>,
) -> anyhow::Result<Vec<remote_runtime::RelayDaemonOptions>> {
    const MAX_DAEMON_RELAYS: usize = 4;
    if endpoints.len() != slots.len() || endpoints.len() != credentials.len() {
        anyhow::bail!(
            "each relay registration needs one --relay, one --relay-slot, and one relay credential source"
        );
    }
    if endpoints.len() > MAX_DAEMON_RELAYS {
        anyhow::bail!("a daemon supports at most {MAX_DAEMON_RELAYS} relay registrations");
    }
    endpoints
        .into_iter()
        .zip(slots)
        .zip(credentials)
        .map(|((endpoint, slot), credentials)| {
            let credentials = match credentials {
                RelayCredentialArg::File(path) => {
                    cmux_remote::provider::RelayCredentialSource::file(path)
                }
                RelayCredentialArg::Command { program, args } => {
                    cmux_remote::provider::RelayCredentialSource::command(program, args)
                }
            };
            Ok(remote_runtime::RelayDaemonOptions {
                endpoint: endpoint
                    .parse()
                    .map_err(|error| anyhow::anyhow!("invalid relay endpoint: {error}"))?,
                slot,
                credentials,
            })
        })
        .collect()
}

/// Copy the control protocol byte-for-byte between stdio and a local session.
///
/// This is intentionally a transport primitive rather than an SSH feature.
/// `ssh -T machine cmux-tui relay` is one consumer; cloud providers can run
/// the same command through their authenticated process transport.
fn run_relay(args: Args) -> anyhow::Result<()> {
    if args.provider_cli_requested() {
        anyhow::bail!("relay cannot also select a machine provider");
    }
    let socket_path = match args.socket {
        Some(path) => path,
        None => cmux_tui_core::server::try_default_socket_path(&args.session)?,
    };
    let stream = cmux_tui_core::platform::transport::connect(&socket_path).map_err(|error| {
        anyhow::anyhow!("cannot connect relay to session socket {}: {error}", socket_path.display())
    })?;
    let mut reader = stream.try_clone_box()?;
    let mut writer = stream;

    // Provider APIs commonly allocate a PTY. Raw mode prevents echo, newline
    // rewriting, and signal processing from corrupting JSONL protocol bytes.
    let raw_stdio = io::stdin().is_terminal();
    if raw_stdio {
        crossterm::terminal::enable_raw_mode()?;
    }

    let input = std::thread::Builder::new().name("relay-input".into()).spawn(move || {
        let result = io::copy(&mut io::stdin().lock(), &mut writer);
        let _ = writer.shutdown(Shutdown::Write);
        result
    })?;
    let output_result = io::copy(&mut reader, &mut io::stdout().lock());
    let _ = reader.shutdown(Shutdown::Read);
    if raw_stdio {
        let _ = crossterm::terminal::disable_raw_mode();
    }
    output_result?;
    if input.is_finished() {
        input.join().map_err(|_| anyhow::anyhow!("relay input thread panicked"))??;
    }
    Ok(())
}

fn new_mux_generation() -> anyhow::Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|_| anyhow::anyhow!("could not create provider mux generation"))?;
    let mut generation = String::with_capacity(32);
    use std::fmt::Write as _;
    for byte in bytes {
        write!(&mut generation, "{byte:02x}").expect("writing to String cannot fail");
    }
    Ok(generation)
}

#[cfg(target_os = "linux")]
fn take_provider_management_listener() -> anyhow::Result<Option<std::os::unix::net::UnixListener>> {
    use std::os::fd::{FromRawFd, OwnedFd, RawFd};

    const SYSTEMD_FIRST_FD: RawFd = 3;
    const FD_NAME: &str = "cmux-provider-authority";
    let listen_pid = std::env::var("LISTEN_PID").ok();
    let listen_fds = std::env::var("LISTEN_FDS").ok();
    let listen_names = std::env::var("LISTEN_FDNAMES").ok();
    unsafe {
        std::env::remove_var("LISTEN_PID");
        std::env::remove_var("LISTEN_FDS");
        std::env::remove_var("LISTEN_FDNAMES");
    }
    if listen_pid.is_none() && listen_fds.is_none() && listen_names.is_none() {
        return Ok(None);
    }
    let pid = listen_pid
        .as_deref()
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or_else(|| anyhow::anyhow!("invalid systemd LISTEN_PID"))?;
    if pid != std::process::id() {
        anyhow::bail!("systemd listener belongs to a different process");
    }
    if listen_fds.as_deref() != Some("1") || listen_names.as_deref() != Some(FD_NAME) {
        anyhow::bail!("expected exactly one named provider management listener");
    }
    let socket_type = socket_option(SYSTEMD_FIRST_FD, libc::SO_TYPE)?;
    let accepting = socket_option(SYSTEMD_FIRST_FD, libc::SO_ACCEPTCONN)?;
    if socket_type != libc::SOCK_STREAM || accepting != 1 {
        anyhow::bail!("provider management descriptor is not a listening stream socket");
    }
    let flags = unsafe { libc::fcntl(SYSTEMD_FIRST_FD, libc::F_GETFD) };
    if flags < 0
        || unsafe { libc::fcntl(SYSTEMD_FIRST_FD, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0
    {
        return Err(io::Error::last_os_error().into());
    }
    let owned = unsafe { OwnedFd::from_raw_fd(SYSTEMD_FIRST_FD) };
    Ok(Some(std::os::unix::net::UnixListener::from(owned)))
}

#[cfg(target_os = "linux")]
fn socket_option(fd: std::os::fd::RawFd, option: libc::c_int) -> io::Result<libc::c_int> {
    use std::mem::size_of;

    let mut value = 0;
    let mut length = size_of::<libc::c_int>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(fd, libc::SOL_SOCKET, option, (&raw mut value).cast(), &raw mut length)
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != size_of::<libc::c_int>() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid socket option length"));
    }
    Ok(value)
}

struct ServedMuxCleanup {
    mux: Option<Arc<Mux>>,
    socket_path: PathBuf,
}

impl ServedMuxCleanup {
    fn new(mux: Arc<Mux>, socket_path: PathBuf) -> Self {
        Self { mux: Some(mux), socket_path }
    }

    fn disarm(&mut self) {
        self.mux = None;
    }
}

impl Drop for ServedMuxCleanup {
    fn drop(&mut self) {
        if let Some(mux) = self.mux.take() {
            mux.shutdown();
            cmux_tui_core::server::cleanup(&self.socket_path);
        }
    }
}

struct LocalOwnerEventLoop {
    stop: Option<cmux_tui_core::MuxEventReceiver>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl LocalOwnerEventLoop {
    fn finish(mut self) -> anyhow::Result<()> {
        self.stop_and_join()
    }

    #[cfg(test)]
    fn stop_handle(&self) -> cmux_tui_core::MuxEventReceiver {
        self.stop.as_ref().expect("owner event loop is active").clone()
    }

    fn stop_and_join(&mut self) -> anyhow::Result<()> {
        if let Some(stop) = self.stop.take() {
            stop.close();
        }
        self.thread.take().map_or(Ok(()), |thread| {
            thread.join().map_err(|_| anyhow::anyhow!("local owner event loop panicked"))
        })
    }
}

impl Drop for LocalOwnerEventLoop {
    fn drop(&mut self) {
        let _ = self.stop_and_join();
    }
}

fn run_server(
    args: Args,
    provider_workspace_authority: Option<ProviderWorkspaceAuthority>,
) -> anyhow::Result<()> {
    #[cfg(not(unix))]
    reject_unsupported_remote_options(&args)?;
    if args.ephemeral && args.state.is_some() {
        anyhow::bail!("--ephemeral and --state are mutually exclusive");
    }
    #[cfg(target_os = "linux")]
    let provider_management_listener = take_provider_management_listener()?;
    #[cfg(not(target_os = "linux"))]
    let provider_management_listener: Option<()> = None;
    if provider_workspace_authority.is_some() && provider_management_listener.is_some() {
        anyhow::bail!(
            "provider workspace authority cannot use both environment and management socket"
        );
    }
    let config = config::load();
    let ws_addr = args.ws.clone().or(config.server.ws.clone());
    let ws_token = args.ws_token.clone().or(config.server.ws_token.clone());
    // Compute the socket path up front so a normal interactive launch can
    // reuse an existing local session and surface children inherit it.
    let socket_path = match args.socket.clone() {
        Some(path) => path,
        None => cmux_tui_core::server::try_default_socket_path(&args.session)?,
    };
    if args.should_attach_existing(&ws_addr, &ws_token)
        && socket_path.exists()
        && let Ok(remote) = RemoteSession::connect(&socket_path)
    {
        return run_connected_session_client(
            socket_path,
            args.session,
            config,
            Session::Remote(remote),
            None,
        );
    }
    // Plain interactive launches do not host the session themselves: a
    // detached headless owner is started (or reused) so every `cmux` for the
    // same session is an equal client and the session survives any client
    // detaching. Modes whose owner must live in this process (ephemeral
    // state, provider authority, WebSocket/remote serving) keep hosting
    // in-process below, as does `server.detached_owner = false`.
    if detached_owner_launch_applicable(
        &args,
        &config,
        &ws_addr,
        &ws_token,
        provider_workspace_authority.is_some() || provider_management_listener.is_some(),
        interactive_stdio_is_terminal(),
    ) {
        return start_detached_owner_session(args, config, socket_path);
    }

    #[cfg(unix)]
    let (remote_relays, remote_direct_websocket, remote_workspace_http) = if args.remote {
        let relays =
            relay_daemon_options(args.relay_endpoints, args.relay_slots, args.relay_credentials)?;
        let direct_websocket = args
            .remote_ws
            .map(|address| {
                address
                    .parse()
                    .map_err(|error| anyhow::anyhow!("invalid remote WebSocket address: {error}"))
            })
            .transpose()?;
        let workspace_http = args
            .remote_http
            .map(|address| {
                address
                    .parse()
                    .map_err(|error| anyhow::anyhow!("invalid remote HTTP address: {error}"))
            })
            .transpose()?;
        (relays, direct_websocket, workspace_http)
    } else {
        (Vec::new(), None, None)
    };

    let mut surface_options = SurfaceOptions::default();
    config::apply_browser_to_surface_options(&config, &mut surface_options);
    if let Some(term) = args.term {
        surface_options.term = term;
    }
    surface_options.extra_env.push(("CMUX_TUI_SOCKET".into(), socket_path.display().to_string()));
    surface_options.extra_env.push(("CMUX_MUX_SOCKET".into(), socket_path.display().to_string()));
    #[cfg(unix)]
    if args.agent_browser_provider {
        agent_browser_provider::configure_surface_options(&mut surface_options)?;
    }
    if let Some(helper) = agent_hook_install::runtime_helper_path() {
        surface_options
            .extra_env
            .push(("CMUX_TUI_HOOK".into(), helper.to_string_lossy().into_owned()));
    }

    let state_root = if args.ephemeral {
        None
    } else {
        Some(match args.state {
            Some(path) => path,
            None => cmux_tui_core::platform::workspace_state_dir()
                .ok_or_else(|| anyhow::anyhow!("cannot determine durable state directory"))?,
        })
    };
    if let Some(state_root) = state_root.as_deref() {
        surface_options.terminal_host_root = Some(
            cmux_tui_core::terminal_host_runtime::terminal_host_root(state_root, &args.session),
        );
    }
    let provider_management_pending = provider_management_listener.is_some();
    let mux =
        match (state_root.as_deref(), provider_workspace_authority, provider_management_pending) {
            (Some(root), Some(authority), false) => Mux::open_persistent_provider_managed(
                args.session.clone(),
                surface_options,
                root,
                authority,
            ),
            (Some(root), None, true) => Mux::open_persistent_provider_managed_pending(
                args.session.clone(),
                surface_options,
                root,
                new_mux_generation()?,
            ),
            (Some(root), None, false) => {
                Mux::open_persistent(args.session.clone(), surface_options, root)
            }
            (None, Some(authority), false) => {
                Ok(Mux::new_provider_managed(args.session.clone(), surface_options, authority))
            }
            (None, None, true) => Mux::new_provider_managed_pending(
                args.session.clone(),
                surface_options,
                new_mux_generation()?,
            ),
            (None, None, false) => Ok(Mux::new(args.session.clone(), surface_options)),
            (_, Some(_), true) => {
                unreachable!("conflicting provider authority inputs rejected above")
            }
        }
        .map_err(|error| {
            workspace_schema_startup_error(
                error,
                &args.session,
                &socket_path,
                state_root.as_deref(),
            )
        })?;
    // Background mux workers can report reconnect diagnostics before an
    // interactive client attaches. Install the non-terminal sink as soon as
    // the owner mux exists, before serving or adopting clients.
    app::install_mux_diagnostic_logger(&mux);
    // Headless sessions have no host terminal to query, so seed the mux from
    // Ghostty's config before any protocol client can create a surface.
    mux.seed_default_colors_if_no_durable_override(config.terminal_defaults);
    mux.configure_sidebar_plugin(config.sidebar.plugin.clone());
    #[cfg(target_os = "linux")]
    let _provider_management = provider_management_listener
        .map(|listener| cmux_tui_core::provider_management::serve(listener, mux.clone()))
        .transpose()?;
    let owner_event_loop =
        background_owner_reload_completion(args.headless).map(|complete_reload| {
            if complete_reload {
                start_headless_local_owner_event_loop(&mux)
            } else {
                start_local_owner_event_loop(&mux)
            }
        });
    let pending_server = match cmux_tui_core::server::serve_paused(mux.clone(), args.socket.clone())
    {
        Ok(server) => server,
        Err(error) => {
            mux.shutdown();
            return Err(error);
        }
    };

    #[cfg(unix)]
    let remote_runtime = if args.remote {
        let runtime = match remote_runtime::start_daemon_runtime(
            socket_path.clone(),
            remote_runtime::DaemonRuntimeOptions {
                session: args.session.clone(),
                state_dir: args.remote_state_dir,
                link_socket: args.remote_link_socket,
                admin_socket: args.remote_admin_socket,
                direct_websocket: remote_direct_websocket,
                allow_insecure_non_loopback: args.remote_ws_insecure_bind,
                workspace_http: remote_workspace_http,
                relays: remote_relays,
                iroh: args.iroh,
                advertised_routes: args.advertised_routes,
                resume_lease: std::time::Duration::from_secs(args.remote_resume_lease_seconds),
                replaceable_sidecar: false,
            },
        ) {
            Ok(runtime) => runtime,
            Err(error) => {
                mux.shutdown();
                return Err(error);
            }
        };
        crate::client_log::stderr_log!(
            "startup",
            "cmux-tui: remote daemon {}, link {}, admin {}",
            runtime.info().daemon_fingerprint,
            runtime.info().link_socket.display(),
            runtime.info().admin_socket.display()
        );
        for route in &runtime.info().routes {
            crate::client_log::stderr_log!("startup", "cmux-tui: remote route {route}");
        }
        Some(runtime)
    } else {
        None
    };

    let websocket_server = match (|| -> anyhow::Result<_> {
        Ok(match ws_addr {
            Some(addr) => {
                let addr = addr
                    .parse()
                    .map_err(|error| anyhow::anyhow!("invalid WebSocket address: {error}"))?;
                Some(cmux_tui_core::server::serve_websocket(
                    mux.clone(),
                    addr,
                    ws_token,
                    args.ws_insecure_bind,
                )?)
            }
            None => None,
        })
    })() {
        Ok(server) => server,
        Err(error) => {
            #[cfg(unix)]
            if let Some(runtime) = remote_runtime {
                let _ = runtime.shutdown();
            }
            mux.shutdown();
            return Err(error);
        }
    };
    if let Some(server) = &websocket_server {
        crate::client_log::stderr_log!(
            "startup",
            "cmux-tui: WebSocket control at ws://{}",
            server.local_addr()
        );
    }
    let served_socket = pending_server.into_bound_path();
    let mut served_mux_cleanup = ServedMuxCleanup::new(mux.clone(), served_socket);

    let machine_runtime = (config.machine_sidebar.enabled
        || !config.machine_sidebar.create_sources.is_empty()
        || !config.machines.is_empty())
    .then(|| {
        MachineRuntime::with_creation_sources(
            socket_path.clone(),
            config.machines.clone(),
            config.machine_sidebar.create_sources.clone(),
        )
    });
    let result = if args.headless {
        mux.mark_server_lifecycle_ready();
        #[cfg(unix)]
        {
            run_headless(&mux, &socket_path, || {
                remote_runtime
                    .as_ref()
                    .is_some_and(remote_runtime::DaemonRuntimeHandle::is_finished)
            })
        }
        #[cfg(not(unix))]
        {
            run_headless(&mux, &socket_path, || false)
        }
    } else if let Some(runtime) = machine_runtime {
        run_machine_client(runtime, mux.clone())
    } else {
        match RemoteSession::connect(&socket_path)
            .context("connect the interactive client to its session server")
        {
            Ok(remote) => {
                run_tui_with_owner(Session::Remote(remote), args.session, None, Some(mux.clone()))
            }
            Err(error) => Err(error),
        }
    };
    let owner_event_result = owner_event_loop.map_or(Ok(()), LocalOwnerEventLoop::finish);
    #[cfg(unix)]
    let remote_shutdown = remote_runtime.map(|runtime| runtime.shutdown()).transpose();
    #[cfg(unix)]
    {
        let shutdown_result = finish_server_shutdown(
            websocket_server,
            &mux,
            &socket_path,
            remote_shutdown,
            result.and(owner_event_result),
        );
        served_mux_cleanup.disarm();
        drop(served_mux_cleanup);
        shutdown_result
    }
    #[cfg(not(unix))]
    {
        drop(websocket_server);
        mux.shutdown();
        cmux_tui_core::server::cleanup(&socket_path);
        served_mux_cleanup.disarm();
        drop(served_mux_cleanup);
        result.and(owner_event_result)
    }
}

fn dispatch_local_owner_event(event: &cmux_tui_core::MuxEvent, reload: impl FnOnce()) {
    if matches!(event, cmux_tui_core::MuxEvent::ConfigReloadRequested) {
        reload();
    }
}

fn local_owner_reload_events(mux: &Mux) -> cmux_tui_core::MuxEventReceiver {
    mux.subscribe_config_reload()
}

fn background_owner_reload_completion(headless: bool) -> Option<bool> {
    headless.then_some(true)
}

fn start_local_owner_event_loop(mux: &Arc<Mux>) -> LocalOwnerEventLoop {
    start_local_owner_event_loop_with_completion(mux, false)
}

fn start_headless_local_owner_event_loop(mux: &Arc<Mux>) -> LocalOwnerEventLoop {
    start_local_owner_event_loop_with_completion(mux, true)
}

fn start_local_owner_event_loop_with_completion(
    mux: &Arc<Mux>,
    complete_reload: bool,
) -> LocalOwnerEventLoop {
    let weak_mux = Arc::downgrade(mux);
    let events = local_owner_reload_events(mux);
    let stop = events.clone();
    let thread = std::thread::spawn(move || {
        while let Ok(event) = events.recv() {
            let mux = weak_mux.upgrade();
            dispatch_local_owner_event(&event, move || {
                if let Some(mux) = mux {
                    let request = mux.begin_config_reload_application();
                    let config = config::load();
                    session::apply_config_to_local_owner(&mux, &config);
                    if complete_reload {
                        mux.complete_config_reload_application(request);
                    }
                }
            });
        }
    });
    LocalOwnerEventLoop { stop: Some(stop), thread: Some(thread) }
}

#[cfg(unix)]
fn finish_server_shutdown<W, R>(
    websocket_server: Option<W>,
    mux: &Arc<Mux>,
    socket_path: &Path,
    remote_shutdown: anyhow::Result<Option<R>>,
    result: anyhow::Result<()>,
) -> anyhow::Result<()> {
    drop(websocket_server);
    mux.shutdown();
    cmux_tui_core::server::cleanup(socket_path);
    remote_shutdown.map(|_| ())?;
    result
}

#[cfg(not(unix))]
fn reject_unsupported_remote_options(args: &Args) -> anyhow::Result<()> {
    let requested = args.remote
        || args.remote_ws.is_some()
        || args.remote_ws_insecure_bind
        || args.remote_http.is_some()
        || args.remote_state_dir.is_some()
        || args.remote_link_socket.is_some()
        || args.remote_admin_socket.is_some()
        || !args.relay_endpoints.is_empty()
        || !args.relay_slots.is_empty()
        || !args.relay_credentials.is_empty()
        || args.iroh
        || !args.advertised_routes.is_empty();
    if requested {
        anyhow::bail!(
            "remote daemon mode requires Unix sockets and is unsupported on {}",
            std::env::consts::OS
        );
    }
    Ok(())
}

fn run_tui(
    session: Session,
    session_label: String,
    surface_only: Option<cmux_tui_core::SurfaceId>,
) -> anyhow::Result<()> {
    run_tui_with_owner(session, session_label, surface_only, None)
}

fn run_tui_with_owner(
    session: Session,
    session_label: String,
    surface_only: Option<cmux_tui_core::SurfaceId>,
    owner_mux: Option<Arc<Mux>>,
) -> anyhow::Result<()> {
    match run_tui_once(session, session_label, surface_only, owner_mux, None, None)? {
        app::RunOutcome::Quit => Ok(()),
        app::RunOutcome::Machine(_) => {
            anyhow::bail!("machine request returned without a machine runtime")
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SessionClientMode {
    Plain,
    Machines,
}

fn session_client_mode(config: &config::Config) -> SessionClientMode {
    if config.machine_sidebar.enabled
        || !config.machine_sidebar.create_sources.is_empty()
        || !config.machines.is_empty()
    {
        SessionClientMode::Machines
    } else {
        SessionClientMode::Plain
    }
}

fn interactive_stdio_is_terminal() -> bool {
    io::stdin().is_terminal() && io::stdout().is_terminal()
}

/// True when a plain interactive launch should connect through a detached
/// session owner instead of hosting the mux inside this TUI process.
///
/// `provider_owned` covers the modes whose mux must live in this process
/// (provider workspace authority from the environment or a management
/// listener). Ephemeral state is in-memory and dies with its process by
/// contract, so it is never delegated to an owner. Non-terminal stdio keeps
/// the legacy path: the TUI cannot start there, and spawning an owner first
/// would leak it when the client then fails.
fn detached_owner_launch_applicable(
    args: &Args,
    config: &config::Config,
    ws_addr: &Option<String>,
    ws_token: &Option<String>,
    provider_owned: bool,
    stdio_is_terminal: bool,
) -> bool {
    args.should_attach_existing(ws_addr, ws_token)
        && config.server.detached_owner
        && !args.ephemeral
        && !args.agent_browser_provider
        && !provider_owned
        && stdio_is_terminal
}

fn start_detached_owner_session(
    args: Args,
    config: config::Config,
    socket_path: PathBuf,
) -> anyhow::Result<()> {
    let messages = &localization::catalog().local_server;
    let spec = local_owner::OwnerSpec {
        session: args.session.clone(),
        socket: socket_path.clone(),
        socket_is_derived: args.socket.is_none(),
        state: args.state.clone(),
        term: args.term.clone(),
    };
    let deadline = std::time::Instant::now() + local_owner::ENSURE_DEADLINE;
    if let Err(error) = local_owner::ensure_owner(&spec, Some(&args.session), deadline) {
        match error {
            local_owner::EnsureError::Spawn(_error) => {
                anyhow::bail!("{}", messages.owner_spawn_failed())
            }
            local_owner::EnsureError::NotReady => anyhow::bail!("{}", messages.owner_not_ready),
            local_owner::EnsureError::WrongOwner => anyhow::bail!("{}", messages.wrong_owner),
            local_owner::EnsureError::DifferentSession => {
                anyhow::bail!("{}", messages.different_session)
            }
            local_owner::EnsureError::InvalidIdentity => {
                anyhow::bail!("{}", messages.invalid_identity)
            }
            local_owner::EnsureError::UnsupportedProtocol => {
                anyhow::bail!("{}", messages.unsupported_protocol)
            }
        }
    }
    let remote = RemoteSession::connect(&socket_path)
        .context("connect the interactive client to its detached session owner")?;
    run_connected_session_client(socket_path, args.session, config, Session::Remote(remote), None)
}

fn run_connected_session_client(
    socket_path: PathBuf,
    session_label: String,
    config: config::Config,
    session: Session,
    surface_only: Option<cmux_tui_core::SurfaceId>,
) -> anyhow::Result<()> {
    if surface_only.is_some() {
        return run_tui(session, session_label, surface_only);
    }
    match session_client_mode(&config) {
        SessionClientMode::Plain => run_tui(session, session_label, None),
        SessionClientMode::Machines => {
            let runtime = MachineRuntime::with_creation_sources(
                socket_path,
                config.machines,
                config.machine_sidebar.create_sources,
            );
            run_machine_client_with_initial(runtime, session, None)
        }
    }
}

fn run_machine_client(runtime: MachineRuntime, owner_mux: Arc<Mux>) -> anyhow::Result<()> {
    let active = runtime.initial_key();
    let connections = MachineConnectionHub::new(runtime.connection_connectors());
    let session = connections.connect(active)?;
    run_machine_client_with_hub(runtime, session, connections, Some(owner_mux))
}

fn run_machine_client_with_initial(
    runtime: MachineRuntime,
    session: Session,
    active_lease: Option<Box<dyn MachineConnectionLease>>,
) -> anyhow::Result<()> {
    let active = runtime.initial_key();
    let connections = MachineConnectionHub::new(runtime.connection_connectors());
    connections
        .insert_ready(active, MachineConnection { session: session.clone(), _lease: active_lease });
    run_machine_client_with_hub(runtime, session, connections, None)
}

fn run_machine_client_with_hub(
    runtime: MachineRuntime,
    session: Session,
    connections: MachineConnectionHub,
    owner_mux: Option<Arc<Mux>>,
) -> anyhow::Result<()> {
    let active = runtime.initial_key();
    let label = runtime.name(active).unwrap_or("machine").to_string();
    let mut machine_ui = runtime.ui_state(active);
    machine_ui.set_connection_phases(connections.phases());
    connections.note_presented(Some(active));
    let controller: Box<dyn MachineController> =
        Box::new(StaticMachineController { runtime, active, connections, pending: None });
    match run_tui_once(session, label, None, owner_mux, Some(machine_ui), Some(controller))? {
        app::RunOutcome::Quit => Ok(()),
        app::RunOutcome::Machine(_) => {
            anyhow::bail!("machine request escaped its in-place controller")
        }
    }
}

struct StaticMachineController {
    runtime: MachineRuntime,
    active: machine::MachineKey,
    connections: MachineConnectionHub,
    pending: Option<machine::MachineKey>,
}

impl MachineController for StaticMachineController {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        match request {
            MachineRequest::Switch(machine) => self.switch(machine),
            MachineRequest::Connect { target, route: MachineConnectRoute::Local } => {
                let machine = self.runtime.connect_machine(&target)?;
                self.register(machine)?;
                self.switch(machine)
            }
            MachineRequest::Connect { route: MachineConnectRoute::Provider, .. } => Ok(self
                .notice(
                    localization::catalog().sidebar.machine_catalog_provider_actions_unsupported,
                )),
            MachineRequest::Create => {
                Ok(self.notice(localization::catalog().sidebar.machine_catalog_create_unsupported))
            }
            MachineRequest::CreateFrom { source_id } => {
                let (machine, name) = self.runtime.create_from(&source_id)?;
                self.register(machine)?;
                let message =
                    format!("{}: {name}", localization::catalog().sidebar.prototype_machine_added);
                Ok(self.notice(message))
            }
            MachineRequest::RenameClientMachine { machine, name } => {
                let name = self.runtime.rename_machine(machine, &name)?;
                let result = MachineActionResult::ui(self.ui_state(self.active));
                Ok(if machine == self.active { result.with_session_label(name) } else { result })
            }
            MachineRequest::SelectProviderScope(_)
            | MachineRequest::InvokeProviderAction { .. }
            | MachineRequest::ReconnectProvider => Ok(self.notice(
                localization::catalog().sidebar.machine_catalog_provider_actions_unsupported,
            )),
            MachineRequest::CreateManagedIsolatedWorkspace(_)
            | MachineRequest::CreateManagedHostWorkspace(_)
            | MachineRequest::RenameManagedMachine { .. }
            | MachineRequest::DeleteManagedMachine { .. }
            | MachineRequest::RestoreManagedMachine { .. }
            | MachineRequest::PurgeManagedMachine { .. }
            | MachineRequest::RenameManagedWorkspace { .. }
            | MachineRequest::DeleteManagedWorkspace { .. }
            | MachineRequest::RestoreManagedWorkspace { .. }
            | MachineRequest::PurgeManagedWorkspace { .. } => {
                Ok(self.notice(localization::catalog().sidebar.managed_workspace_unsupported))
            }
        }
    }

    fn commit_replacement(&mut self, present: bool) -> anyhow::Result<()> {
        let machine = self.pending.take().ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.machine_replacement_target_missing)
        })?;
        if present {
            self.active = machine;
            self.connections.note_presented(Some(machine));
        }
        Ok(())
    }

    fn abort_replacement(&mut self) {
        if let Some(machine) = self.pending.take()
            && machine != self.active
        {
            self.connections.remove(machine);
        }
    }

    fn close(&mut self) {
        self.pending = None;
        self.connections.close();
    }
}

impl StaticMachineController {
    fn switch(&mut self, machine: machine::MachineKey) -> anyhow::Result<MachineActionResult> {
        self.register(machine)?;
        let (session, reused) = self.connections.connect_tracked(machine)?;
        let label = self.runtime.name(machine).unwrap_or("machine").to_string();
        self.pending = Some(machine);
        let ui = self.ui_state(machine);
        Ok(MachineActionResult::replace(ui, session, label).with_reused_session(reused))
    }

    fn notice(&self, notice: impl Into<String>) -> MachineActionResult {
        let mut ui = self.ui_state(self.active);
        ui.notice = Some(notice.into());
        MachineActionResult::ui(ui)
    }

    fn register(&self, machine: machine::MachineKey) -> anyhow::Result<()> {
        let connector = self.runtime.connection_connector(machine).ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.client_machine_unavailable)
        })?;
        self.connections.register(machine, connector);
        Ok(())
    }

    fn ui_state(&self, active: machine::MachineKey) -> MachineUiState {
        let mut ui = self.runtime.ui_state(active);
        ui.set_connection_phases(self.connections.phases());
        ui
    }
}

#[cfg(unix)]
fn run_provider_machine_client(
    connector: Arc<dyn MachineProviderConnector>,
    local_machines: Vec<config::MachineConfig>,
    connect_external: bool,
) -> anyhow::Result<()> {
    let state_root = cmux_tui_core::platform::workspace_state_dir();
    let mut runtime = ProviderMachineController::connect_with(
        connector,
        local_machines,
        connect_external,
        state_root,
    )?;

    let (session, label, machine_ui) = match runtime.open_selected() {
        Ok(opened) => opened,
        Err(error) => runtime.placeholder(initial_provider_connection_notice(
            &localization::catalog().sidebar,
            &error,
        )),
    };
    runtime.sync_connections();
    let controller: Box<dyn MachineController> = Box::new(runtime);
    match run_tui_once(session, label, None, None, Some(machine_ui), Some(controller))? {
        app::RunOutcome::Quit => Ok(()),
        app::RunOutcome::Machine(_) => {
            anyhow::bail!("provider request escaped its in-place controller")
        }
    }
}

fn initial_provider_connection_notice(
    messages: &localization::SidebarMessages,
    error: &dyn std::fmt::Display,
) -> String {
    format!("{}: {error}", messages.initial_machine_connection_failed)
}

fn publish_session_default_colors(
    session: &Session,
    colors: cmux_tui_core::DefaultColors,
    surface_only: Option<cmux_tui_core::SurfaceId>,
) -> anyhow::Result<()> {
    // A scoped attach receives the target terminal's resolved colors through
    // vt-state. Publishing this client's host colors would recolor sibling
    // surfaces and change the session defaults for future terminals.
    if surface_only.is_some() {
        return Ok(());
    }
    match session {
        Session::Local(mux) => {
            mux.seed_default_colors_if_no_durable_override(colors);
            Ok(())
        }
        Session::Remote(remote) => remote.set_default_colors(colors),
    }
}

fn run_tui_once(
    session: Session,
    session_label: String,
    surface_only: Option<cmux_tui_core::SurfaceId>,
    owner_mux: Option<Arc<Mux>>,
    machine_ui: Option<MachineUiState>,
    machine_controller: Option<Box<dyn MachineController>>,
) -> anyhow::Result<app::RunOutcome> {
    crossterm::terminal::enable_raw_mode()?;
    let config = config::load();
    let mut colors = config.terminal_defaults;
    let host_colors = host_colors::probe_default_colors();
    if host_colors.fg.is_some() {
        colors.fg = host_colors.fg;
    }
    if host_colors.bg.is_some() {
        colors.bg = host_colors.bg;
    }
    let color_result = publish_session_default_colors(&session, colors, surface_only);
    let raw_result = crossterm::terminal::disable_raw_mode();
    if let Err(err) = color_result {
        crate::client_log::stderr_log!("startup", "cmux-tui: failed to set default colors: {err}");
    }
    raw_result?;
    app::run_with_machine_updates(
        session,
        session_label,
        colors,
        surface_only,
        owner_mux,
        machine_ui,
        machine_controller,
    )
}

fn run_headless<F>(
    mux: &Arc<Mux>,
    socket_path: &Path,
    remote_runtime_finished: F,
) -> anyhow::Result<()>
where
    F: Fn() -> bool,
{
    crate::client_log::stderr_log!(
        "startup",
        "cmux-tui: headless, control socket at {}",
        socket_path.display()
    );
    // Keep the process alive; the control socket drives everything and
    // the mux reaps exited surfaces itself.
    let events = mux.subscribe();
    loop {
        if shutdown_requested() || mux.daemon_shutdown_requested() {
            break;
        }
        if remote_runtime_finished() {
            break;
        }
        match events.recv_timeout(std::time::Duration::from_millis(250)) {
            Ok(_) | Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                std::thread::park_timeout(std::time::Duration::from_millis(250));
            }
        }
    }
    Ok(())
}

fn usage_exit(msg: &str) -> ! {
    crate::client_log::stderr_log!("startup", "cmux: {msg}\n\n{}", usage());
    client_log::exit(2);
}

#[cfg(all(test, unix))]
mod remote_args_tests {
    use super::*;

    #[test]
    fn daemon_accepts_native_and_durable_object_relay_registrations() {
        let args = parse_args(
            [
                "--headless",
                "--remote",
                "--relay",
                "relay+wss://relay.example",
                "--relay-slot",
                "native-route-key",
                "--relay-ticket-command",
                "native-ticket-command",
                "--relay",
                "relay+do://worker.example",
                "--relay-slot",
                "do-route-key",
                "--relay-ticket-file",
                "/tmp/do-ticket",
            ]
            .map(str::to_string),
        );

        let relays =
            relay_daemon_options(args.relay_endpoints, args.relay_slots, args.relay_credentials)
                .unwrap();
        assert_eq!(relays.len(), 2);
        assert_eq!(relays[0].endpoint.as_str(), "relay+wss://relay.example");
        assert_eq!(relays[1].endpoint.as_str(), "relay+do://worker.example");
    }

    #[test]
    fn daemon_rejects_inline_relay_ticket() {
        const CHILD_ENV: &str = "CMUX_DAEMON_RELAY_TICKET_LOCALE_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("remote_args_tests::daemon_rejects_inline_relay_ticket")
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .env("LC_ALL", "ja_JP.UTF-8")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "Japanese daemon relay-ticket rejection child failed:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        let marker = "inline-daemon-secret-marker";
        let error = parse_args_result(
            [
                "--headless",
                "--remote",
                "--relay",
                "relay+wss://relay.example",
                "--relay-slot",
                "routing-key",
                "--relay-ticket",
                marker,
            ]
            .map(str::to_string),
        )
        .expect_err("inline daemon relay ticket was accepted");
        assert!(!error.contains(marker));
        assert_eq!(
            error,
            localization::catalog_for_locale("ja_JP.UTF-8")
                .remote_client
                .inline_relay_ticket_rejected
        );
    }

    #[test]
    fn inline_relay_ticket_scanner_preserves_command_argument_literals() {
        let args =
            ["--relay-ticket-command", "helper", "--relay-ticket-command-arg", "--relay-ticket"]
                .map(str::to_string);

        assert!(!has_inline_relay_ticket_argument(&args));
    }

    #[test]
    fn remote_state_directory_enables_remote_daemon_mode() {
        let args = parse_args(["--remote-state-dir", "/tmp/cmux-remote-state"].map(str::to_string));

        assert!(args.remote);
        assert_eq!(args.remote_state_dir, Some(PathBuf::from("/tmp/cmux-remote-state")));
    }

    #[test]
    fn remote_http_enables_remote_daemon_mode() {
        let args = parse_args(["--remote-http", "127.0.0.1:8765"].map(str::to_string));

        assert!(args.remote);
        assert_eq!(args.remote_http.as_deref(), Some("127.0.0.1:8765"));
    }

    #[test]
    fn malformed_relay_endpoint_errors_do_not_echo_credentials() {
        let error = relay_daemon_options(
            vec!["relay+wss://dont-leak-me@[".into()],
            vec!["routing-key".into()],
            vec![RelayCredentialArg::File("/tmp/relay-ticket".into())],
        )
        .expect_err("malformed relay endpoint should fail");

        assert!(!error.to_string().contains("dont-leak-me"));
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn args(values: &[&str]) -> Args {
        parse_args_result(values.iter().map(|value| value.to_string())).unwrap()
    }

    #[test]
    fn plain_interactive_launch_uses_a_detached_owner() {
        let config = config::Config::default();
        assert!(config.server.detached_owner);
        assert!(detached_owner_launch_applicable(&args(&[]), &config, &None, &None, false, true));
        assert!(detached_owner_launch_applicable(
            &args(&["--session", "agents", "--state", "/tmp/state"]),
            &config,
            &None,
            &None,
            false,
            true
        ));
    }

    #[test]
    fn in_process_hosting_is_kept_where_the_owner_must_live_here() {
        let config = config::Config::default();
        // Modes excluded by should_attach_existing.
        assert!(!detached_owner_launch_applicable(
            &args(&["--headless"]),
            &config,
            &None,
            &None,
            false,
            true
        ));
        assert!(!detached_owner_launch_applicable(
            &args(&[]),
            &config,
            &Some("127.0.0.1:7681".to_string()),
            &None,
            false,
            true
        ));
        // Ephemeral state is in-memory and dies with its process.
        assert!(!detached_owner_launch_applicable(
            &args(&["--ephemeral"]),
            &config,
            &None,
            &None,
            false,
            true
        ));
        // Provider-owned muxes stay in this process.
        assert!(!detached_owner_launch_applicable(&args(&[]), &config, &None, &None, true, true));
        // Without terminal stdio the TUI cannot start; spawning an owner
        // first would leak it.
        assert!(!detached_owner_launch_applicable(&args(&[]), &config, &None, &None, false, false));
        // Explicit opt-out restores the founding-TUI host.
        let mut opted_out = config;
        opted_out.server.detached_owner = false;
        assert!(!detached_owner_launch_applicable(
            &args(&[]),
            &opted_out,
            &None,
            &None,
            false,
            true
        ));
    }

    #[test]
    fn public_cli_routing_skips_private_process_option_values() {
        let strings =
            |values: &[&str]| values.iter().map(|value| (*value).to_string()).collect::<Vec<_>>();
        assert!(is_cli_invocation(&strings(&["--relay-slot", "server", "workspace", "list",])));
        assert!(!is_cli_invocation(&strings(&["--relay-slot", "routing-key", "--headless",])));
    }

    #[test]
    fn server_start_routing_skips_private_process_option_values() {
        for value in ["--help", "--json", "--jsonl", "--quiet"] {
            let mut values = [
                "server",
                "start",
                "--relay-ticket-command",
                "ticket-helper",
                "--relay-ticket-command-arg",
                value,
            ]
            .map(str::to_string)
            .to_vec();

            rewrite_server_start(&mut values);

            assert_eq!(values[0], "--headless");
            assert_eq!(values.last().map(String::as_str), Some(value));
        }

        let mut quiet = ["server", "start", "--quiet"].map(str::to_string).to_vec();
        rewrite_server_start(&mut quiet);
        assert_eq!(quiet, ["server", "start", "--quiet"]);
    }

    #[test]
    fn startup_scanners_share_option_value_boundaries() {
        for option in STARTUP_VALUE_OPTIONS
            .iter()
            .copied()
            .filter(|option| !matches!(*option, "--relay-ticket" | "--relay-ticket-command-arg"))
        {
            let args = [option, "--help"].map(str::to_string);
            assert!(!is_cli_invocation(&args), "{option} consumed a value boundary");
            assert!(!server_start_has_cli_routing_flag(&args), "{option} routed its value");
        }

        assert!(!has_inline_relay_ticket_argument(
            &["--relay-ticket-command", "helper", "--relay-ticket-command-arg", "--relay-ticket",]
                .map(str::to_string)
        ));
        assert!(!has_inline_relay_ticket_argument(
            &["--machine-provider-command", "provider", "--relay-ticket", "--",]
                .map(str::to_string)
        ));
        assert!(server_start_has_cli_routing_flag(&["--json"].map(str::to_string)));
    }

    #[test]
    fn startup_value_scanner_rejects_missing_values() {
        for option in STARTUP_VALUE_OPTIONS.iter().copied() {
            let args = [option].map(str::to_string);
            assert_eq!(startup_option_value_end(&args, 0), None, "{option} accepted no value");
        }

        for option in ["--socket", "--session", "--machine"] {
            let mut args = [option].map(str::to_string).to_vec();
            rewrite_server_start(&mut args);
            assert_eq!(args, [option].map(str::to_string));
        }
    }

    #[test]
    fn local_owner_event_dispatches_reload_to_the_shared_mutation_path() {
        let applied = std::cell::Cell::new(false);

        dispatch_local_owner_event(&cmux_tui_core::MuxEvent::ConfigReloadRequested, || {
            applied.set(true);
        });

        assert!(applied.get());
    }

    #[test]
    fn local_owner_reload_subscription_ignores_unrelated_event_overflow() {
        let mux = Mux::new("owner-reload-overflow", SurfaceOptions::default());
        let events = local_owner_reload_events(&mux);

        for surface in 0..=4_096 {
            mux.emit(cmux_tui_core::MuxEvent::Bell(surface));
        }
        mux.emit(cmux_tui_core::MuxEvent::ConfigReloadRequested);

        assert!(matches!(events.recv().unwrap(), cmux_tui_core::MuxEvent::ConfigReloadRequested));
        assert!(!events.overflowed());
    }

    #[test]
    fn local_owner_event_loop_stop_wakes_without_a_mux_event() {
        let mux = Arc::new(Mux::new("owner-event-stop", SurfaceOptions::default()));
        let event_loop = start_local_owner_event_loop(&mux);
        let stop = event_loop.stop_handle();
        let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);

        stop.close();
        std::thread::spawn(move || done_tx.send(event_loop.finish()).unwrap());
        let stopped_without_event = match done_rx.recv_timeout(Duration::from_secs(1)) {
            Ok(result) => {
                result.unwrap();
                true
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => false,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                panic!("owner event loop join observer disconnected")
            }
        };
        if !stopped_without_event {
            mux.emit(cmux_tui_core::MuxEvent::ConfigReloadRequested);
            done_rx.recv_timeout(Duration::from_secs(2)).unwrap().unwrap();
        }

        assert!(stopped_without_event, "owner event loop required a mux event to stop");
    }

    #[test]
    fn interactive_owner_event_loop_defers_reload_completion_to_the_app() {
        let mux = Arc::new(Mux::new("interactive-owner-reload", SurfaceOptions::default()));
        let event_loop = start_local_owner_event_loop(&mux);
        let worker_mux = mux.clone();
        let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
        let worker = std::thread::spawn(move || {
            result_tx.send(worker_mux.request_config_reload()).unwrap();
        });

        assert!(matches!(
            result_rx.recv_timeout(Duration::from_millis(100)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        ));
        let request = mux.begin_config_reload_application();
        mux.complete_config_reload_application(request);
        result_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
        worker.join().unwrap();
        event_loop.finish().unwrap();
    }

    #[test]
    fn interactive_owner_uses_only_the_app_reload_path() {
        assert_eq!(background_owner_reload_completion(false), None);
        assert_eq!(background_owner_reload_completion(true), Some(true));
    }

    #[cfg(unix)]
    #[test]
    fn remote_shutdown_failure_still_stops_the_mux_and_removes_the_socket() {
        let socket_path = std::env::temp_dir().join(format!(
            "cmux-remote-shutdown-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::write(&socket_path, b"test socket marker").unwrap();
        let mux = Mux::new("remote-shutdown-failure", SurfaceOptions::default());

        let error = finish_server_shutdown(
            Some(()),
            &mux,
            &socket_path,
            Err::<Option<()>, _>(anyhow::anyhow!("injected remote shutdown failure")),
            Ok(()),
        )
        .unwrap_err()
        .to_string();

        assert!(error.contains("injected remote shutdown failure"), "{error}");
        assert!(mux.daemon_shutdown_requested());
        assert!(!socket_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn normal_server_cleanup_disarms_the_fallback_guard() {
        let socket_path = std::env::temp_dir().join(format!(
            "cmux-normal-shutdown-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::write(&socket_path, b"test socket marker").unwrap();
        let mux = Mux::new("normal-shutdown", SurfaceOptions::default());
        let mut cleanup = ServedMuxCleanup::new(mux.clone(), socket_path.clone());

        finish_server_shutdown(
            Some(()),
            &mux,
            &socket_path,
            Ok::<Option<()>, anyhow::Error>(None),
            Ok(()),
        )
        .unwrap();
        cleanup.disarm();

        assert!(cleanup.mux.is_none());
        assert!(mux.daemon_shutdown_requested());
        assert!(!socket_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn browser_owned_server_accepts_the_private_agent_browser_provider_flag() {
        let parsed = args(&["--headless", "--agent-browser-provider"]);
        assert!(parsed.headless);
        assert!(parsed.agent_browser_provider);
        assert!(!usage().contains("--agent-browser-provider"));
    }

    #[cfg(not(unix))]
    #[test]
    fn browser_owned_server_rejects_the_private_provider_flag() {
        let error =
            parse_args_result(["--headless", "--agent-browser-provider"].map(str::to_string))
                .unwrap_err();
        assert!(error.contains("unsupported"));
    }

    #[cfg(windows)]
    #[test]
    fn recovery_commands_identify_the_powershell_dialect() {
        assert_eq!(shell_prompt(), "PowerShell> ");
        assert_eq!(shell_quote(r"C:\future session.sock"), r"'C:\future session.sock'");
    }

    #[test]
    fn absent_socket_recovery_only_shows_reset_when_supported() {
        let messages = &localization::catalog_for_locale("en_US.UTF-8").startup;
        let state_root = Path::new("/tmp/cmux state");
        let supported = absent_socket_schema_recovery(
            messages,
            "future-session",
            Some(state_root),
            ResetStateRecoverySupport::Supported,
        );
        assert!(supported.contains("no server is listening on this socket"), "{supported}");
        assert!(supported.contains("reset-state"), "{supported}");
        assert!(supported.contains("--state '/tmp/cmux state'"), "{supported}");

        let main_supported = absent_socket_schema_recovery(
            messages,
            "main",
            Some(state_root),
            ResetStateRecoverySupport::Supported,
        );
        assert!(
            main_supported.contains("cmux session 'main' reset-state --state '/tmp/cmux state'"),
            "{main_supported}"
        );

        let unsupported = absent_socket_schema_recovery(
            messages,
            "future-session",
            Some(state_root),
            ResetStateRecoverySupport::Unsupported,
        );
        assert!(unsupported.contains("no server is listening on this socket"), "{unsupported}");
        assert!(unsupported.contains("scoped saved-state reset is not supported"), "{unsupported}");
        assert!(!unsupported.contains("reset-state"), "{unsupported}");
    }

    #[test]
    fn scoped_terminal_attach_does_not_publish_session_default_colors() {
        let mux = Mux::new("scoped-terminal-color-test", SurfaceOptions::default());
        let original = cmux_tui_core::DefaultColors {
            fg: Some(cmux_tui_core::Rgb { r: 1, g: 2, b: 3 }),
            ..Default::default()
        };
        let client = cmux_tui_core::DefaultColors {
            fg: Some(cmux_tui_core::Rgb { r: 4, g: 5, b: 6 }),
            ..Default::default()
        };
        mux.set_default_colors(original);
        let session = Session::Local(mux.clone());

        publish_session_default_colors(&session, client, Some(7)).unwrap();
        assert_eq!(
            mux.default_colors(),
            original,
            "scoped terminal attach must retain the session and sibling tabs' colors"
        );

        publish_session_default_colors(&session, client, None).unwrap();
        assert_eq!(mux.default_colors(), client, "full-session clients still publish their colors");
    }

    #[test]
    fn initial_provider_connection_failure_uses_the_selected_locale() {
        let error = io::Error::other("offline");
        assert_eq!(
            initial_provider_connection_notice(
                &localization::catalog_for_locale("en_US.UTF-8").sidebar,
                &error,
            ),
            "Could not connect: offline"
        );
        assert_eq!(
            initial_provider_connection_notice(
                &localization::catalog_for_locale("ja_JP.UTF-8").sidebar,
                &error,
            ),
            "マシンに接続できませんでした: offline"
        );
    }

    #[test]
    fn static_machine_catalog_notices_use_the_selected_locale() {
        const CHILD_ENV: &str = "CMUX_STATIC_MACHINE_NOTICE_LOCALE_CHILD";
        if std::env::var_os(CHILD_ENV).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("tests::static_machine_catalog_notices_use_the_selected_locale")
                .arg("--exact")
                .arg("--nocapture")
                .env(CHILD_ENV, "1")
                .env("LC_ALL", "ja_JP.UTF-8")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "Japanese static machine notice child failed:\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }

        let runtime = MachineRuntime::new(PathBuf::from("/tmp/static-machine-notice.sock"), vec![]);
        let active = runtime.initial_key();
        let connections = MachineConnectionHub::new(runtime.connection_connectors());
        let mut controller =
            StaticMachineController { runtime, active, connections, pending: None };

        assert_eq!(
            controller.perform(MachineRequest::Create).unwrap().ui.notice.as_deref(),
            Some("このマシンカタログではマシンを作成できません")
        );
        assert_eq!(
            controller
                .perform(MachineRequest::SelectProviderScope("team".into()))
                .unwrap()
                .ui
                .notice
                .as_deref(),
            Some("このマシンカタログにはプロバイダーアクションがありません")
        );
    }

    #[test]
    fn static_machine_creation_does_not_connect_until_selected() {
        let suffix =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let socket = std::env::temp_dir()
            .join(format!("cmux-unselected-machine-{}-{suffix}.sock", std::process::id()));
        let runtime = MachineRuntime::with_creation_sources(
            socket,
            vec![],
            vec![config::MachineCreationSourceConfig {
                id: "docker".into(),
                name: "Docker".into(),
                subtitle: "container prototype".into(),
            }],
        );
        let active = runtime.initial_key();
        let connections = MachineConnectionHub::new(runtime.connection_connectors());
        let mut controller =
            StaticMachineController { runtime, active, connections, pending: None };

        let action =
            controller.perform(MachineRequest::CreateFrom { source_id: "docker".into() }).unwrap();
        let created = action
            .ui
            .snapshot
            .machines
            .iter()
            .find(|machine| machine.id == "prototype:docker:1")
            .unwrap()
            .key;

        assert_eq!(
            action.ui.connection_phase(created),
            machine::MachineConnectionPhase::Disconnected,
            "created machine transport must not open until the row is selected"
        );
        assert!(action.replacement.is_none(), "creation must not replace the active session");
    }

    #[test]
    fn static_machine_controller_retains_committed_connection_leases() {
        use std::sync::atomic::AtomicUsize;

        struct CountedLease(Arc<AtomicUsize>);

        impl Drop for CountedLease {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }

        let dropped = Arc::new(AtomicUsize::new(0));
        let connects = Arc::new(AtomicUsize::new(0));
        let connector = |key: machine::MachineKey| {
            let dropped = Arc::clone(&dropped);
            let connects = Arc::clone(&connects);
            let connector: machine_runtime::MachineConnectFn = Arc::new(move || {
                connects.fetch_add(1, Ordering::SeqCst);
                Ok(MachineConnection {
                    session: Session::Local(Mux::new(
                        format!("machine-hub-{}", key.0),
                        SurfaceOptions::default(),
                    )),
                    _lease: Some(Box::new(CountedLease(Arc::clone(&dropped)))),
                })
            });
            (key, connector)
        };
        let first = machine::MachineKey(1);
        let second = machine::MachineKey(2);
        let connections = MachineConnectionHub::new([connector(first), connector(second)]);

        connections.connect(first).unwrap();
        connections.connect(second).unwrap();
        connections.connect(first).unwrap();
        assert_eq!(
            dropped.load(Ordering::SeqCst),
            0,
            "switching must keep every connected machine lease warm"
        );
        assert_eq!(connects.load(Ordering::SeqCst), 2, "returning to a machine reuses its session");

        connections.close();
        assert_eq!(dropped.load(Ordering::SeqCst), 2, "all leases close with the connection hub");
    }

    #[test]
    fn presented_connection_survives_warm_pool_eviction() {
        use std::sync::atomic::AtomicUsize;

        struct CountedLease(Arc<AtomicUsize>);

        impl Drop for CountedLease {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }

        let dropped = Arc::new(AtomicUsize::new(0));
        let connector = |key: machine::MachineKey| {
            let dropped = Arc::clone(&dropped);
            let connector: machine_runtime::MachineConnectFn = Arc::new(move || {
                Ok(MachineConnection {
                    session: Session::Local(Mux::new(
                        format!("machine-hub-presented-{}", key.0),
                        SurfaceOptions::default(),
                    )),
                    _lease: Some(Box::new(CountedLease(Arc::clone(&dropped)))),
                })
            });
            (key, connector)
        };
        let first = machine::MachineKey(1);
        let second = machine::MachineKey(2);
        let third = machine::MachineKey(3);
        let connections = MachineConnectionHub::with_warm_limit(
            [connector(first), connector(second), connector(third)],
            2,
        );

        // `first` is presented but has the OLDEST use stamp once the others
        // connect - exactly the shape where plain LRU would evict the
        // session still on screen mid-switch.
        connections.connect(first).unwrap();
        connections.note_presented(Some(first));
        connections.connect(second).unwrap();
        connections.connect(third).unwrap();
        assert_eq!(dropped.load(Ordering::SeqCst), 1, "one eviction past the limit");

        let (_, reused) = connections.connect_tracked(first).unwrap();
        assert!(reused, "the presented machine's connection must survive eviction");

        connections.close();
    }

    #[test]
    fn connection_hub_evicts_least_recently_used_beyond_the_warm_limit() {
        use std::sync::atomic::AtomicUsize;

        struct CountedLease(Arc<AtomicUsize>);

        impl Drop for CountedLease {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }

        let dropped = Arc::new(AtomicUsize::new(0));
        let connects = Arc::new(AtomicUsize::new(0));
        let connector = |key: machine::MachineKey| {
            let dropped = Arc::clone(&dropped);
            let connects = Arc::clone(&connects);
            let connector: machine_runtime::MachineConnectFn = Arc::new(move || {
                connects.fetch_add(1, Ordering::SeqCst);
                Ok(MachineConnection {
                    session: Session::Local(Mux::new(
                        format!("machine-hub-lru-{}", key.0),
                        SurfaceOptions::default(),
                    )),
                    _lease: Some(Box::new(CountedLease(Arc::clone(&dropped)))),
                })
            });
            (key, connector)
        };
        let first = machine::MachineKey(1);
        let second = machine::MachineKey(2);
        let third = machine::MachineKey(3);
        let connections = MachineConnectionHub::with_warm_limit(
            [connector(first), connector(second), connector(third)],
            2,
        );

        let (_, reused) = connections.connect_tracked(first).unwrap();
        assert!(!reused, "first connect opens fresh");
        connections.connect(second).unwrap();
        assert_eq!(dropped.load(Ordering::SeqCst), 0, "two warm connections fit the limit");

        connections.connect(third).unwrap();
        assert_eq!(
            dropped.load(Ordering::SeqCst),
            1,
            "a third connection evicts the least recently used one"
        );

        // `second` stayed warm; returning to it is a reuse, not a reconnect.
        let (_, reused) = connections.connect_tracked(second).unwrap();
        assert!(reused, "recently used connections survive eviction");
        assert_eq!(connects.load(Ordering::SeqCst), 3);

        // `first` was evicted back to Disconnected; its connector reconnects.
        let (_, reused) = connections.connect_tracked(first).unwrap();
        assert!(!reused, "evicted machines reconnect through their connector");
        assert_eq!(connects.load(Ordering::SeqCst), 4);
        assert_eq!(dropped.load(Ordering::SeqCst), 2, "reconnecting evicted the next oldest");

        connections.close();
        assert_eq!(dropped.load(Ordering::SeqCst), 4, "all leases close with the connection hub");
    }

    #[cfg(unix)]
    #[test]
    fn unix_provider_uses_the_edge_supplied_bearer() {
        use std::os::unix::net::UnixListener;
        use std::time::{SystemTime, UNIX_EPOCH};

        let suffix = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let socket = std::env::temp_dir()
            .join(format!("cmux-provider-token-{}-{suffix}.sock", std::process::id()));
        let listener = UnixListener::bind(&socket).unwrap();
        let connector = provider_connector_with_unix_token(
            ProviderLaunch::Unix(socket.clone()),
            CapturedProviderToken::from_value(OsString::from("edge-fixed-token")),
        )
        .unwrap();

        let connection = connector.connect().unwrap();
        let (_server, _) = listener.accept().unwrap();
        let (token, control, _) = connection.into_parts();
        assert_eq!(token.expose(), "edge-fixed-token");

        drop(control);
        drop(listener);
        std::fs::remove_file(socket).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn provider_token_errors_never_echo_the_secret() {
        let secret = "do-not-print\nthis-secret";
        let error = parse_provider_token(OsString::from(secret)).unwrap_err().to_string();
        assert_eq!(error, "machine-provider credential is invalid");
        assert!(!error.contains(secret));
        assert!(!error.contains("do-not-print"));
    }

    #[cfg(target_os = "linux")]
    fn initial_environment_contains(needle: &[u8]) -> bool {
        unsafe {
            let mut cursor = environ;
            while !cursor.is_null() && !(*cursor).is_null() {
                if CStr::from_ptr(*cursor)
                    .to_bytes()
                    .windows(needle.len())
                    .any(|window| window == needle)
                {
                    return true;
                }
                cursor = cursor.add(1);
            }
        }
        false
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_provider_authority_process_is_non_dumpable_and_scrubs_env() {
        const CHILD_MARKER: &str = "CMUX_TEST_PROVIDER_DUMPABLE_CHILD";
        const TOKEN: &str = "test-provider-token";
        const AUTHORITY: &str = "provider-workspace-authority-linux-test-00000001";
        if std::env::var_os(CHILD_MARKER).is_some() {
            assert!(initial_environment_contains(TOKEN.as_bytes()));
            assert!(initial_environment_contains(AUTHORITY.as_bytes()));
            harden_provider_secret_process().unwrap();
            let dumpable = unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) };
            assert_eq!(dumpable, 0);
            let authority =
                CapturedProviderWorkspaceAuthority::capture().into_authority().unwrap().unwrap();
            assert_eq!(format!("{authority:?}"), "ProviderWorkspaceAuthority([redacted])");
            remove_secret_environment_variable(MACHINE_PROVIDER_TOKEN_ENV);
            assert!(std::env::var_os(MACHINE_PROVIDER_TOKEN_ENV).is_none());
            assert!(std::env::var_os(PROVIDER_WORKSPACE_AUTHORITY_ENV).is_none());
            assert!(!initial_environment_contains(TOKEN.as_bytes()));
            assert!(!initial_environment_contains(AUTHORITY.as_bytes()));
            match std::fs::read("/proc/self/environ") {
                Ok(process_environment) => {
                    assert!(
                        !process_environment
                            .windows(TOKEN.len())
                            .any(|window| window == TOKEN.as_bytes())
                    );
                    assert!(
                        !process_environment
                            .windows(AUTHORITY.len())
                            .any(|window| window == AUTHORITY.as_bytes())
                    );
                }
                Err(error) => assert_eq!(error.kind(), io::ErrorKind::PermissionDenied),
            }
            return;
        }

        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "tests::linux_provider_authority_process_is_non_dumpable_and_scrubs_env",
                "--nocapture",
            ])
            .env(CHILD_MARKER, "1")
            .env(MACHINE_PROVIDER_TOKEN_ENV, TOKEN)
            .env(PROVIDER_WORKSPACE_AUTHORITY_ENV, AUTHORITY)
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[test]
    fn direct_provider_command_preserves_literal_argv_until_terminator() {
        let parsed = args(&[
            "--machine-provider-command",
            "/opt/provider",
            "--literal",
            "$(touch nope)",
            "--",
            "--term",
            "xterm-direct",
        ]);

        assert_eq!(
            parsed.machine_provider_command,
            Some(vec!["/opt/provider".into(), "--literal".into(), "$(touch nope)".into(),])
        );
        assert_eq!(parsed.term.as_deref(), Some("xterm-direct"));
        assert!(
            parse_args_result(["--machine-provider-command".into(), "provider".into()]).is_err()
        );
        assert!(parse_args_result(["--machine-provider-command".into(), "--".into()]).is_err());
    }

    #[test]
    fn cloud_cli_parses_overrides_and_implies_cloud_mode() {
        let parsed = args(&[
            "--cloud-host",
            "edge.example.com",
            "--cloud-user",
            "lawrence",
            "--cloud-port",
            "2200",
            "--cloud-identity",
            "/tmp/cloud-key",
        ]);

        assert!(parsed.cloud_cli_requested());
        assert_eq!(parsed.cloud_host.as_deref(), Some("edge.example.com"));
        assert_eq!(parsed.cloud_user.as_deref(), Some("lawrence"));
        assert_eq!(parsed.cloud_port, Some(2200));
        assert_eq!(parsed.cloud_identity, Some(PathBuf::from("/tmp/cloud-key")));
        assert!(parse_args_result(["--cloud-port".into(), "0".into()]).is_err());
    }

    #[test]
    fn provider_resolution_keeps_defaults_off_and_applies_cli_over_config() {
        let mut config = config::Config::default();
        assert_eq!(resolve_provider_launch(&args(&[]), &config).unwrap(), None);

        config.machine_provider.cloud.enabled = true;
        config.machine_provider.cloud.host = "configured.example.com".into();
        config.machine_provider.cloud.user = Some("configured-user".into());
        config.machine_provider.cloud.port = Some(2222);
        config.machine_provider.cloud.identity_file = Some(PathBuf::from("/configured-key"));
        assert_eq!(
            resolve_provider_launch(&args(&[]), &config).unwrap(),
            Some(ProviderLaunch::Cloud(CloudLaunch {
                host: "configured.example.com".into(),
                user: Some("configured-user".into()),
                port: Some(2222),
                identity_file: Some(PathBuf::from("/configured-key")),
            }))
        );
        assert_eq!(
            resolve_provider_launch(
                &args(&["--cloud", "--cloud-host", "cli.example.com", "--cloud-port", "2200",]),
                &config,
            )
            .unwrap(),
            Some(ProviderLaunch::Cloud(CloudLaunch {
                host: "cli.example.com".into(),
                user: Some("configured-user".into()),
                port: Some(2200),
                identity_file: Some(PathBuf::from("/configured-key")),
            }))
        );

        assert_eq!(
            resolve_provider_launch(&args(&["--machine-provider", "/tmp/provider.sock"]), &config)
                .unwrap(),
            Some(ProviderLaunch::Unix(PathBuf::from("/tmp/provider.sock")))
        );

        assert_eq!(
            resolve_provider_launch(
                &args(&["--machine-provider-command", "/opt/provider", "--profile", "dev", "--",]),
                &config,
            )
            .unwrap(),
            Some(ProviderLaunch::Command(vec![
                OsString::from("/opt/provider"),
                OsString::from("--profile"),
                OsString::from("dev"),
            ]))
        );
    }

    #[test]
    fn provider_resolution_rejects_conflicts_and_limits_static_overlay() {
        let mut config = config::Config::default();
        let parsed = args(&["--machine-provider", "/tmp/provider.sock", "--cloud"]);
        let error = resolve_provider_launch(&parsed, &config).unwrap_err().to_string();
        assert!(error.contains("choose only one provider mode"), "{error}");

        let parsed = args(&[
            "--machine-provider-command",
            "provider",
            "--",
            "--cloud-host",
            "edge.example.com",
        ]);
        let error = resolve_provider_launch(&parsed, &config).unwrap_err().to_string();
        assert!(error.contains("choose only one provider mode"), "{error}");

        config.machines.push(config::MachineConfig {
            id: "local-agents".into(),
            name: "Local agents".into(),
            subtitle: String::new(),
            target: config::MachineTargetConfig::Unix {
                socket: PathBuf::from("/tmp/local-agents.sock"),
            },
        });
        assert!(matches!(
            resolve_provider_launch(&args(&["--cloud"]), &config).unwrap(),
            Some(ProviderLaunch::Cloud(_))
        ));
        let error =
            resolve_provider_launch(&args(&["--machine-provider", "/tmp/provider.sock"]), &config)
                .unwrap_err()
                .to_string();
        assert!(error.contains("only be combined with the local cloud"), "{error}");
    }

    #[test]
    fn only_local_cloud_launch_enables_ephemeral_machine_connect() {
        assert!(
            ProviderLaunch::Cloud(CloudLaunch {
                host: "cmux.cloud".into(),
                user: None,
                port: None,
                identity_file: None,
            })
            .enables_client_machine_connect()
        );
        assert!(
            !ProviderLaunch::Unix(PathBuf::from("/tmp/provider.sock"))
                .enables_client_machine_connect()
        );
        assert!(
            !ProviderLaunch::Command(vec![OsString::from("provider")])
                .enables_client_machine_connect()
        );
    }

    #[test]
    fn startup_help_lists_all_provider_entrypoints() {
        let usage = usage();
        assert!(usage.contains("--machine-provider <path>"));
        assert!(usage.contains("--machine-provider-command <program> [arg ...] --"));
        assert!(usage.contains("--cloud"));
        assert!(usage.contains("--cloud-identity"));
    }

    #[test]
    fn startup_help_localizes_the_machine_agent_entrypoint() {
        let english = usage_for_platform(localization::catalog_for_locale("en_US.UTF-8"), true);
        assert!(english.contains("cmux machine-agent"));
        assert!(english.contains("Share one local session through the configured host"));
        assert!(english.contains("cmux server <ACTION>"));
        assert!(english.contains("Stop a replaceable SSH sidecar explicitly"));
        let japanese = usage_for_platform(localization::catalog_for_locale("ja_JP.UTF-8"), true);
        assert!(japanese.contains("cmux machine-agent"));
        assert!(japanese.contains("設定したホスト経由でローカルセッションを共有"));
        assert!(japanese.contains("cmux server <操作>"));
        assert!(japanese.contains("置換可能な SSH サイドカーを明示的に停止"));
        assert!(!japanese.contains("Share one local session"));
        assert!(!japanese.contains("Stop authenticated remote access explicitly"));
    }

    #[test]
    fn startup_help_omits_machine_agent_on_unsupported_platforms() {
        let english = localization::catalog_for_locale("en_US.UTF-8");
        let usage = usage_for_platform(english, false);
        assert!(!usage.contains("machine-agent"));
        assert!(usage.contains("cmux relay"));
        assert!(!usage.contains("cmux-tui"));
        assert!(!usage.lines().any(|line| !line.is_empty() && line.trim().is_empty()));
    }

    #[test]
    fn old_single_target_attach_flag_is_rejected() {
        let removed = ["--sur", "face"].concat();
        assert!(parse_args_result([removed.clone(), "s:abc123".into()]).is_err());
        assert!(parse_args_result(["attach".into(), removed, "s:abc123".into()]).is_err());
    }

    #[test]
    fn terminal_attach_is_scoped_to_attach_mode() {
        let terminal = "term_0123456789abcdef0123456789abcdef";
        let parsed = args(&["attach", "--session", "agents", "--terminal", terminal]);
        assert!(parsed.attach);
        assert_eq!(parsed.session, "agents");
        assert_eq!(parsed.terminal.as_deref(), Some(terminal));
        assert!(parse_args_result(["--terminal".into(), terminal.into()]).is_err());
        assert!(parse_args_result(["attach".into(), "--terminal".into()]).is_err());
    }

    #[test]
    fn attach_verb_can_follow_global_startup_options() {
        let parsed = args(&["--session", "agents", "attach"]);
        assert!(parsed.attach);
        assert_eq!(parsed.session, "agents");
    }

    #[test]
    fn startup_help_stays_focused_on_process_modes() {
        let english = usage_for_platform(localization::catalog_for_locale("en_US.UTF-8"), true);
        assert!(english.contains("cmux <scope> --help"));
        assert!(english.contains("--terminal <id>"));
        assert!(!english.contains("cmux-tui"));
        assert!(!english.contains("KEYS"));
        assert!(!english.contains("CLI VERBS"));

        let japanese = usage_for_platform(localization::catalog_for_locale("ja_JP.UTF-8"), true);
        assert!(japanese.contains("cmux <scope> --help"));
        assert!(!japanese.contains("cmux-tui"));
        assert!(!japanese.contains("KEYS"));
    }

    #[test]
    fn provider_mode_rejects_server_and_attach_options_before_connecting() {
        let parsed = args(&[
            "attach",
            "--cloud",
            "--session",
            "agents",
            "--socket",
            "/tmp/session.sock",
            "--headless",
            "--ws",
            "127.0.0.1:7681",
            "--ws-token",
            "secret",
            "--ws-insecure-bind",
            "--remote-ws",
            "127.0.0.1:8443",
            "--term",
            "xterm-direct",
        ]);

        let error = validate_provider_process_args(&parsed).unwrap_err().to_string();
        for conflict in [
            "attach",
            "--session",
            "--socket",
            "--headless",
            "--ws",
            "--ws-token",
            "--ws-insecure-bind",
            "remote daemon options",
            "--term",
        ] {
            assert!(error.contains(conflict), "missing {conflict:?} in {error:?}");
        }
    }

    #[test]
    fn existing_session_reuse_preserves_machine_client_mode() {
        let mut config = config::Config::default();
        assert_eq!(session_client_mode(&config), SessionClientMode::Plain);

        config.machine_sidebar.enabled = true;
        assert_eq!(session_client_mode(&config), SessionClientMode::Machines);

        config.machine_sidebar.enabled = false;
        config.machines.push(config::MachineConfig {
            id: "build-host".into(),
            name: "Build host".into(),
            subtitle: String::new(),
            target: config::MachineTargetConfig::Unix {
                socket: PathBuf::from("/tmp/build-host.sock"),
            },
        });
        assert_eq!(session_client_mode(&config), SessionClientMode::Machines);
    }
}
