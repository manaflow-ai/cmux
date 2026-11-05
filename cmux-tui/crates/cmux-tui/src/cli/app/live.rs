//! `cmux live start|stop|status`: edit cmux itself while it runs.
//!
//! Leo (2026-11-05): "you should be able to just change your app without going through all this
//! hoopla", and on how people find it: "it should just be blasted, like, hey, you can edit your
//! thing and just do this". `start` runs a checkout's webviews dev server and points the running
//! app at it (`~/.config/cmux/web-dev.json`), so a saved edit to cmux's web UI shows in every
//! open page and chat, in WebKit and Chromium, with no build and no relaunch
//! (docs/cmux-next/hot-reload.md). The work is `scripts/cmux-next/web-overlay.sh` in that
//! checkout: the dev server comes from its tree, so the script that starts it is the tree's own.
//! The app's Edit cmux Live action and the `cmux-live` agent skill run this command.
//!
//! `--rust` does the same for the daemon: `start --rust` watches the checkout's cmux-tui/ and, on
//! each saved .rs, builds the daemons it reaches (here or on `--build-host`) and swaps the running
//! daemon for the build, keeping every terminal and agent session (`scripts/cmux-next/rust-live.py`).
//! `status` shows the last swap and how long it took from the save.

use cmux_process::Command as Process;
use std::path::{Path, PathBuf};

use super::UsageError;

/// The script in a cmux checkout that runs the dev server and writes `web-dev.json`.
const SCRIPT: &str = "scripts/cmux-next/web-overlay.sh";
/// The script in a cmux checkout that runs the Rust daemon loop (`--rust`).
const RUST_SCRIPT: &str = "scripts/cmux-next/rust-live.py";

/// A parsed `cmux live` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Command {
    /// `--help`, `-h`, `help` or no verb.
    Help,
    /// Run `worktree`'s dev server (default: the checkout around the current folder).
    Start { worktree: Option<PathBuf>, port: Option<u16> },
    /// Stop the dev server `start` ran; the app goes back to its shipped web UI.
    Stop { worktree: Option<PathBuf> },
    /// What the app loads from, and the Live Web Reload setting.
    Status { worktree: Option<PathBuf> },
    /// `start|stop|status --rust`: the Rust daemon loop of `worktree`'s [`RUST_SCRIPT`].
    Rust { verb: RustVerb, worktree: Option<PathBuf>, build_host: Option<String>, session: Option<String> },
}

/// What `--rust` does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RustVerb {
    /// Watch the checkout; each saved .rs swaps the running daemon for its build.
    Start,
    /// Stop watching; the daemon keeps the last build it swapped in.
    Stop,
    /// Whether it watches, and the last swap with its timing.
    Status,
}

/// Parses the words after `live`.
pub(super) fn parse(rest: &[String]) -> Result<Command, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let verb = rest.first().map(String::as_str);
    if matches!(verb, None | Some("help"))
        || rest.iter().any(|word| word == "--help" || word == "-h")
    {
        return Ok(Command::Help);
    }
    let mut worktree = None;
    let mut port = None;
    let mut rust = false;
    let mut build_host = None;
    let mut session = None;
    let mut words = rest.iter().skip(1);
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| words.next().cloned())
                .filter(|value| !value.is_empty())
                .ok_or_else(|| UsageError::new(messages.missing_value.replace("{flag}", flag)))
        };
        match flag {
            "--worktree" => worktree = Some(PathBuf::from(value()?)),
            "--rust" if inline.is_none() => rust = true,
            "--build-host" if verb == Some("start") => build_host = Some(value()?),
            "--session" if verb == Some("start") => session = Some(value()?),
            "--port" if verb == Some("start") => {
                port = Some(value()?.parse::<u16>().ok().filter(|port| *port > 0).ok_or_else(
                    || UsageError::new(messages.missing_value.replace("{flag}", "--port")),
                )?);
            }
            other => {
                return Err(UsageError::new(
                    messages.unexpected_argument.replace("{value}", other),
                ));
            }
        }
    }
    if (build_host.is_some() || session.is_some()) && !rust {
        let flag = if build_host.is_some() { "--build-host" } else { "--session" };
        return Err(UsageError::new(messages.unexpected_argument.replace("{value}", flag)));
    }
    if rust {
        if port.is_some() {
            return Err(UsageError::new(messages.unexpected_argument.replace("{value}", "--port")));
        }
        let verb = match verb {
            Some("start") => RustVerb::Start,
            Some("stop") => RustVerb::Stop,
            Some("status") => RustVerb::Status,
            _ => return Err(UsageError::new(messages.live.usage)),
        };
        return Ok(Command::Rust { verb, worktree, build_host, session });
    }
    match verb {
        Some("start") => Ok(Command::Start { worktree, port }),
        Some("stop") => Ok(Command::Stop { worktree }),
        Some("status") => Ok(Command::Status { worktree }),
        _ => Err(UsageError::new(messages.live.usage)),
    }
}

/// Runs `command`: the checkout's script, with this process's terminal, and its exit status.
pub(super) fn run(command: &Command) -> i32 {
    let messages = &crate::localization::catalog().app_control.live;
    let (worktree, args): (&Option<PathBuf>, Vec<String>) = match command {
        Command::Help => {
            println!("{}", messages.usage);
            return 0;
        }
        Command::Start { worktree, port } => {
            let mut args = vec!["server".to_owned(), "--local".to_owned()];
            if let Some(port) = port {
                args.extend(["--port".to_owned(), port.to_string()]);
            }
            (worktree, args)
        }
        Command::Stop { worktree } => (worktree, vec!["server".to_owned(), "off".to_owned()]),
        Command::Status { worktree } => (worktree, vec!["status".to_owned()]),
        Command::Rust { .. } => return run_rust(command),
    };
    let started = matches!(command, Command::Stop { .. } | Command::Status { .. });
    let Some(tree) = checkout(worktree.as_deref(), started) else {
        eprintln!("{}", messages.no_checkout);
        return 2;
    };
    let mut process = Process::new("bash");
    process.arg(tree.join(SCRIPT)).args(&args).current_dir(&tree);
    if let Some(path) = tool_path(std::env::var_os("PATH"), std::env::var_os("HOME")) {
        process.env("PATH", path);
    }
    if matches!(command, Command::Start { .. }) {
        process.args(["--worktree".as_ref(), tree.as_os_str()]);
    }
    match process.status() {
        Ok(status) => {
            let code = status.code().unwrap_or(1);
            if code == 0 && matches!(command, Command::Start { .. }) {
                println!("{}", messages.started);
            }
            if matches!(command, Command::Status { .. }) && tree.join(RUST_SCRIPT).is_file() {
                // The Rust loop's last swap, when it ever ran (prints nothing otherwise).
                let _ = Process::new("python3")
                    .arg(tree.join(RUST_SCRIPT))
                    .args(["status", "--if-used"])
                    .current_dir(&tree)
                    .status();
            }
            code
        }
        Err(error) => {
            eprintln!("{}", messages.cannot_run.replace("{error}", &error.to_string()));
            1
        }
    }
}

/// Runs a `--rust` command: the checkout's [`RUST_SCRIPT`], with this process's terminal.
fn run_rust(command: &Command) -> i32 {
    let messages = &crate::localization::catalog().app_control.live;
    let Command::Rust { verb, worktree, build_host, session } = command else {
        return 2;
    };
    let tree = match worktree {
        Some(worktree) => worktree.canonicalize().ok().filter(|tree| tree.join(RUST_SCRIPT).is_file()),
        None => Process::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| PathBuf::from(String::from_utf8_lossy(&output.stdout).trim()))
            .filter(|tree| tree.join(RUST_SCRIPT).is_file()),
    };
    // stop and status need no checkout: the loop's state folder says what runs.
    let script = match (&tree, verb) {
        (Some(tree), _) => tree.join(RUST_SCRIPT),
        (None, RustVerb::Start) => {
            eprintln!("{}", messages.rust_no_checkout);
            return 2;
        }
        (None, _) => match recorded_rust_script() {
            Some(script) => script,
            None => {
                println!("{}", messages.rust_not_watching);
                return 0;
            }
        },
    };
    let mut process = Process::new("python3");
    process.arg(&script);
    match verb {
        RustVerb::Start => {
            process.arg("start");
            if let Some(tree) = &tree {
                process.args(["--worktree".as_ref(), tree.as_os_str()]);
            }
            if let Some(host) = build_host {
                process.args(["--build-host", host]);
            }
            if let Some(session) = session {
                process.args(["--session", session]);
            }
        }
        RustVerb::Stop => {
            process.arg("stop");
        }
        RustVerb::Status => {
            process.arg("status");
        }
    }
    if let Some(path) = tool_path(std::env::var_os("PATH"), std::env::var_os("HOME")) {
        process.env("PATH", path);
    }
    match process.status() {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            eprintln!("{}", messages.cannot_run.replace("{error}", &error.to_string()));
            1
        }
    }
}

/// The running Rust loop's script, from the checkout its `watch.pid` names.
fn recorded_rust_script() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").filter(|home| !home.is_empty())?;
    let state = std::env::var_os("CMUX_RUST_LIVE_STATE_DIR")
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = PathBuf::from(home);
            if cfg!(target_os = "macos") {
                home.join("Library/Caches/cmux-next/rust-live")
            } else {
                std::env::var_os("XDG_CACHE_HOME")
                    .filter(|dir| !dir.is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(|| home.join(".cache"))
                    .join("cmux-next/rust-live")
            }
        });
    recorded_watch_tree(&state.join("watch.pid")).map(|tree| tree.join(RUST_SCRIPT)).filter(|s| s.is_file())
}

/// The checkout in a `watch.pid` file (`<pid> <tree>`, written by `rust-live.py`).
pub(super) fn recorded_watch_tree(file: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(file).ok()?;
    let (pid, tree) = text.lines().next()?.trim().split_once(' ')?;
    (pid.parse::<u32>().is_ok() && !tree.is_empty()).then(|| PathBuf::from(tree))
}

/// The cmux checkout to use: `worktree`, else the one around the current folder, else (for `stop`
/// and `status`, when `started`) the one the running dev server was started from. Each must hold
/// [`SCRIPT`].
fn checkout(worktree: Option<&Path>, started: bool) -> Option<PathBuf> {
    if let Some(worktree) = worktree {
        let tree = worktree.canonicalize().ok()?;
        return holds_script(&tree).then_some(tree);
    }
    let around = Process::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| PathBuf::from(String::from_utf8_lossy(&output.stdout).trim()))
        .filter(|tree| holds_script(tree));
    if around.is_some() || !started {
        return around;
    }
    recorded_tree(&state_dir()?.join("dev-server.tree")).filter(|tree| holds_script(tree))
}

/// `PATH` with the folders `bun` and Homebrew install into appended when missing. The app's
/// Edit cmux Live action runs this command with a GUI app's short `PATH`, which has neither, and the
/// script runs `bun` (the webviews dev server). Nil when nothing needs adding.
pub(super) fn tool_path(
    path: Option<std::ffi::OsString>,
    home: Option<std::ffi::OsString>,
) -> Option<std::ffi::OsString> {
    let mut dirs: Vec<PathBuf> =
        path.as_deref().map(|path| std::env::split_paths(path).collect()).unwrap_or_default();
    let before = dirs.len();
    let mut wanted = Vec::new();
    if let Some(home) = home.filter(|home| !home.is_empty()) {
        wanted.push(PathBuf::from(home).join(".bun/bin"));
    }
    wanted.extend(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map(PathBuf::from));
    for dir in wanted {
        if !dirs.contains(&dir) {
            dirs.push(dir);
        }
    }
    (dirs.len() != before).then(|| std::env::join_paths(dirs).ok()).flatten()
}

fn holds_script(tree: &Path) -> bool {
    tree.join(SCRIPT).is_file()
}

/// `web-overlay.sh`'s state folder (its `state`): pid files and the started tree.
fn state_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CMUX_WEB_SLOT_STATE_DIR").filter(|dir| !dir.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    let home = std::env::var_os("HOME").filter(|home| !home.is_empty())?;
    Some(PathBuf::from(home).join("Library/Caches/cmux-next/web-slot"))
}

/// The tree in a `dev-server.tree` file (`<tree>:<port>`, written by `web-overlay.sh`).
pub(super) fn recorded_tree(file: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(file).ok()?;
    let line = text.lines().next()?.trim();
    let (tree, port) = line.rsplit_once(':')?;
    (!tree.is_empty() && port.parse::<u16>().is_ok()).then(|| PathBuf::from(tree))
}

#[cfg(test)]
mod tests;
