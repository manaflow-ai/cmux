//! Where the CLI's interactive commands open a session: bare `acpmux`, `acpmux attach [S]`,
//! `acpmux new` without `--detach`, and `acpmux chats open K`.
//!
//! acpmux is headless: its ratatui TUI (`src/tui/`) builds only with the `tui` feature, which is
//! off by default. The `cmux` multicall binary turns it on (cmux-tui's Cargo.toml), so `cmux acp
//! attach` and the bundle's `acpmux` symlink open it as before. A headless acpmux (the standalone
//! `acpmux` the packages ship, a default `cargo build -p acpmux`) hands the same session to a
//! `cmux` that carries it, as `acpmux attach S` on this acpmux's home, and with no `cmux` streams
//! the session as `attach --plain` does.

use crate::client::Client;
use anyhow::Result;
use std::sync::Arc;

/// Open `session` (or the session list when None) in a terminal UI.
#[cfg(feature = "tui")]
pub async fn run(client: Arc<Client>, session: Option<String>) -> Result<()> {
    crate::tui::run(client, session).await
}

/// Open `session` (or the session list when None) in a terminal UI.
#[cfg(not(feature = "tui"))]
pub async fn run(client: Arc<Client>, session: Option<String>) -> Result<()> {
    if let Some(cmux) = handoff_binary() {
        drop(client);
        return handoff(&cmux, session.as_deref());
    }
    match session {
        Some(id) => {
            eprintln!(
                "acpmux: this acpmux is headless (no terminal UI) and no `cmux` is on PATH: \
                 streaming the session as `acpmux attach --plain`"
            );
            crate::cli::output::plain_attach(client, &id).await
        }
        None => Err(anyhow::anyhow!(
            "this acpmux is headless (no terminal UI) and no `cmux` is on PATH: list sessions with \
             `acpmux ls`, follow one with `acpmux attach --plain NAME`, or open them in cmux \
             (ACPMUX_TUI=/path/to/cmux names the binary)"
        )),
    }
}

/// Set on the handed-off process: a `cmux` that is itself headless never hands back.
#[cfg(not(feature = "tui"))]
const HANDOFF_ENV: &str = "ACPMUX_TUI_HANDOFF";

/// The `cmux` binary that carries the TUI: `ACPMUX_TUI`, else a `cmux` beside this executable
/// (one install, one build), else the first `cmux` on PATH. Never this executable itself.
#[cfg(not(feature = "tui"))]
fn handoff_binary() -> Option<std::path::PathBuf> {
    pick_handoff(
        std::env::var_os(HANDOFF_ENV).is_some(),
        std::env::var_os("ACPMUX_TUI"),
        std::env::current_exe().ok().as_deref(),
        std::env::var_os("PATH"),
    )
}

/// [`handoff_binary`] over its inputs: none inside a handed-off process, else the first existing
/// file of `named`, `exe`'s sibling `cmux`, then each PATH entry's `cmux` that is not `exe`.
#[cfg(any(test, not(feature = "tui")))]
fn pick_handoff(
    handed_off: bool,
    named: Option<std::ffi::OsString>,
    exe: Option<&std::path::Path>,
    path: Option<std::ffi::OsString>,
) -> Option<std::path::PathBuf> {
    use std::path::{Path, PathBuf};
    if handed_off {
        return None;
    }
    let me = exe.and_then(|e| e.canonicalize().ok());
    let usable =
        |p: &Path| p.is_file() && p.canonicalize().ok().is_some_and(|c| Some(&c) != me.as_ref());
    let name = if cfg!(windows) { "cmux.exe" } else { "cmux" };
    let sibling = exe.and_then(Path::parent).map(|d| d.join(name));
    let on_path = path
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .map(|d| d.join(name));
    named.map(PathBuf::from).into_iter().chain(sibling).chain(on_path).find(|p| usable(p))
}

#[cfg(test)]
mod tests {
    use super::pick_handoff;
    use std::fs;

    fn file(path: &std::path::Path) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, b"").unwrap();
    }

    #[test]
    fn a_headless_acpmux_hands_off_to_the_cmux_beside_it_before_one_on_path() {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("bin/acpmux");
        let sibling = dir.path().join("bin/cmux");
        let other = dir.path().join("other/cmux");
        file(&exe);
        file(&sibling);
        file(&other);
        let path = Some(dir.path().join("other").into_os_string());
        assert_eq!(pick_handoff(false, None, Some(&exe), path.clone()), Some(sibling.clone()));
        fs::remove_file(&sibling).unwrap();
        assert_eq!(pick_handoff(false, None, Some(&exe), path.clone()), Some(other.clone()));
        // ACPMUX_TUI wins; a missing one is skipped.
        let named = dir.path().join("named-cmux");
        assert_eq!(
            pick_handoff(false, Some(named.clone().into_os_string()), Some(&exe), path.clone()),
            Some(other.clone())
        );
        file(&named);
        assert_eq!(
            pick_handoff(false, Some(named.clone().into_os_string()), Some(&exe), path.clone()),
            Some(named)
        );
    }

    #[test]
    fn a_handed_off_process_and_this_executable_itself_never_hand_off() {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("cmux");
        file(&exe);
        let path = Some(dir.path().as_os_str().to_owned());
        // The only `cmux` is this executable (a headless build named cmux): no loop.
        assert_eq!(pick_handoff(false, None, Some(&exe), path.clone()), None);
        let other = dir.path().join("b/cmux");
        file(&other);
        assert_eq!(
            pick_handoff(true, None, Some(&exe), Some(other.parent().unwrap().into())),
            None
        );
        assert_eq!(pick_handoff(false, None, None, None), None);
    }
}

/// `acpmux attach [S]` through `cmux` (its argv0 `acpmux` runs acpmux, `cmux-tui` main.rs), on
/// this process's acpmux home so it reaches the same daemon.
#[cfg(not(feature = "tui"))]
fn handoff(cmux: &std::path::Path, session: Option<&str>) -> Result<()> {
    let mut command = std::process::Command::new(cmux);
    command.env(HANDOFF_ENV, "1").env("ACPMUX_HOME", crate::config::home());
    // No argv0 on Windows: `cmux acp …` is the same acpmux.
    #[cfg(not(unix))]
    command.arg("acp");
    if let Some(id) = session {
        command.args(["attach", id]);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        let error = command.arg0("acpmux").exec();
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
