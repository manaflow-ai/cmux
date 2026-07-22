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
mod config;
mod host_colors;
mod keys;
mod localization;
mod machine;
mod machine_provider_client;
#[cfg(unix)]
mod machine_provider_runtime;
mod machine_runtime;
mod plugin_manager;
mod process_diagnostics;
mod pty_input;
mod session;
mod sidebar_files;
mod ui;

use std::ffi::OsString;
use std::io::{self, IsTerminal};
use std::net::Shutdown;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_tui_core::{Mux, SurfaceOptions};
#[cfg(unix)]
use cmux_tui_machine_protocol::BearerToken;
use machine::{MachineActionResult, MachineController, MachineRequest, MachineUiState};
#[cfg(unix)]
use machine_provider_client::{
    CommandProviderConnector, MachineProviderConnector, SshProviderConnector, UnixProviderConnector,
};
#[cfg(unix)]
use machine_provider_runtime::ProviderMachineRuntime;
use machine_runtime::MachineRuntime;
use session::{RemoteSession, Session};

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);
#[cfg(unix)]
const MACHINE_PROVIDER_TOKEN_ENV: &str = "CMUX_MACHINE_PROVIDER_TOKEN";

#[cfg(unix)]
extern "C" fn handle_signal(_: libc::c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::Release);
}

pub(crate) fn shutdown_requested() -> bool {
    SHUTDOWN_REQUESTED.load(Ordering::Acquire)
}

#[cfg(unix)]
fn install_signal_handlers() {
    unsafe {
        libc::signal(libc::SIGTERM, handle_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, handle_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGHUP, handle_signal as *const () as libc::sighandler_t);
    }
}

// No POSIX signals on Windows; Ctrl-C arrives as console input and the
// TUI's normal quit path handles shutdown.
#[cfg(not(unix))]
fn install_signal_handlers() {}

#[cfg(target_os = "linux")]
fn harden_provider_secret_process() -> io::Result<()> {
    if std::env::var_os(MACHINE_PROVIDER_TOKEN_ENV).is_none() {
        return Ok(());
    }
    let result = unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
    if result == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

#[cfg(not(target_os = "linux"))]
fn harden_provider_secret_process() -> io::Result<()> {
    Ok(())
}

const USAGE: &str = "\
cmux-tui - terminal multiplexer backed by libghostty-vt

USAGE:
  cmux-tui [OPTIONS]           Start a session (TUI + control socket)
  cmux-tui attach [OPTIONS]    Attach to an existing session's socket
  cmux-tui relay [OPTIONS]     Relay stdio to a session's socket
  cmux-tui <verb> [OPTIONS]    Run one control-socket command
  cmux-tui plugin <subcommand> Manage sidebar plugins locally

OPTIONS:
  --session <name>   Session name (default: main). Determines the socket path.
  --socket <path>    Explicit control socket path.
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
  --term <value>     TERM for child shells (default: xterm-256color).
  -h, --help         Show this help.
  -V, --version      Print the cmux-tui version.

KEYS (prefix: Ctrl-b)
  t  new tab in pane   B    new browser tab    Alt-n  auto-layout new pane
  Tab/BackTab  next/prev tab
  0-9  select screen
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
  new-screen, new-pane, split, set-ratio, set-split-ratio, pane-neighbor, focus-direction,
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

#[derive(Debug, Clone, PartialEq, Eq)]
struct Args {
    attach: bool,
    session: String,
    socket: Option<PathBuf>,
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
    term: Option<String>,
}

impl Args {
    fn should_attach_existing(&self, ws_addr: &Option<String>, ws_token: &Option<String>) -> bool {
        !self.headless
            && ws_addr.is_none()
            && ws_token.is_none()
            && !self.ws_insecure_bind
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
        term: None,
    };
    let mut args = args.into_iter().peekable();
    if args.peek().map(|s| s.as_str()) == Some("attach") {
        out.attach = true;
        args.next();
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
            "--headless" => out.headless = true,
            "--ws" => {
                out.ws = Some(args.next().ok_or_else(|| "--ws needs a value".to_string())?);
            }
            "--ws-token" => {
                out.ws_token =
                    Some(args.next().ok_or_else(|| "--ws-token needs a value".to_string())?);
            }
            "--ws-insecure-bind" => out.ws_insecure_bind = true,
            "--term" => {
                out.term = Some(args.next().ok_or_else(|| "--term needs a value".to_string())?);
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            "-V" | "--version" => {
                println!("cmux-tui {}", version_string());
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    Ok(out)
}

fn version_string() -> String {
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
    if launch.is_some() && !config.machines.is_empty() {
        anyhow::bail!("a dynamic machine provider cannot be combined with static machines config");
    }
    Ok(launch)
}

#[cfg(unix)]
fn provider_connector(launch: ProviderLaunch) -> anyhow::Result<Arc<dyn MachineProviderConnector>> {
    provider_connector_with_unix_token(launch, std::env::var_os(MACHINE_PROVIDER_TOKEN_ENV))
}

#[cfg(unix)]
fn provider_connector_with_unix_token(
    launch: ProviderLaunch,
    unix_token: Option<OsString>,
) -> anyhow::Result<Arc<dyn MachineProviderConnector>> {
    let connector: Arc<dyn MachineProviderConnector> = match launch {
        ProviderLaunch::Unix(socket) => match unix_token {
            Some(token) => {
                Arc::new(UnixProviderConnector::new(socket, parse_provider_token(token)?))
            }
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
    let value = value
        .into_string()
        .map_err(|_| anyhow::anyhow!("machine-provider credential is not valid UTF-8"))?;
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
    if args.term.is_some() {
        conflicts.push("--term");
    }
    if !conflicts.is_empty() {
        anyhow::bail!("machine provider mode cannot be combined with {}", conflicts.join(", "));
    }
    Ok(())
}

fn main() {
    if let Err(error) = harden_provider_secret_process() {
        eprintln!("cmux-tui: cannot protect machine-provider credentials: {error}");
        std::process::exit(1);
    }
    install_signal_handlers();
    let raw_args = std::env::args().skip(1).collect::<Vec<_>>();
    if raw_args.first().map(|arg| arg.as_str()) == Some("help") {
        cli::print_help(USAGE);
        std::process::exit(0);
    }
    if raw_args.first().map(|arg| arg.as_str()) == Some("relay") {
        let args = parse_args(raw_args.into_iter().skip(1));
        if let Err(error) = run_relay(args) {
            eprintln!("cmux-tui: {error}");
            std::process::exit(1);
        }
        return;
    }
    if cli::is_cli_invocation(&raw_args) {
        std::process::exit(cli::run(&raw_args, USAGE));
    }
    let args = parse_args(raw_args);
    let provider = resolve_provider_launch(&args, &config::load())
        .unwrap_or_else(|error| usage_exit(&error.to_string()));
    #[cfg(unix)]
    let provider = provider
        .map(|launch| {
            validate_provider_process_args(&args)?;
            provider_connector(launch)
        })
        .transpose()
        .unwrap_or_else(|error| usage_exit(&error.to_string()));
    #[cfg(unix)]
    if provider.is_some() {
        // The connector owns its parsed token now. Remove the inherited copy
        // before any worker or provider subprocess can inherit it.
        unsafe { std::env::remove_var(MACHINE_PROVIDER_TOKEN_ENV) };
    }
    #[cfg(not(unix))]
    if provider.is_some() {
        validate_provider_process_args(&args)
            .unwrap_or_else(|error| usage_exit(&error.to_string()));
    }
    #[cfg(unix)]
    let result = match provider {
        Some(provider) => run_provider_machine_client(provider),
        None if args.attach => run_attach(args),
        None => run_server(args),
    };
    #[cfg(not(unix))]
    let result = match provider {
        Some(_) => Err(anyhow::anyhow!("dynamic machine providers require Unix")),
        None if args.attach => run_attach(args),
        None => run_server(args),
    };
    if let Err(e) = result {
        eprintln!("cmux-tui: {e}");
        std::process::exit(1);
    }
}

fn run_attach(args: Args) -> anyhow::Result<()> {
    let socket_path =
        args.socket.unwrap_or_else(|| cmux_tui_core::server::default_socket_path(&args.session));
    let config = config::load();
    if config.machine_sidebar.enabled || !config.machines.is_empty() {
        return run_machine_client(MachineRuntime::new(socket_path, config.machines));
    }
    let remote = RemoteSession::connect(&socket_path)?;
    run_tui(Session::Remote(remote), args.session)
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
    let socket_path =
        args.socket.unwrap_or_else(|| cmux_tui_core::server::default_socket_path(&args.session));
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

fn run_server(args: Args) -> anyhow::Result<()> {
    let config = config::load();
    let ws_addr = args.ws.clone().or(config.server.ws.clone());
    let ws_token = args.ws_token.clone().or(config.server.ws_token.clone());
    // Compute the socket path up front so a normal interactive launch can
    // reuse an existing local session and surface children inherit it.
    let socket_path = args
        .socket
        .clone()
        .unwrap_or_else(|| cmux_tui_core::server::default_socket_path(&args.session));
    if args.should_attach_existing(&ws_addr, &ws_token)
        && socket_path.exists()
        && let Ok(remote) = RemoteSession::connect(&socket_path)
    {
        return run_tui(Session::Remote(remote), args.session);
    }

    let mut surface_options = SurfaceOptions::default();
    config::apply_browser_to_surface_options(&config, &mut surface_options);
    if let Some(term) = args.term {
        surface_options.term = term;
    }
    surface_options.extra_env.push(("CMUX_TUI_SOCKET".into(), socket_path.display().to_string()));
    surface_options.extra_env.push(("CMUX_MUX_SOCKET".into(), socket_path.display().to_string()));

    let mux = Mux::new(args.session.clone(), surface_options);
    // Headless sessions have no host terminal to query, so seed the mux from
    // Ghostty's config before any protocol client can create a surface.
    mux.set_default_colors(config.terminal_defaults);
    mux.configure_sidebar_plugin(config.sidebar.plugin.clone());
    let websocket_server = match ws_addr {
        Some(addr) => {
            let addr = addr
                .parse()
                .map_err(|error| anyhow::anyhow!("invalid WebSocket address {addr:?}: {error}"))?;
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

    let machine_runtime = (config.machine_sidebar.enabled || !config.machines.is_empty())
        .then(|| MachineRuntime::new(socket_path.clone(), config.machines.clone()));
    let result = if args.headless {
        run_headless(&mux, &socket_path)
    } else if let Some(runtime) = machine_runtime {
        run_machine_client(runtime)
    } else {
        run_tui(Session::Local(mux.clone()), args.session)
    };
    drop(websocket_server);
    mux.shutdown();
    cmux_tui_core::server::cleanup(&socket_path);
    result
}

fn run_tui(session: Session, session_label: String) -> anyhow::Result<()> {
    match run_tui_once(session, session_label, None, None)? {
        app::RunOutcome::Quit => Ok(()),
        app::RunOutcome::Machine(_) => {
            anyhow::bail!("machine request returned without a machine runtime")
        }
    }
}

fn run_machine_client(mut runtime: MachineRuntime) -> anyhow::Result<()> {
    let active = runtime.initial_key();
    let session = runtime.connect(active)?;
    let label = runtime.name(active).unwrap_or("machine").to_string();
    let machine_ui = MachineUiState::new(runtime.snapshot(active));
    let controller: Box<dyn MachineController> =
        Box::new(StaticMachineController { runtime, active });
    match run_tui_once(session, label, Some(machine_ui), Some(controller))? {
        app::RunOutcome::Quit => Ok(()),
        app::RunOutcome::Machine(_) => {
            anyhow::bail!("machine request escaped its in-place controller")
        }
    }
}

struct StaticMachineController {
    runtime: MachineRuntime,
    active: machine::MachineKey,
}

impl MachineController for StaticMachineController {
    fn perform(&mut self, request: MachineRequest) -> anyhow::Result<MachineActionResult> {
        match request {
            MachineRequest::Switch(machine) => self.switch(machine),
            MachineRequest::Connect(target) => {
                let machine = self.runtime.connect_machine(&target)?;
                self.switch(machine)
            }
            MachineRequest::Create => Ok(self.notice("This machine catalog cannot create VMs")),
            MachineRequest::SelectProviderScope(_)
            | MachineRequest::InvokeProviderAction { .. }
            | MachineRequest::ReconnectProvider => {
                Ok(self.notice("This machine catalog has no provider actions"))
            }
            MachineRequest::CreateManagedIsolatedWorkspace(_)
            | MachineRequest::CreateManagedHostWorkspace(_)
            | MachineRequest::RenameManagedWorkspace { .. }
            | MachineRequest::DeleteManagedWorkspace { .. }
            | MachineRequest::RestoreManagedWorkspace { .. }
            | MachineRequest::PurgeManagedWorkspace { .. } => {
                Ok(self.notice(localization::catalog().sidebar.managed_workspace_unsupported))
            }
        }
    }
}

impl StaticMachineController {
    fn switch(&mut self, machine: machine::MachineKey) -> anyhow::Result<MachineActionResult> {
        let session = self.runtime.connect(machine)?;
        let label = self.runtime.name(machine).unwrap_or("machine").to_string();
        self.active = machine;
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
fn run_provider_machine_client(connector: Arc<dyn MachineProviderConnector>) -> anyhow::Result<()> {
    let mut runtime = ProviderMachineRuntime::connect_with(connector)?;

    let (session, label, machine_ui) = match runtime.open_selected() {
        Ok(opened) => opened,
        Err(error) => runtime.placeholder(format!("Could not connect: {error}")),
    };
    let controller: Box<dyn MachineController> = Box::new(runtime);
    match run_tui_once(session, label, Some(machine_ui), Some(controller))? {
        app::RunOutcome::Quit => Ok(()),
        app::RunOutcome::Machine(_) => {
            anyhow::bail!("provider request escaped its in-place controller")
        }
    }
}

fn run_tui_once(
    session: Session,
    session_label: String,
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
    let color_result = session.set_default_colors(colors);
    let raw_result = crossterm::terminal::disable_raw_mode();
    if let Err(err) = color_result {
        eprintln!("cmux-tui: failed to set default colors: {err}");
    }
    raw_result?;
    app::run_with_machine_updates(session, session_label, colors, machine_ui, machine_controller)
}

fn run_headless(mux: &Arc<Mux>, socket_path: &std::path::Path) -> anyhow::Result<()> {
    eprintln!("cmux-tui: headless, control socket at {}", socket_path.display());
    // Keep the process alive; the control socket drives everything and
    // the mux reaps exited surfaces itself.
    let events = mux.subscribe();
    loop {
        if shutdown_requested() {
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
    eprintln!("cmux-tui: {msg}\n\n{USAGE}");
    std::process::exit(2);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Args {
        parse_args_result(values.iter().map(|value| value.to_string())).unwrap()
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
            Some(OsString::from("edge-fixed-token")),
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
    #[test]
    fn linux_provider_token_process_is_non_dumpable() {
        const CHILD_MARKER: &str = "CMUX_TEST_PROVIDER_DUMPABLE_CHILD";
        if std::env::var_os(CHILD_MARKER).is_some() {
            harden_provider_secret_process().unwrap();
            let dumpable = unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) };
            assert_eq!(dumpable, 0);
            return;
        }

        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "tests::linux_provider_token_process_is_non_dumpable", "--nocapture"])
            .env(CHILD_MARKER, "1")
            .env(MACHINE_PROVIDER_TOKEN_ENV, "test-provider-token")
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
    fn provider_resolution_rejects_incompatible_explicit_modes() {
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
        let error = resolve_provider_launch(&args(&["--cloud"]), &config).unwrap_err().to_string();
        assert!(error.contains("cannot be combined with static machines"), "{error}");
    }

    #[test]
    fn startup_help_lists_all_provider_entrypoints() {
        assert!(USAGE.contains("--machine-provider <path>"));
        assert!(USAGE.contains("--machine-provider-command <program> [arg ...] --"));
        assert!(USAGE.contains("--cloud"));
        assert!(USAGE.contains("--cloud-identity"));
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
            "--term",
        ] {
            assert!(error.contains(conflict), "missing {conflict:?} in {error:?}");
        }
    }
}
