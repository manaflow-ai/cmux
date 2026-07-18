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
mod plugin_manager;
mod pty_input;
mod session;
mod sidebar_files;
mod ui;

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_tui_core::{Mux, RendererSupervisorConfig, StateStore, SurfaceOptions};
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
  cmux-tui attach [OPTIONS]    Attach to an existing session's socket
  cmux-tui <verb> [OPTIONS]    Run one control-socket command
  cmux-tui plugin <subcommand> Manage sidebar plugins locally

OPTIONS:
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
    term: Option<String>,
}

fn parse_args(args: impl IntoIterator<Item = String>) -> Args {
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
                out.session = args.next().unwrap_or_else(|| usage_exit("--session needs a value"));
            }
            "--socket" => {
                out.socket = Some(
                    args.next().unwrap_or_else(|| usage_exit("--socket needs a value")).into(),
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
                out.ws = Some(args.next().unwrap_or_else(|| usage_exit("--ws needs a value")));
            }
            "--ws-token" => {
                out.ws_token =
                    Some(args.next().unwrap_or_else(|| usage_exit("--ws-token needs a value")));
            }
            "--ws-insecure-bind" => out.ws_insecure_bind = true,
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

    let result = if args.headless {
        run_headless(&mux, &socket_path, app_service_layout)
    } else {
        // The embedded frontend uses the same protocol-v9 authority path as
        // an attached TUI. This prevents in-process PTY writes or legacy
        // smallest-viewer resizes from bypassing daemon leases after migration.
        let remote = RemoteSession::connect(&socket_path)?;
        run_tui(Session::Remote(remote), args.session)
    };
    drop(websocket_server);
    mux.shutdown();
    cmux_tui_core::server::cleanup(&socket_path);
    result
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
        if shutdown_requested() {
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
    eprintln!("cmux-tui: {msg}\n\n{USAGE}");
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
