//! cmux-mux: a tmux-like terminal multiplexer TUI.
//!
//! Runs the mux core (workspaces → split panes → tabs on real PTYs,
//! terminal state from libghostty-vt) with a Ratatui frontend, and always
//! exposes the JSON control socket so external frontends can attach.
//! `cmux-mux attach` connects the same TUI to an existing (usually
//! headless) session over that socket, which is how detach/reattach works.

mod app;
mod browser_input;
mod cli;
mod config;
mod host_colors;
mod keys;
mod session;
mod ui;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use mux_core::{Mux, SurfaceOptions};
use session::{RemoteSession, Session};

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

extern "C" fn handle_signal(_: libc::c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::Release);
}

pub(crate) fn shutdown_requested() -> bool {
    SHUTDOWN_REQUESTED.load(Ordering::Acquire)
}

fn install_signal_handlers() {
    unsafe {
        libc::signal(libc::SIGTERM, handle_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, handle_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGHUP, handle_signal as *const () as libc::sighandler_t);
    }
}

const USAGE: &str = "\
cmux-mux - terminal multiplexer backed by libghostty-vt

USAGE:
  cmux-mux [OPTIONS]           Start a session (TUI + control socket)
  cmux-mux attach [OPTIONS]    Attach to an existing session's socket
  cmux-mux <verb> [OPTIONS]    Run one control-socket command

OPTIONS:
  --session <name>   Session name (default: main). Determines the socket path.
  --socket <path>    Explicit control socket path.
  --headless         Run only the control socket, no TUI.
  --term <value>     TERM for child shells (default: xterm-256color).
  -h, --help         Show this help.

KEYS (prefix: Ctrl-b)
  c  new tab in pane   B    new browser tab    n/p  next/prev tab
  1-9  select tab
  %  split right       \"  split down          x    close tab
  ,  rename pane       $    rename workspace
  Tab  next screen     S    new screen
  h/j/k/l or arrows    move focus              d    quit (attach: detach)
  w  next workspace    W    new workspace       s    toggle sidebar
  <  browser back      >    browser forward     r/u  browser reload/edit URL
  Ctrl-b  send a literal Ctrl-b

MOUSE
  Right-click a pane for rename/new tab/split/close; right-click a
  sidebar workspace or a status-bar screen for rename/close. Click
  tab-bar entries to switch tabs (+ for a new tab), and status-bar
  screen entries to switch screens (+ for a new screen).

CLI VERBS
  identify, list-workspaces, send, read-screen, vt-state, new-tab,
  new-browser-tab, new-workspace, new-screen, split, set-ratio,
  set-default-colors, close-surface, close-pane, close-screen,
  close-workspace, rename-pane, rename-surface, rename-screen,
  rename-workspace, resize-surface, focus-pane, select-tab,
  select-screen, select-workspace, move-tab, move-workspace,
  scroll-surface, subscribe, attach-surface
";

struct Args {
    attach: bool,
    session: String,
    socket: Option<PathBuf>,
    headless: bool,
    term: Option<String>,
}

fn parse_args(args: impl IntoIterator<Item = String>) -> Args {
    let mut out = Args {
        attach: false,
        session: "main".to_string(),
        socket: None,
        headless: false,
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
                out.session = args.next().unwrap_or_else(|| usage_exit("--session needs a value"))
            }
            "--socket" => {
                out.socket =
                    Some(args.next().unwrap_or_else(|| usage_exit("--socket needs a value")).into())
            }
            "--headless" => out.headless = true,
            "--term" => {
                out.term = Some(args.next().unwrap_or_else(|| usage_exit("--term needs a value")))
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                std::process::exit(0);
            }
            other => usage_exit(&format!("unknown argument {other:?}")),
        }
    }
    out
}

fn main() {
    install_signal_handlers();
    let raw_args = std::env::args().skip(1).collect::<Vec<_>>();
    if raw_args.first().map(|arg| arg.as_str()) == Some("help") {
        print!("{USAGE}");
        std::process::exit(0);
    }
    if cli::is_cli_invocation(&raw_args) {
        std::process::exit(cli::run(&raw_args, USAGE));
    }
    let args = parse_args(raw_args);
    let result = if args.attach { run_attach(args) } else { run_server(args) };
    if let Err(e) = result {
        eprintln!("cmux-mux: {e}");
        std::process::exit(1);
    }
}

fn run_attach(args: Args) -> anyhow::Result<()> {
    let socket_path =
        args.socket.unwrap_or_else(|| mux_core::server::default_socket_path(&args.session));
    let remote = RemoteSession::connect(&socket_path)?;
    run_tui(Session::Remote(remote), args.session)
}

fn run_server(args: Args) -> anyhow::Result<()> {
    let mut surface_options = SurfaceOptions::default();
    let config = config::load();
    surface_options.chrome_binary = config.browser.chrome_binary.clone();
    surface_options.cdp_url = config.browser.cdp_url.clone();
    surface_options.browser_discover = config.browser.discover;
    surface_options.browser_discover_ports = config.browser.discover_ports.clone();
    surface_options.browser_user_data_dir = config.browser.user_data_dir.clone();
    surface_options.browser_ephemeral = config.browser.ephemeral;
    surface_options.browser_max_capture_megapixels = config.browser.max_capture_megapixels;
    surface_options.browser_capture_scale = config.browser.capture_scale;
    if let Some(term) = args.term {
        surface_options.term = term;
    }
    // Compute the socket path up front so surface children inherit it.
    let socket_path =
        args.socket.unwrap_or_else(|| mux_core::server::default_socket_path(&args.session));
    surface_options.extra_env.push(("CMUX_MUX_SOCKET".into(), socket_path.display().to_string()));

    let mux = Mux::new(args.session.clone(), surface_options);
    mux_core::server::serve(mux.clone(), Some(socket_path.clone()))?;

    let result = if args.headless {
        run_headless(&mux, &socket_path)
    } else {
        run_tui(Session::Local(mux.clone()), args.session)
    };
    mux.shutdown();
    mux_core::server::cleanup(&socket_path);
    result
}

fn run_tui(session: Session, session_label: String) -> anyhow::Result<()> {
    crossterm::terminal::enable_raw_mode()?;
    let colors = host_colors::probe_default_colors();
    let color_result = session.set_default_colors(colors);
    let raw_result = crossterm::terminal::disable_raw_mode();
    if let Err(err) = color_result {
        eprintln!("cmux-mux: failed to set default colors: {err}");
    }
    raw_result?;
    app::run(session, session_label)
}

fn run_headless(mux: &Arc<Mux>, socket_path: &std::path::Path) -> anyhow::Result<()> {
    eprintln!("cmux-mux: headless, control socket at {}", socket_path.display());
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
                std::thread::park_timeout(std::time::Duration::from_millis(250))
            }
        }
    }
    Ok(())
}

fn usage_exit(msg: &str) -> ! {
    eprintln!("cmux-mux: {msg}\n\n{USAGE}");
    std::process::exit(2);
}
