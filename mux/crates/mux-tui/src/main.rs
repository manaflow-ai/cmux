//! cmux-mux: a tmux-like terminal multiplexer TUI.
//!
//! Runs the mux core (workspaces → tabs → panes on real PTYs, terminal
//! state from libghostty-vt) with a Ratatui frontend, and always exposes
//! the JSON control socket so external frontends can attach. `cmux-mux
//! attach` connects the same TUI to an existing (usually headless)
//! session over that socket, which is how detach/reattach works.

mod app;
mod keys;
mod session;
mod ui;

use std::path::PathBuf;
use std::sync::Arc;

use mux_core::{Mux, PaneOptions};
use session::{RemoteSession, Session};

const USAGE: &str = "\
cmux-mux - terminal multiplexer backed by libghostty-vt

USAGE:
  cmux-mux [OPTIONS]           Start a session (TUI + control socket)
  cmux-mux attach [OPTIONS]    Attach to an existing session's socket

OPTIONS:
  --session <name>   Session name (default: main). Determines the socket path.
  --socket <path>    Explicit control socket path.
  --headless         Run only the control socket, no TUI.
  --term <value>     TERM for child shells (default: xterm-256color).
  -h, --help         Show this help.

KEYS (prefix: Ctrl-b)
  c  new tab           n/p  next/prev tab      1-9  select tab
  %  split right       \"  split down          x    kill pane
  h/j/k/l or arrows    move focus              d    quit (attach: detach)
  w  next workspace    W    new workspace
  Ctrl-b  send a literal Ctrl-b
";

struct Args {
    attach: bool,
    session: String,
    socket: Option<PathBuf>,
    headless: bool,
    term: Option<String>,
}

fn parse_args() -> Args {
    let mut out = Args {
        attach: false,
        session: "main".to_string(),
        socket: None,
        headless: false,
        term: None,
    };
    let mut args = std::env::args().skip(1).peekable();
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
                out.socket = Some(
                    args.next().unwrap_or_else(|| usage_exit("--socket needs a value")).into(),
                )
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
    let args = parse_args();
    let result = if args.attach {
        run_attach(args)
    } else {
        run_server(args)
    };
    if let Err(e) = result {
        eprintln!("cmux-mux: {e}");
        std::process::exit(1);
    }
}

fn run_attach(args: Args) -> anyhow::Result<()> {
    let socket_path = args
        .socket
        .unwrap_or_else(|| mux_core::server::default_socket_path(&args.session));
    let remote = RemoteSession::connect(&socket_path)?;
    app::run(Session::Remote(remote), args.session)
}

fn run_server(args: Args) -> anyhow::Result<()> {
    let mut pane_options = PaneOptions::default();
    if let Some(term) = args.term {
        pane_options.term = term;
    }
    // Compute the socket path up front so pane children inherit it.
    let socket_path = args
        .socket
        .unwrap_or_else(|| mux_core::server::default_socket_path(&args.session));
    pane_options
        .extra_env
        .push(("CMUX_MUX_SOCKET".into(), socket_path.display().to_string()));

    let mux = Mux::new(args.session.clone(), pane_options);
    mux_core::server::serve(mux.clone(), Some(socket_path.clone()))?;

    let result = if args.headless {
        run_headless(&mux, &socket_path)
    } else {
        app::run(Session::Local(mux.clone()), args.session)
    };
    mux_core::server::cleanup(&socket_path);
    result
}

fn run_headless(mux: &Arc<Mux>, socket_path: &std::path::Path) -> anyhow::Result<()> {
    eprintln!(
        "cmux-mux: headless, control socket at {}",
        socket_path.display()
    );
    // Keep the process alive; the control socket drives everything. Dead
    // panes still need reaping out of the tree (the TUI does this when
    // attached).
    let events = mux.subscribe();
    loop {
        match events.recv() {
            Ok(mux_core::MuxEvent::PaneExited(id)) => mux.close_pane(id),
            Ok(_) => {}
            Err(_) => std::thread::park(),
        }
    }
}

fn usage_exit(msg: &str) -> ! {
    eprintln!("cmux-mux: {msg}\n\n{USAGE}");
    std::process::exit(2);
}
