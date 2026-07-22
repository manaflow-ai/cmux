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
mod plugin_manager;
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

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_tui_core::{Mux, SurfaceOptions};
use session::{RemoteSession, Session};

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

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

const USAGE: &str = "\
cmux-tui - terminal multiplexer backed by libghostty-vt

USAGE:
  cmux-tui [OPTIONS]           Start a session (TUI + control socket)
  cmux-tui daemon [OPTIONS]    Start a headless session and remote daemon
  cmux-tui connect <ROUTE>     Attach through an authenticated remote route
  cmux-tui ssh <HOST>          Bootstrap and attach over direct SSH
  cmux-tui forward <ROUTE>     Forward a workspace TCP service locally
  cmux-tui rpc <ROUTE>         Run workspace coding-agent RPC requests
  cmux-tui enroll <ACTION>     Enroll, approve, list, or revoke devices
  cmux-tui known-daemons       List client-pinned daemon identities and routes
  cmux-tui attach [OPTIONS]    Attach to an existing session's socket
  cmux-tui <verb> [OPTIONS]    Run one control-socket command
  cmux-tui plugin <subcommand> Manage sidebar plugins locally

OPTIONS:
  --session <name>   Session name (default: main). Determines the socket path.
  --socket <path>    Explicit control socket path.
  --headless         Run only the control socket, no TUI.
  --ws <addr>        Also listen for WebSocket clients (default: off).
  --ws-token <token> Allow a static-token bypass for interactive pairing.
  --ws-insecure-bind Allow a non-loopback WebSocket bind (no TLS; use a proxy).
  --remote          Run the authenticated remote daemon with this session.
  --remote-ws <addr> Listen for direct remote WebSocket links.
  --remote-ws-insecure-bind  Allow plaintext remote WebSocket off loopback.
  --remote-state-dir <path>  Override remote identity and runtime state.
  --remote-link-socket <path> Override the local authenticated link socket.
  --remote-admin-socket <path> Override the owner-only admin socket.
  --remote-resume-lease-seconds <seconds>
                    Retain crashed-client replay state for 1-86400 seconds.
  --relay <url> --relay-slot <slot> --relay-ticket <ticket>
                    Register with a relay; repeat up to four groups.
  --relay-ticket-file <path>  Refresh the relay ticket from a file.
  --relay-ticket-command <program> [--relay-ticket-command-arg <arg>]
                    Refresh the relay ticket from an argv-based command.
  --iroh            Publish an Iroh route for NAT traversal and mobile use.
  --advertise <url> Add a non-secret route hint to enrollment invitations.
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

struct Args {
    attach: bool,
    session: String,
    socket: Option<PathBuf>,
    headless: bool,
    ws: Option<String>,
    ws_token: Option<String>,
    ws_insecure_bind: bool,
    remote: bool,
    remote_ws: Option<String>,
    remote_ws_insecure_bind: bool,
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

enum RelayCredentialArg {
    Ticket(String),
    File(PathBuf),
    Command { program: String, args: Vec<String> },
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
    let mut out = Args {
        attach: false,
        session: "main".to_string(),
        socket: None,
        headless: false,
        ws: None,
        ws_token: None,
        ws_insecure_bind: false,
        remote: false,
        remote_ws: None,
        remote_ws_insecure_bind: false,
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
                out.session = args.next().unwrap_or_else(|| usage_exit("--session needs a value"));
            }
            "--socket" => {
                out.socket = Some(
                    args.next().unwrap_or_else(|| usage_exit("--socket needs a value")).into(),
                );
            }
            "--headless" => out.headless = true,
            "--ws" => {
                out.ws = Some(args.next().unwrap_or_else(|| usage_exit("--ws needs a value")));
            }
            "--ws-token" => {
                out.ws_token =
                    Some(args.next().unwrap_or_else(|| usage_exit("--ws-token needs a value")));
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
            "--remote-state-dir" => {
                out.remote_state_dir = Some(
                    args.next()
                        .unwrap_or_else(|| usage_exit("--remote-state-dir needs a value"))
                        .into(),
                );
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
                out.relay_credentials.push(RelayCredentialArg::Ticket(
                    args.next().unwrap_or_else(|| usage_exit("--relay-ticket needs a value")),
                ));
                out.remote = true;
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
                out.term = Some(args.next().unwrap_or_else(|| usage_exit("--term needs a value")));
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            "-V" | "--version" => {
                println!("cmux-tui {}", version_string());
                std::process::exit(0);
            }
            other => usage_exit(&format!("unknown argument {other:?}")),
        }
    }
    out
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

fn main() {
    install_signal_handlers();
    let raw_args = std::env::args().skip(1).collect::<Vec<_>>();
    if raw_args.first().map(|arg| arg.as_str()) == Some("help") {
        cli::print_help(USAGE);
        std::process::exit(0);
    }
    if remote_cli::is_remote_invocation(&raw_args) {
        std::process::exit(remote_cli::run(&raw_args, USAGE));
    }
    if cli::is_cli_invocation(&raw_args) {
        std::process::exit(cli::run(&raw_args, USAGE));
    }
    let args = parse_args(raw_args);
    let result = if args.attach { run_attach(args) } else { run_server(args) };
    if let Err(e) = result {
        eprintln!("cmux-tui: {e}");
        std::process::exit(1);
    }
}

fn run_attach(args: Args) -> anyhow::Result<()> {
    let socket_path =
        args.socket.unwrap_or_else(|| cmux_tui_core::server::default_socket_path(&args.session));
    let remote = RemoteSession::connect(&socket_path)?;
    run_tui(Session::Remote(remote), args.session)
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
                RelayCredentialArg::Ticket(ticket) => {
                    cmux_remote::provider::RelayCredentialSource::static_ticket(ticket)?
                }
                RelayCredentialArg::File(path) => {
                    cmux_remote::provider::RelayCredentialSource::file(path)
                }
                RelayCredentialArg::Command { program, args } => {
                    cmux_remote::provider::RelayCredentialSource::command(program, args)
                }
            };
            Ok(remote_runtime::RelayDaemonOptions {
                endpoint: endpoint.parse().map_err(|error| {
                    anyhow::anyhow!("invalid relay endpoint {endpoint:?}: {error}")
                })?,
                slot,
                credentials,
            })
        })
        .collect()
}

fn run_server(args: Args) -> anyhow::Result<()> {
    #[cfg(not(unix))]
    reject_unsupported_remote_options(&args)?;

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

    #[cfg(unix)]
    let (remote_relays, remote_direct_websocket) = if args.remote {
        let relays =
            relay_daemon_options(args.relay_endpoints, args.relay_slots, args.relay_credentials)?;
        let direct_websocket = args
            .remote_ws
            .map(|address| {
                address.parse().map_err(|error| {
                    anyhow::anyhow!("invalid remote WebSocket address {address:?}: {error}")
                })
            })
            .transpose()?;
        (relays, direct_websocket)
    } else {
        (Vec::new(), None)
    };

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

    #[cfg(unix)]
    let remote_runtime = if args.remote {
        let runtime = remote_runtime::start_daemon_runtime(
            socket_path.clone(),
            remote_runtime::DaemonRuntimeOptions {
                session: args.session.clone(),
                state_dir: args.remote_state_dir,
                link_socket: args.remote_link_socket,
                admin_socket: args.remote_admin_socket,
                direct_websocket: remote_direct_websocket,
                allow_insecure_non_loopback: args.remote_ws_insecure_bind,
                relays: remote_relays,
                iroh: args.iroh,
                advertised_routes: args.advertised_routes,
                resume_lease: std::time::Duration::from_secs(args.remote_resume_lease_seconds),
                replaceable_sidecar: false,
            },
        )?;
        eprintln!(
            "cmux-tui: remote daemon {}, link {}, admin {}",
            runtime.info().daemon_fingerprint,
            runtime.info().link_socket.display(),
            runtime.info().admin_socket.display()
        );
        for route in &runtime.info().routes {
            eprintln!("cmux-tui: remote route {route}");
        }
        Some(runtime)
    } else {
        None
    };

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
    } else {
        run_tui(Session::Local(mux.clone()), args.session)
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

fn run_tui(session: Session, session_label: String) -> anyhow::Result<()> {
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
    app::run(session, session_label, colors)
}

fn run_headless<F>(
    mux: &Arc<Mux>,
    socket_path: &std::path::Path,
    remote_runtime_finished: F,
) -> anyhow::Result<()>
where
    F: Fn() -> bool,
{
    eprintln!("cmux-tui: headless, control socket at {}", socket_path.display());
    // Keep the process alive; the control socket drives everything and
    // the mux reaps exited surfaces itself.
    let events = mux.subscribe();
    loop {
        if shutdown_requested() {
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
    eprintln!("cmux-tui: {msg}\n\n{USAGE}");
    std::process::exit(2);
}

#[cfg(all(test, unix))]
mod remote_args_tests {
    use super::*;

    #[test]
    fn daemon_accepts_native_and_durable_object_relay_registrations() {
        let args = parse_args(
            [
                "daemon",
                "--relay",
                "relay+wss://relay.example",
                "--relay-slot",
                "native-slot",
                "--relay-ticket",
                "native-ticket",
                "--relay",
                "relay+do://worker.example",
                "--relay-slot",
                "do-slot",
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
}
