//! cmux-tui: a tmux-like terminal multiplexer TUI.
//!
//! Runs the mux core (workspaces → split panes → tabs on real PTYs,
//! terminal state from libghostty-vt) with a Ratatui frontend, and always
//! exposes the JSON control socket so external frontends can attach.
//! `cmux-tui attach` connects the same TUI to an existing (usually
//! headless) session over that socket, which is how detach/reattach works.

mod app;
mod browser_input;
mod cli;
mod client_registration;
mod config;
mod host_colors;
mod keys;
mod layout_undo;
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
    const REMOTE_COMMANDS: &[&str] = &[
        "connect",
        "ssh",
        "forward",
        "rpc",
        "enroll",
        "known-daemons",
        "remote-probe",
        "remote-link",
        "remote-sidecar",
        "remote-stop",
        "install-self",
    ];

    pub fn is_remote_invocation(args: &[String]) -> bool {
        args.first().is_some_and(|argument| REMOTE_COMMANDS.contains(&argument.as_str()))
    }

    pub fn run(_: &[String], _: &str) -> i32 {
        eprintln!(
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
mod ui;

#[cfg(target_os = "linux")]
use std::ffi::CStr;
use std::ffi::OsString;
use std::io::{self, BufRead, BufReader, IsTerminal, Read, Write};
use std::net::Shutdown;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_tui_core::{Mux, RendererSupervisorConfig, StateStore, SurfaceOptions};
use session::{RemoteSession, Session};
use zeroize::Zeroize;

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);
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
}

pub(crate) fn shutdown_requested() -> bool {
    SHUTDOWN_REQUESTED.load(Ordering::Acquire)
}

#[cfg(unix)]
fn install_signal_handlers() -> io::Result<()> {
    unsafe {
        let mut action = std::mem::zeroed::<libc::sigaction>();
        action.sa_sigaction = handle_signal as *const () as libc::sighandler_t;
        if libc::sigemptyset(&mut action.sa_mask) != 0 {
            return Err(io::Error::last_os_error());
        }
        // Termination must interrupt startup and teardown syscalls. In
        // particular, reopening `/dev/tty` can block forever after the host
        // PTY disappears if the handler is installed with SA_RESTART.
        action.sa_flags = 0;
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            if libc::sigaction(signal, &action, std::ptr::null_mut()) != 0 {
                return Err(io::Error::last_os_error());
            }
        }
    }
    Ok(())
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
  cmux daemon [OPTIONS]    Start a headless session and remote daemon
  cmux connect <ROUTE>     Attach through an authenticated remote route
  cmux ssh <HOST>          Bootstrap and attach over direct SSH
  cmux forward <ROUTE>     Forward a workspace TCP service locally
  cmux rpc <ROUTE>         Run workspace coding-agent RPC requests
  cmux enroll <ACTION>     Enroll, approve, list, or revoke devices
  cmux known-daemons       List client-pinned daemon identities and routes
  cmux attach [OPTIONS]    Attach to a session or one terminal
  cmux relay [OPTIONS]     Relay protocol bytes over stdio
  {machine_agent_usage}
  cmux <scope> --help      Discover resource commands

START OPTIONS
  --session <name>   Session name (default: main). Determines the socket path.
  --socket <path>    Explicit control socket path.
  --state-dir <path> Persistent daemon state directory (platform default).
  --app-service-layout
                     Use cmux's environment-independent macOS service paths.
  --recover-state    Archive corrupt session metadata and issue a new identity.
  --restore-v2-state Restore the immutable pre-v3 checkpoint and exit.
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
  --term <value>     TERM for child shells (default: xterm-256color).
  -h, --help         Show this help.
  -V, --version      Print the cmux-tui version.
  --build-id         Print the packaged daemon content fingerprint.

KEYS (prefix: Ctrl-b)
  t  new tab in pane   B    new browser tab    Tab/BackTab  next/prev tab
  1-9  select screen
  %  split right       \"  split down          x/X  close pane/tab
  ,  rename screen     $    rename workspace   c    new screen
  n/p  next/prev screen
  h/j/k/l or arrows    move focus              d    quit (attach: detach)
  w  next workspace    W    new workspace       s    toggle sidebar
  e  toggle sidebar view                       S    focus sidebar
  <  browser back      >    browser forward     r/u  browser reload/edit URL
  Ctrl-b  send a literal Ctrl-b

MOUSE
  Mouse-aware PTYs receive clicks, motion, and wheel events. Hold Shift
  to select text or open the cmux pane menu. Right-click a pane for
  rename/new tab/split/close; right-click a
  workspace-sidebar row or a status-bar screen for rename/close. Click
  tab-bar entries to switch tabs (+ for a new tab), and status-bar
  screen entries to switch screens (+ for a new screen).

CLI VERBS
  identify, ping, set-client-info, list-clients, detach-client, set-client-sizing,
  reload-config, set-window-title, clear-window-title,
  list-workspaces, export-layout, apply-layout, send,
  read-screen, read-scrollback, vt-state, new-tab, new-browser-tab, new-workspace,
  new-screen, split, set-ratio, pane-neighbor, focus-direction,
  swap-pane, zoom-pane, process-info, set-default-colors,
  close-surface, close-pane, close-screen, close-workspace,
  rename-pane, rename-surface, rename-screen, rename-workspace,
  resize-surface, release-surface-size, focus-pane, select-tab, select-screen,
  select-workspace, move-tab, move-workspace, scroll-surface,
  subscribe, attach-surface, wait-for, run, send-key, copy, ids,
  notify, list-agents, report-agent

PLUGIN VERBS (local; no socket protocol command)
  plugin install <git-url> [--name <name>] [--force]
  plugin list [--json]
  plugin use <name>
  plugin use --builtin
  plugin disable
  plugin update <name>
  plugin remove <name>
";

fn usage_for(catalog: &localization::Catalog) -> String {
    usage_for_platform(catalog, cfg!(unix))
}

fn usage_for_platform(catalog: &localization::Catalog, supports_machine_agent: bool) -> String {
    if supports_machine_agent {
        USAGE.replace("  {machine_agent_usage}\n", &format!("  {}\n", catalog.machine_agent.usage))
    } else {
        USAGE.replace("  {machine_agent_usage}\n", "")
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
    state_dir: Option<PathBuf>,
    app_service_layout: bool,
    recover_state: bool,
    restore_v2_state: bool,
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
    let mut out = Args {
        attach: false,
        session: "main".to_string(),
        socket: None,
        state_dir: None,
        app_service_layout: false,
        recover_state: false,
        restore_v2_state: false,
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
    };
    let mut args = args.into_iter().peekable();
    match args.peek().map(|s| s.as_str()) {
        Some("attach") => {
            out.attach = true;
            args.next();
        }
        Some("daemon") => {
            out.remote = true;
            out.headless = true;
            args.next();
        }
        _ => {}
    }
    while let Some(arg) = args.next() {
        match arg.as_str() {
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
            "--state-dir" => {
                out.state_dir = Some(
                    args.next().unwrap_or_else(|| usage_exit("--state-dir needs a value")).into(),
                );
            }
            "--app-service-layout" => out.app_service_layout = true,
            "--recover-state" => out.recover_state = true,
            "--restore-v2-state" => out.restore_v2_state = true,
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
            "--relay-ticket" => {
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
            "-h" | "--help" => {
                print!("{}", usage());
                std::process::exit(0);
            }
            "-V" | "--version" => {
                println!("cmux {}", version_string());
                std::process::exit(0);
            }
            "--build-id" => {
                println!("{}", cmux_tui_core::build_identity::BUILD_ID);
                std::process::exit(0);
            }
            other => usage_exit(&format!("unknown argument {other:?}")),
        }
    }
    if out.attach && (out.recover_state || out.restore_v2_state) {
        usage_exit("state recovery options are only valid for a local daemon session");
    }
    if out.recover_state && out.restore_v2_state {
        usage_exit("--recover-state and --restore-v2-state are mutually exclusive");
    }
    if out.app_service_layout && (out.socket.is_some() || out.state_dir.is_some()) {
        usage_exit("--app-service-layout cannot be combined with --socket or --state-dir");
    }
    out
}

fn version_string() -> String {
    // CI artifact builds stamp the commit so binaries in cloud snapshots are
    // traceable back to a cmux revision; local builds report the crate version.
    match option_env!("CMUX_TUI_BUILD_COMMIT")
        .or(option_env!("CMUX_MUX_BUILD_COMMIT"))
        .or(option_env!("CMUX_TUI_BUILD_FINGERPRINT"))
    {
        Some(commit) => format!("{} ({commit})", env!("CARGO_PKG_VERSION")),
        None => env!("CARGO_PKG_VERSION").to_string(),
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
    if !conflicts.is_empty() {
        anyhow::bail!("machine provider mode cannot be combined with {}", conflicts.join(", "));
    }
    Ok(())
}

fn main() {
    let raw_args = std::env::args().skip(1).collect::<Vec<_>>();
    if let Some(result) = cmux_tui_core::launch_gate_entrypoint(&raw_args) {
        if let Err(error) = result {
            eprintln!("cmux-tui launch gate: {error}");
            std::process::exit(126);
        }
        return;
    }
    install_signal_handlers();
    if raw_args.first().map(|arg| arg.as_str()) == Some("help") {
        cli::print_help(USAGE);
        std::process::exit(0);
    }
    if cli::is_cli_invocation(&raw_args) {
        discard_provider_secret_environment();
        std::process::exit(cli::run(&raw_args, &usage()));
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
        eprintln!("cmux-tui: {e}");
        std::process::exit(1);
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
    let socket_path = resolved_socket_path(&args);
    let remote = RemoteSession::connect(&socket_path)?;
    run_tui(Session::Remote(remote), args.session)
}

fn resolved_socket_path(args: &Args) -> PathBuf {
    args.socket.clone().unwrap_or_else(|| {
        if args.app_service_layout {
            cmux_tui_core::platform::app_service_runtime_dir()
                .join(format!("{}.sock", args.session))
        } else {
            cmux_tui_core::server::default_socket_path(&args.session)
        }
    })
}

fn run_server(args: Args) -> anyhow::Result<()> {
    let mut surface_options = SurfaceOptions::default();
    let config = config::load();
    // Resolve before moving optional argument fields below.
    let socket_path = resolved_socket_path(&args);
    let ws_addr = args.ws.or(config.server.ws.clone());
    let ws_token = args.ws_token.or(config.server.ws_token.clone());
    config::apply_browser_to_surface_options(&config, &mut surface_options);
    if let Some(term) = args.term {
        surface_options.term = term;
    }
    // Surface children inherit the exact service/client socket.
    surface_options.extra_env.push(("CMUX_TUI_SOCKET".into(), socket_path.display().to_string()));
    surface_options.extra_env.push(("CMUX_MUX_SOCKET".into(), socket_path.display().to_string()));

    let app_service_layout = args.app_service_layout;
    let state_store = match (args.state_dir, app_service_layout) {
        (Some(directory), false) => StateStore::new(directory),
        (None, true) => StateStore::new(
            cmux_tui_core::platform::app_service_state_dir()
                .ok_or_else(|| anyhow::anyhow!("native app-service state directory unavailable"))?,
        ),
        (None, false) => StateStore::platform_default()?,
        (Some(_), true) => unreachable!("app-service path conflicts are rejected while parsing"),
    };
    if args.recover_state {
        let recovery = state_store.recover_session(&args.session)?;
        if let Some(path) = recovery.archived_corrupt_state {
            eprintln!("cmux-tui: archived corrupt session metadata at {}", path.display());
        }
    }
    if args.restore_v2_state {
        state_store.restore_version_two_backup(&args.session)?;
        eprintln!("cmux-tui: restored immutable version-2 state for session {:?}", args.session);
        return Ok(());
    }
    let mux = Mux::recover_from_state_store(args.session.clone(), surface_options, &state_store)?;
    if app_service_layout {
        mux.install_renderer_supervisor(RendererSupervisorConfig::bundled(
            mux.daemon_instance_id,
        )?)?;
    }
    // Headless sessions have no host terminal to query, so seed the mux from
    // Ghostty's config before any protocol client can create a surface.
    mux.seed_default_colors_if_no_durable_override(config.terminal_defaults);
    mux.configure_sidebar_plugin(config.sidebar.plugin.clone());
    #[cfg(target_os = "linux")]
    let _provider_management = provider_management_listener
        .map(|listener| cmux_tui_core::provider_management::serve(listener, mux.clone()))
        .transpose()?;
    let websocket_server = match ws_addr {
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
    };
    if let Some(server) = &websocket_server {
        eprintln!("cmux-tui: WebSocket control at ws://{}", server.local_addr());
    }
    cmux_tui_core::server::serve(mux.clone(), Some(socket_path.clone()))?;

    let result = if args.headless {
        run_headless(&mux, &socket_path, app_service_layout)
    } else {
        // The embedded frontend uses the same protocol-v9 authority path as
        // an attached TUI. This prevents in-process PTY writes or legacy
        // smallest-viewer resizes from bypassing daemon leases after migration.
        let remote = RemoteSession::connect(&socket_path)?;
        run_tui(Session::Remote(remote), args.session)
    };

    let machine_runtime = (config.machine_sidebar.enabled || !config.machines.is_empty())
        .then(|| MachineRuntime::new(socket_path.clone(), config.machines.clone()));
    let result = if args.headless {
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
        run_machine_client(runtime)
    } else {
        match RemoteSession::connect(&socket_path)
            .context("connect the interactive client to its session server")
        {
            Ok(remote) => run_tui(Session::Remote(remote), args.session, None),
            Err(error) => Err(error),
        }
    };
    #[cfg(unix)]
    if let Some(runtime) = remote_runtime {
        runtime.shutdown()?;
    }
    drop(websocket_server);
    mux.shutdown();
    cmux_tui_core::server::cleanup(&socket_path);
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
    match run_tui_once(session, session_label, surface_only, None, None)? {
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
    if config.machine_sidebar.enabled || !config.machines.is_empty() {
        SessionClientMode::Machines
    } else {
        SessionClientMode::Plain
    }
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
            let runtime = MachineRuntime::new(socket_path, config.machines);
            run_machine_client_with_initial(runtime, session)
        }
    }
}

fn run_machine_client(mut runtime: MachineRuntime) -> anyhow::Result<()> {
    let active = runtime.initial_key();
    let session = runtime.connect(active)?;
    run_machine_client_with_initial(runtime, session)
}

fn run_machine_client_with_initial(
    runtime: MachineRuntime,
    session: Session,
) -> anyhow::Result<()> {
    let active = runtime.initial_key();
    let label = runtime.name(active).unwrap_or("machine").to_string();
    let machine_ui = MachineUiState::new(runtime.snapshot(active));
    let controller: Box<dyn MachineController> =
        Box::new(StaticMachineController { runtime, active, pending_active: None });
    match run_tui_once(session, label, None, Some(machine_ui), Some(controller))? {
        app::RunOutcome::Quit => Ok(()),
        app::RunOutcome::Machine(_) => {
            anyhow::bail!("machine request escaped its in-place controller")
        }
    }
}

struct StaticMachineController {
    runtime: MachineRuntime,
    active: machine::MachineKey,
    pending_active: Option<machine::MachineKey>,
}

impl MachineController for StaticMachineController {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        match request {
            MachineRequest::Switch(machine) => self.switch(machine),
            MachineRequest::Connect { target, route: MachineConnectRoute::Local } => {
                let machine = self.runtime.connect_machine(&target)?;
                self.switch(machine)
            }
            MachineRequest::Connect { route: MachineConnectRoute::Provider, .. } => Ok(self
                .notice(
                    localization::catalog().sidebar.machine_catalog_provider_actions_unsupported,
                )),
            MachineRequest::Create => {
                Ok(self.notice(localization::catalog().sidebar.machine_catalog_create_unsupported))
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

    fn commit_replacement(&mut self) -> anyhow::Result<()> {
        self.active = self.pending_active.take().ok_or_else(|| {
            anyhow::anyhow!(localization::catalog().sidebar.machine_replacement_target_missing)
        })?;
        Ok(())
    }

    fn abort_replacement(&mut self) {
        self.pending_active = None;
    }
}

impl StaticMachineController {
    fn switch(&mut self, machine: machine::MachineKey) -> anyhow::Result<MachineActionResult> {
        let session = self.runtime.connect(machine)?;
        let label = self.runtime.name(machine).unwrap_or("machine").to_string();
        self.pending_active = Some(machine);
        let ui = MachineUiState::new(self.runtime.snapshot(machine));
        Ok(MachineActionResult::replace(ui, session, label))
    }

    fn notice(&self, notice: impl Into<String>) -> MachineActionResult {
        let mut ui = MachineUiState::new(self.runtime.snapshot(self.active));
        ui.notice = Some(notice.into());
        MachineActionResult::ui(ui)
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
    let controller: Box<dyn MachineController> = Box::new(runtime);
    match run_tui_once(session, label, None, Some(machine_ui), Some(controller))? {
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
        eprintln!("cmux-tui: failed to set default colors: {err}");
    }
    raw_result?;
    app::run_with_machine_updates(
        session,
        session_label,
        colors,
        surface_only,
        machine_ui,
        machine_controller,
    )
}

fn run_headless(
    mux: &Arc<Mux>,
    socket_path: &std::path::Path,
    app_service_layout: bool,
) -> anyhow::Result<()> {
    eprintln!("cmux-tui: headless, control socket at {}", socket_path.display());
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
        if app_service_layout {
            let executable = std::env::current_exe().ok();
            let packaged = executable
                .as_deref()
                .and_then(cmux_tui_core::build_identity::read_packaged_build_id);
            if cmux_tui_core::build_identity::should_retire_for_packaged_build(
                cmux_tui_core::build_identity::BUILD_ID,
                packaged.as_deref(),
                mux.surface_count(),
            ) {
                eprintln!(
                    "cmux-tui: retiring idle backend build {} for packaged build {}",
                    cmux_tui_core::build_identity::BUILD_ID,
                    packaged.as_deref().unwrap_or("unknown")
                );
                break;
            }
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
    eprintln!("cmux: {msg}\n\n{}", usage());
    std::process::exit(2);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(session: &str) -> Args {
        Args {
            attach: false,
            session: session.to_string(),
            socket: None,
            state_dir: None,
            app_service_layout: false,
            recover_state: false,
            restore_v2_state: false,
            headless: true,
            ws: None,
            ws_token: None,
            ws_insecure_bind: false,
            term: None,
        }
    }

    #[test]
    fn app_service_socket_ignores_environment_runtime_roots() {
        let mut args = args("cmux-service-test");
        args.app_service_layout = true;

        assert_eq!(
            resolved_socket_path(&args),
            cmux_tui_core::platform::app_service_runtime_dir().join("cmux-service-test.sock")
        );
    }

    #[test]
    fn explicit_socket_remains_authoritative_outside_service_mode() {
        let mut args = args("ignored");
        args.socket = Some(PathBuf::from("/tmp/explicit.sock"));

        assert_eq!(resolved_socket_path(&args), PathBuf::from("/tmp/explicit.sock"));
    }

    #[test]
    fn version_two_restore_is_an_explicit_local_state_operation() {
        let parsed = parse_args([
            "--session".to_string(),
            "rollback".to_string(),
            "--state-dir".to_string(),
            "/tmp/cmux-state-rollback-test".to_string(),
            "--restore-v2-state".to_string(),
        ]);

        assert_eq!(parsed.session, "rollback");
        assert_eq!(parsed.state_dir, Some(PathBuf::from("/tmp/cmux-state-rollback-test")));
        assert!(parsed.restore_v2_state);
        assert!(!parsed.recover_state);
        assert!(!parsed.attach);
    }
}
