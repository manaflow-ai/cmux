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
//! `--swift` is live mode for the app's Swift (docs/cmux-next/live-code.md). Leo (2026-11-05):
//! "there should likely be a way to switch it on and off for when you're hot-building". The live
//! code build is slower and bigger (unoptimized, a file at a time, interposable calls), a cost of how
//! the app is built, so `start --swift` restarts a tagged build into the live code build of its own
//! commit with every session kept, and `stop --swift` restarts it back into the normal build. The
//! work is `scripts/live-code/live-mode.py` in the checkout (it builds with that tree's build.sh).

use cmux_process::Command as Process;
use std::path::{Path, PathBuf};

use super::UsageError;

/// The script in a cmux checkout that runs the dev server and writes `web-dev.json`.
const SCRIPT: &str = "scripts/cmux-next/web-overlay.sh";
/// The script in a cmux checkout that swaps a tagged build to its live code build and back.
const SWIFT_SCRIPT: &str = "scripts/live-code/live-mode.py";

/// A parsed `cmux live` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Command {
    /// `--help`, `-h`, `help` or no verb.
    Help,
    /// Run `worktree`'s dev server (default: the checkout around the current folder).
    Start { worktree: Option<PathBuf>, port: Option<u16> },
    /// Stop the dev server `start` ran; the app goes back to its shipped web UI.
    Stop { worktree: Option<PathBuf> },
    /// What the app loads from, and the Live Web Reload setting; and the Swift live mode line.
    Status { worktree: Option<PathBuf> },
    /// `start|stop --swift`: restart the tagged build into its live code build, or back.
    Swift(Swift),
}

/// `cmux live start|stop --swift` (scripts/live-code/live-mode.py).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Swift {
    pub on: bool,
    pub worktree: Option<PathBuf>,
    /// The tagged build (default: the one this terminal belongs to, `CMUX_TAG`).
    pub tag: Option<String>,
    /// Return at once; the swap runs in its own session (the app's Live Mode buttons: the app quits).
    pub detach: bool,
    /// The app already set `labs.liveCode` (the person's click on its button).
    pub setting_done: bool,
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
    let (mut swift, mut tag, mut detach, mut setting_done) = (false, None, false, false);
    let switches = matches!(verb, Some("start" | "stop"));
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
            "--swift" if switches => swift = true,
            "--tag" if switches => tag = Some(value()?),
            "--detach" if switches => detach = true,
            "--setting-done" if switches => setting_done = true,
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
    if swift {
        if port.is_some() {
            return Err(UsageError::new(messages.unexpected_argument.replace("{value}", "--port")));
        }
        return Ok(Command::Swift(Swift { on: verb == Some("start"), worktree, tag, detach, setting_done }));
    }
    if let Some(flag) = [(tag.is_some(), "--tag"), (detach, "--detach"), (setting_done, "--setting-done")]
        .into_iter()
        .find_map(|(given, flag)| given.then_some(flag))
    {
        // Only the Swift switch takes these.
        return Err(UsageError::new(messages.unexpected_argument.replace("{value}", flag)));
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
        Command::Swift(swift) => return run_swift(swift),
    };
    let started = matches!(command, Command::Stop { .. } | Command::Status { .. });
    let Some(tree) = checkout(worktree.as_deref(), started) else {
        if matches!(command, Command::Status { .. }) && swift_status(worktree.as_deref()) {
            return 0;
        }
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
            if matches!(command, Command::Status { .. }) {
                swift_status(Some(&tree));
            }
            code
        }
        Err(error) => {
            eprintln!("{}", messages.cannot_run.replace("{error}", &error.to_string()));
            1
        }
    }
}

/// Runs live-mode.py `start` or `stop` in the checkout, with this process's terminal.
fn run_swift(swift: &Swift) -> i32 {
    let messages = &crate::localization::catalog().app_control.live;
    let Some(tree) = swift_checkout(swift.worktree.as_deref(), !swift.on) else {
        eprintln!("{}", messages.no_swift_checkout);
        return 2;
    };
    let mut args = vec![if swift.on { "start" } else { "stop" }.to_owned()];
    if let Some(tag) = &swift.tag {
        args.extend(["--tag".to_owned(), tag.clone()]);
    }
    if swift.detach {
        args.push("--detach".to_owned());
    }
    if swift.setting_done {
        args.push("--setting-done".to_owned());
    }
    match swift_process(&tree, &args).status() {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            eprintln!("{}", messages.cannot_run_swift.replace("{error}", &error.to_string()));
            1
        }
    }
}

/// Prints live-mode.py's `status` line when a checkout with it is found; whether one was.
fn swift_status(worktree: Option<&Path>) -> bool {
    let Some(tree) = swift_checkout(worktree, true) else { return false };
    swift_process(&tree, &["status".to_owned()]).status().is_ok_and(|status| status.success())
}

fn swift_process(tree: &Path, args: &[String]) -> Process {
    let mut process = Process::new("python3");
    process.arg(tree.join(SWIFT_SCRIPT)).args(args).args(["--tree".as_ref(), tree.as_os_str()]);
    process.current_dir(tree);
    if let Some(path) = tool_path(std::env::var_os("PATH"), std::env::var_os("HOME")) {
        process.env("PATH", path);
    }
    process
}

/// The checkout for `--swift`: `worktree`, else the one around the current folder, else the one
/// that built the running tagged app (`CMUXTERM_REPO_ROOT`, which reload.sh writes into its
/// environment), else (`started`: stop and status) the one live mode last ran from.
fn swift_checkout(worktree: Option<&Path>, started: bool) -> Option<PathBuf> {
    let holds = |tree: &Path| tree.join(SWIFT_SCRIPT).is_file();
    if let Some(worktree) = worktree {
        return worktree.canonicalize().ok().filter(|tree| holds(tree));
    }
    let around = Process::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| PathBuf::from(String::from_utf8_lossy(&output.stdout).trim()))
        .filter(|tree| holds(tree));
    let built_from = || {
        std::env::var_os("CMUXTERM_REPO_ROOT")
            .filter(|root| !root.is_empty())
            .map(PathBuf::from)
            .filter(|tree| holds(tree))
    };
    let recorded = || {
        let home = std::env::var_os("HOME").filter(|home| !home.is_empty())?;
        let file = PathBuf::from(home).join("Library/Caches/cmux-next/live-mode/tree");
        recorded_swift_tree(&file).filter(|tree| holds(tree))
    };
    around.or_else(built_from).or_else(|| started.then(recorded).flatten())
}

/// The checkout in live mode's `tree` file (one absolute path, written by live-mode.py).
pub(super) fn recorded_swift_tree(file: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(file).ok()?;
    let line = text.lines().next()?.trim();
    line.starts_with('/').then(|| PathBuf::from(line))
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
