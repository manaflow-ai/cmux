//! cmux-mux: a tmux-like terminal multiplexer TUI.
//!
//! Runs the mux core (workspaces → tabs → panes on real PTYs, terminal
//! state from libghostty-vt) with a Ratatui frontend, and always exposes
//! the JSON control socket so external frontends can attach.

mod app;
mod keys;
mod ui;

use std::sync::Arc;

use mux_core::{Mux, PaneOptions};

const USAGE: &str = "\
cmux-mux - terminal multiplexer backed by libghostty-vt

USAGE:
  cmux-mux [OPTIONS]

OPTIONS:
  --session <name>   Session name (default: main). Determines the socket path.
  --socket <path>    Explicit control socket path.
  --headless         Run only the control socket, no TUI.
  --term <value>     TERM for child shells (default: xterm-256color).
  -h, --help         Show this help.

KEYS (prefix: Ctrl-b)
  c  new tab           n/p  next/prev tab      1-9  select tab
  %  split right       \"  split down          x    kill pane
  h/j/k/l or arrows    move focus              d    quit
  w  next workspace    W    new workspace
  Ctrl-b  send a literal Ctrl-b
";

fn main() {
    let mut session = "main".to_string();
    let mut socket: Option<std::path::PathBuf> = None;
    let mut headless = false;
    let mut term: Option<String> = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--session" => {
                session = args.next().unwrap_or_else(|| usage_exit("--session needs a value"))
            }
            "--socket" => {
                socket = Some(
                    args.next().unwrap_or_else(|| usage_exit("--socket needs a value")).into(),
                )
            }
            "--headless" => headless = true,
            "--term" => term = Some(args.next().unwrap_or_else(|| usage_exit("--term needs a value"))),
            "-h" | "--help" => {
                print!("{USAGE}");
                return;
            }
            other => usage_exit(&format!("unknown argument {other:?}")),
        }
    }

    let mut pane_options = PaneOptions::default();
    if let Some(term) = term {
        pane_options.term = term;
    }
    // Compute the socket path up front so pane children inherit it.
    let socket_path = socket.unwrap_or_else(|| mux_core::server::default_socket_path(&session));
    pane_options
        .extra_env
        .push(("CMUX_MUX_SOCKET".into(), socket_path.display().to_string()));

    let mux = Mux::new(session, pane_options);
    if let Err(e) = mux_core::server::serve(mux.clone(), Some(socket_path.clone())) {
        eprintln!("cmux-mux: {e}");
        std::process::exit(1);
    }

    let result = if headless {
        run_headless(&mux, &socket_path)
    } else {
        app::run(mux.clone(), &socket_path)
    };
    mux_core::server::cleanup(&socket_path);
    if let Err(e) = result {
        eprintln!("cmux-mux: {e}");
        std::process::exit(1);
    }
}

fn run_headless(mux: &Arc<Mux>, socket_path: &std::path::Path) -> anyhow::Result<()> {
    eprintln!(
        "cmux-mux: headless, control socket at {}",
        socket_path.display()
    );
    // Keep the process alive; the control socket drives everything.
    let events = mux.subscribe();
    loop {
        match events.recv() {
            Ok(_) => {}
            Err(_) => std::thread::park(),
        }
    }
}

fn usage_exit(msg: &str) -> ! {
    eprintln!("cmux-mux: {msg}\n\n{USAGE}");
    std::process::exit(2);
}
