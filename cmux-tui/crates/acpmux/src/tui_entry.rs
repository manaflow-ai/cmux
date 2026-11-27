//! Where the CLI's interactive commands open a session: bare `acpmux`, `acpmux attach [S]`,
//! `acpmux new` without `--detach`, and `acpmux chats open K`.
//!
//! acpmux is headless: it holds no terminal UI and links no terminal UI crate (Lawrence,
//! 2026-11-17: "we want to keep acpmux headless"). The ratatui TUI is its own crate, acpmux-tui,
//! which the `cmux` multicall binary links and installs at start ([`install`]), so `cmux acp
//! attach` and the bundle's `acpmux` symlink open it as before. An acpmux with none installed
//! (the standalone `acpmux` the packages ship, a `cargo build -p acpmux`) hands the same session
//! to a `cmux` that carries it, as `cmux acp attach S` on this acpmux's home, and with no `cmux`
//! streams the session as `attach --plain` does.

use crate::client::Client;
use anyhow::Result;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, OnceLock};

/// A terminal UI's entry: open `session` (or the session list when None) on `client`.
pub type Ui = fn(Arc<Client>, Option<String>) -> Pin<Box<dyn Future<Output = Result<()>>>>;

static UI: OnceLock<Ui> = OnceLock::new();

/// Install the terminal UI this process opens sessions in (the `cmux` binary installs
/// acpmux-tui's at start). The first install wins.
pub fn install(ui: Ui) {
    let _ = UI.set(ui);
}

/// Open `session` (or the session list when None) in a terminal UI.
pub async fn run(client: Arc<Client>, session: Option<String>) -> Result<()> {
    if let Some(ui) = UI.get() {
        return ui(client, session).await;
    }
    if let Some(cmux) = handoff_binary() {
        drop(client);
        return handoff(&cmux, session.as_deref());
    }
    match session {
        Some(id) => {
            eprintln!(
                "acpmux: this acpmux is headless (no terminal UI) and no `cmux` with acpmux was found: \
                 streaming the session as `acpmux attach --plain`"
            );
            crate::cli::output::plain_attach(client, &id).await
        }
        None => Err(anyhow::anyhow!(
            "this acpmux is headless (no terminal UI) and no `cmux` with acpmux was found: list sessions with \
             `acpmux ls`, follow one with `acpmux attach --plain NAME`, or open them in cmux \
             (ACPMUX_TUI=/path/to/cmux names the binary)"
        )),
    }
}

/// Set on the handed-off process: a `cmux` that is itself headless never hands back.
const HANDOFF_ENV: &str = "ACPMUX_TUI_HANDOFF";

/// The `cmux` binary that carries the TUI: `ACPMUX_TUI`, else a `cmux` beside this executable
/// (one install, one build), else the first `cmux` on PATH that answers `cmux acp --version`
/// (a cmux client without acpmux, as on a lane VM, does not). Never this executable itself.
fn handoff_binary() -> Option<std::path::PathBuf> {
    pick_handoff(
        std::env::var_os(HANDOFF_ENV).is_some(),
        std::env::var_os("ACPMUX_TUI"),
        std::env::current_exe().ok().as_deref(),
        std::env::var_os("PATH"),
        carries_acpmux,
    )
}

/// Whether `cmux` runs acpmux under `acp` (every cmux that links acpmux installs its TUI).
fn carries_acpmux(cmux: &std::path::Path) -> bool {
    std::process::Command::new(cmux)
        .args(["acp", "--version"])
        .env(HANDOFF_ENV, "1")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// [`handoff_binary`] over its inputs: none inside a handed-off process, else the first existing
/// file of `named`, `exe`'s sibling `cmux`, then each PATH entry's `cmux`, that is not `exe` and
/// that `carries`.
fn pick_handoff(
    handed_off: bool,
    named: Option<std::ffi::OsString>,
    exe: Option<&std::path::Path>,
    path: Option<std::ffi::OsString>,
    carries: impl Fn(&std::path::Path) -> bool,
) -> Option<std::path::PathBuf> {
    use std::path::{Path, PathBuf};
    if handed_off {
        return None;
    }
    let me = exe.and_then(|e| e.canonicalize().ok());
    let usable = |p: &Path| {
        p.is_file() && p.canonicalize().ok().is_some_and(|c| Some(&c) != me.as_ref()) && carries(p)
    };
    let name = if cfg!(windows) { "cmux.exe" } else { "cmux" };
    let sibling = exe.and_then(Path::parent).map(|d| d.join(name));
    let on_path = path
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .map(|d| d.join(name));
    named.map(PathBuf::from).into_iter().chain(sibling).chain(on_path).find(|p| usable(p))
}

/// `cmux acp attach [S]` (every cmux build has `acp`; an older one does not run acpmux under the
/// argv0 `acpmux`), on this process's acpmux home so it reaches the same daemon.
fn handoff(cmux: &std::path::Path, session: Option<&str>) -> Result<()> {
    let mut command = std::process::Command::new(cmux);
    command.env(HANDOFF_ENV, "1").env("ACPMUX_HOME", crate::config::home()).arg("acp");
    if let Some(id) = session {
        command.args(["attach", id]);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        let error = command.exec();
        Err(anyhow::anyhow!("open the terminal UI with {}: {error}", cmux.display()))
    }
    #[cfg(not(unix))]
    {
        let status = command.status()?;
        if status.success() {
            Ok(())
        } else {
            Err(anyhow::anyhow!("{} exited with {status}", cmux.display()))
        }
    }
}

#[cfg(test)]
#[path = "tui_entry_tests.rs"]
mod tests;
