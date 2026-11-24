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
//! `--swift` is live mode for the app's Swift (docs/cmux-next/live-code.md). Leo (2026-11-05):
//! "there should likely be a way to switch it on and off for when you're hot-building". The live
//! code build is slower and bigger (unoptimized, a file at a time, interposable calls), a cost of how
//! the app is built, so `start --swift` restarts a tagged build into the live code build of its own
//! commit with every session kept, and `stop --swift` restarts it back into the normal build. The
//! work is `scripts/live-code/live-mode.py` in the checkout (it builds with that tree's build.sh).
//!
//! `--chromium` does it for the browser engine's renderer and Blink C++: `start --chromium` watches
//! the checkout's `.cmux-dev/chromium/`, builds the engine incrementally on `--build-host`'s warm
//! tree, swaps the new framework into the running app and restarts only its renderer processes,
//! so open Chromium pages reload on the build while the app and every session stay up
//! (`scripts/cmux-next/chromium-live.py`, [`chromium`]).
//!
//! `auto` is the router over all of them: `auto start` has the session daemon watch the checkout and
//! send each save to the layer that swaps it (cmux-tui-core live_auto.rs), reporting each as a
//! `swap.done` event on `subscribe`; no prompt, no toast, no focus change.

use cmux_process::Command as Process;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::super::GlobalArgs;
use super::UsageError;

mod chromium;
mod web_abi;

/// The script in a cmux checkout that runs the dev server and writes `web-dev.json`.
const SCRIPT: &str = "scripts/cmux-next/web-overlay.sh";
/// The script in a cmux checkout that runs the Rust daemon loop (`--rust`).
const RUST_SCRIPT: &str = "scripts/cmux-next/rust-live.py";
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
    /// What the app loads its web UI from and why (the cmux Live setting, web-dev.json, the server); and the Swift live mode line.
    Status { worktree: Option<PathBuf> },
    /// `start|stop|status --rust`: the Rust daemon loop of `worktree`'s [`RUST_SCRIPT`].
    Rust {
        verb: RustVerb,
        worktree: Option<PathBuf>,
        build_host: Option<String>,
        session: Option<String>,
        /// `start --socket S`: the daemon socket of the app to swap (what `cmux --socket S` reaches),
        /// as `cmux app try` and the app's other commands take it.
        socket: Option<PathBuf>,
    },
    /// `start|stop --swift`: restart the tagged build into its live code build, or back.
    Swift(Swift),
    /// `start|stop|status --chromium`: the engine loop of `worktree`'s `chromium-live.py`;
    /// `args` are its own `start` flags (`--build-host`, `--src`, `--out`, ...), passed through.
    Chromium { verb: RustVerb, worktree: Option<PathBuf>, args: Vec<String> },
    /// `auto [start|stop|status]`: the daemon's save router (`live-auto`), for `worktree`.
    Auto { verb: RustVerb, worktree: Option<PathBuf> },
}

/// What `--rust` (or `--chromium`) does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RustVerb {
    /// Watch the checkout; each saved .rs swaps the running daemon for its build.
    Start,
    /// Stop watching; the daemon keeps the last build it swapped in.
    Stop,
    /// Whether it watches, and the last swap with its timing.
    Status,
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
    /// `stop` only: restart into the build from before live mode, not the optimized build of the edits.
    pub discard: bool,
    /// `start` only: build the live code build of HEAD, not reuse the last one with the difference patched in.
    pub fresh: bool,
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
    if verb == Some("auto") {
        return parse_auto(rest.get(1..).unwrap_or_default());
    }
    let mut worktree = None;
    let mut port = None;
    let mut rust = false;
    let mut chromium = false;
    let mut passthrough: Vec<String> = Vec::new();
    let mut build_host = None;
    let mut session = None;
    let mut socket = None;
    let (mut swift, mut tag, mut detach, mut setting_done, mut discard, mut fresh) =
        (false, None, false, false, false, false);
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
            "--rust" if inline.is_none() => rust = true,
            "--chromium" if inline.is_none() => chromium = true,
            "--src" | "--out" | "--target" | "--app" | "--edits" if verb == Some("start") => {
                let value = value()?;
                passthrough.extend([flag.to_owned(), value]);
            }
            "--gpu" if inline.is_none() && verb == Some("start") => {
                passthrough.push(flag.to_owned());
            }
            "--build-host" if verb == Some("start") => build_host = Some(value()?),
            "--session" if verb == Some("start") => session = Some(value()?),
            "--socket" if verb == Some("start") => socket = Some(PathBuf::from(value()?)),
            "--swift" if switches => swift = true,
            "--tag" if switches => tag = Some(value()?),
            "--detach" if switches => detach = true,
            "--setting-done" if switches => setting_done = true,
            "--discard" if verb == Some("stop") => discard = true,
            "--fresh" if verb == Some("start") => fresh = true,
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
    let unexpected =
        |flag: &str| UsageError::new(messages.unexpected_argument.replace("{value}", flag));
    if swift {
        // The Swift switch takes none of the other loops' flags (a flag it would drop unread).
        let other = [
            (rust, "--rust"),
            (chromium, "--chromium"),
            (port.is_some(), "--port"),
            (build_host.is_some(), "--build-host"),
            (session.is_some(), "--session"),
            (socket.is_some(), "--socket"),
        ]
        .into_iter()
        .find_map(|(given, flag)| given.then_some(flag))
        .or(passthrough.first().map(String::as_str));
        if let Some(flag) = other {
            return Err(unexpected(flag));
        }
        return Ok(Command::Swift(Swift {
            on: verb == Some("start"),
            worktree,
            tag,
            detach,
            setting_done,
            discard,
            fresh,
        }));
    }
    if let Some(flag) = [
        (tag.is_some(), "--tag"),
        (detach, "--detach"),
        (setting_done, "--setting-done"),
        (discard, "--discard"),
        (fresh, "--fresh"),
    ]
    .into_iter()
    .find_map(|(given, flag)| given.then_some(flag))
    {
        // Only the Swift switch takes these.
        return Err(unexpected(flag));
    }
    let unexpected =
        |flag: &str| UsageError::new(messages.unexpected_argument.replace("{value}", flag));
    if rust && chromium {
        return Err(unexpected("--chromium"));
    }
    if let (false, Some(flag)) = (chromium, passthrough.first()) {
        return Err(unexpected(flag));
    }
    if build_host.is_some() && !rust && !chromium {
        return Err(unexpected("--build-host"));
    }
    if session.is_some() && !rust {
        return Err(unexpected("--session"));
    }
    if socket.is_some() && (!rust || session.is_some()) {
        // One daemon per loop: a socket or a session names it, not both.
        return Err(unexpected("--socket"));
    }
    if chromium {
        if port.is_some() {
            return Err(unexpected("--port"));
        }
        let verb = match verb {
            Some("start") => RustVerb::Start,
            Some("stop") => RustVerb::Stop,
            Some("status") => RustVerb::Status,
            _ => return Err(UsageError::new(messages.live.usage)),
        };
        if let Some(host) = build_host {
            passthrough.splice(0..0, ["--build-host".to_owned(), host]);
        }
        return Ok(Command::Chromium { verb, worktree, args: passthrough });
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
        return Ok(Command::Rust { verb, worktree, build_host, session, socket });
    }
    match verb {
        Some("start") => Ok(Command::Start { worktree, port }),
        Some("stop") => Ok(Command::Stop { worktree }),
        Some("status") => Ok(Command::Status { worktree }),
        _ => Err(UsageError::new(messages.live.usage)),
    }
}

/// `auto [start|stop|status] [--worktree PATH]`; `start` when no verb is given.
fn parse_auto(rest: &[String]) -> Result<Command, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let mut verb = None;
    let mut worktree = None;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        match flag {
            "--worktree" => {
                let value = inline.or_else(|| words.next().cloned()).filter(|v| !v.is_empty());
                worktree = Some(PathBuf::from(value.ok_or_else(|| {
                    UsageError::new(messages.missing_value.replace("{flag}", flag))
                })?));
            }
            "start" if verb.is_none() => verb = Some(RustVerb::Start),
            "stop" if verb.is_none() => verb = Some(RustVerb::Stop),
            "status" if verb.is_none() => verb = Some(RustVerb::Status),
            other => {
                return Err(UsageError::new(
                    messages.unexpected_argument.replace("{value}", other),
                ));
            }
        }
    }
    Ok(Command::Auto { verb: verb.unwrap_or(RustVerb::Start), worktree })
}

/// `command` with the daemon `cmux --socket S live ...` or `cmux --session S live ...` names, when
/// `start --rust` names none itself (the flag after the noun wins).
pub(super) fn routed(command: &Command, socket: Option<&Path>, session: Option<&str>) -> Command {
    match command {
        Command::Rust {
            verb: RustVerb::Start,
            worktree,
            build_host,
            session: None,
            socket: None,
        } => Command::Rust {
            verb: RustVerb::Start,
            worktree: worktree.clone(),
            build_host: build_host.clone(),
            session: socket.is_none().then(|| session.map(str::to_owned)).flatten(),
            socket: socket.map(Path::to_path_buf),
        },
        other => other.clone(),
    }
}

/// Runs `command`: the checkout's script, with this process's terminal, and its exit status.
pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
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
        Command::Swift(swift) => return run_swift(swift),
        Command::Chromium { verb, worktree, args } => return chromium::run(*verb, worktree, args),
        Command::Auto { verb, worktree } => return run_auto(global, *verb, worktree.as_deref()),
    };
    let started = matches!(command, Command::Stop { .. } | Command::Status { .. });
    let Some(tree) = checkout(worktree.as_deref(), started) else {
        if matches!(command, Command::Status { .. }) && swift_status(worktree.as_deref()) {
            return 0;
        }
        eprintln!("{}", messages.no_checkout);
        return 2;
    };
    if matches!(command, Command::Start { .. })
        && let Some(found) = web_abi::mismatch(
            &tree,
            &web_abi::target_apps(std::env::var_os("CMUX_WEB_OVERLAY_APP")),
        )
    {
        // Nothing is started or written: a write to web-dev.json reloads every page of every app.
        eprintln!(
            "{}",
            messages
                .abi_mismatch
                .replace("{tree_abi}", &found.tree_abi.to_string())
                .replace("{app}", &found.app.display().to_string())
                .replace("{app_abi}", &found.app_abi.to_string())
        );
        return 1;
    }
    let mut process = Process::new("bash");
    process.arg(tree.join(SCRIPT)).args(&args).current_dir(&tree);
    if let Some(path) = tool_path(std::env::var_os("PATH"), std::env::var_os("HOME")) {
        process.env("PATH", path);
    }
    if matches!(command, Command::Start { .. }) {
        process.args(["--worktree".as_ref(), tree.as_os_str()]);
    }
    if matches!(command, Command::Status { .. }) {
        // The script's own `cmux settings get` reached no app this command was pointed at
        // (`--app-socket`), and the `cmux` on a GUI app's `PATH` may be none at all.
        process.env(LIVE_SETTING_ENV, live_setting(global));
    }
    match process.status() {
        Ok(status) => {
            let code = status.code().unwrap_or(1);
            if code == 0 && matches!(command, Command::Start { .. }) {
                println!("{}", messages.started);
            }
            if matches!(command, Command::Status { .. }) {
                swift_status(Some(&tree));
                if tree.join(RUST_SCRIPT).is_file() {
                    // The Rust loop's last swap, when it ever ran (prints nothing otherwise).
                    let _ = Process::new("python3")
                        .arg(tree.join(RUST_SCRIPT))
                        .args(["status", "--if-used"])
                        .current_dir(&tree)
                        .status();
                }
                chromium::status_if_used(&tree);
            }
            code
        }
        Err(error) => {
            eprintln!("{}", messages.cannot_run.replace("{error}", &error.to_string()));
            1
        }
    }
}

/// Runs `auto`: one `live-auto` request to the session daemon, which owns the router.
fn run_auto(global: &GlobalArgs, verb: RustVerb, worktree: Option<&Path>) -> i32 {
    use super::super::safe_mode::{Answer, ask};
    let messages = &crate::localization::catalog().app_control.live;
    let around = || {
        Process::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| PathBuf::from(String::from_utf8_lossy(&output.stdout).trim()))
    };
    let tree = match worktree {
        Some(path) => Some(path.canonicalize().unwrap_or_else(|_| path.to_path_buf())),
        None => around(),
    };
    let op = match verb {
        RustVerb::Start => "start",
        RustVerb::Stop => "stop",
        RustVerb::Status => "status",
    };
    if verb == RustVerb::Start && tree.is_none() {
        eprintln!("{}", messages.no_checkout);
        return 2;
    }
    let mut frame = json!({"id": "cmux-live-auto-1", "cmd": "live-auto", "op": op});
    // `stop` with no --worktree outside a checkout stops every one.
    if let Some(tree) = tree.as_ref().filter(|_| verb != RustVerb::Status) {
        if let Some(map) = frame.as_object_mut() {
            map.insert("worktree".to_owned(), json!(tree.display().to_string()));
        }
    }
    let answer = match ask(global, frame) {
        Answer::Ok(answer) => answer,
        Answer::Refused { code, message } => {
            eprintln!(
                "{}",
                messages.auto_refused.replace("{error}", &format!("{code}: {message}"))
            );
            return 1;
        }
        Answer::NoDaemon(error) => {
            eprintln!("{}", messages.auto_no_daemon.replace("{error}", &error));
            return 1;
        }
    };
    if matches!(global.output, super::super::OutputMode::Json | super::super::OutputMode::JsonLines)
    {
        println!("{answer}");
        return 0;
    }
    if global.output == super::super::OutputMode::Quiet {
        return 0;
    }
    for line in auto_lines(&answer, verb) {
        println!("{line}");
    }
    0
}

/// `live-auto`'s answer as the lines `cmux live auto` prints.
pub(super) fn auto_lines(answer: &Value, verb: RustVerb) -> Vec<String> {
    let messages = &crate::localization::catalog().app_control.live;
    let trees = answer.get("trees").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut lines = Vec::new();
    if verb == RustVerb::Stop {
        for tree in answer.get("stopped").and_then(Value::as_array).into_iter().flatten() {
            lines.push(messages.auto_stopped.replace("{worktree}", tree.as_str().unwrap_or("")));
        }
    }
    if trees.is_empty() {
        lines.push(messages.auto_not_watching.to_owned());
        return lines;
    }
    let on = |tree: &Value, layer: &str| {
        tree.get("live").and_then(|live| live.get(layer)).and_then(Value::as_bool) == Some(true)
    };
    for tree in &trees {
        let layers: Vec<&str> =
            ["web", "rust", "swift"].into_iter().filter(|layer| on(tree, layer)).collect();
        let number = |key: &str| {
            tree.get("trigger_ms").and_then(|ms| ms.get(key)).and_then(Value::as_f64).unwrap_or(0.0)
        };
        lines.push(
            messages
                .auto_watching
                .replace("{worktree}", tree["worktree"].as_str().unwrap_or(""))
                .replace(
                    "{layers}",
                    &if layers.is_empty() { "-".to_owned() } else { layers.join(", ") },
                )
                .replace("{saves}", &tree["saves"].as_u64().unwrap_or(0).to_string())
                .replace("{p50}", &format!("{:.1}", number("p50")))
                .replace("{p95}", &format!("{:.1}", number("p95"))),
        );
        if let Some(error) = tree["error"].as_str() {
            lines.push(format!("  {error}"));
        }
    }
    for event in answer.get("recent").and_then(Value::as_array).into_iter().flatten().rev().take(5)
    {
        let paths: Vec<&str> =
            event["paths"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
        let note = event["error"].as_str().or(event["reason"].as_str()).unwrap_or("");
        lines.push(format!(
            "  {} {:.0} ms {}{}{}",
            event["layer"].as_str().unwrap_or("?"),
            event["ms"].as_f64().unwrap_or(0.0),
            paths.join(" "),
            if note.is_empty() { "" } else { ": " },
            note
        ));
    }
    lines
}

/// The cmux Live setting, read here for `status`.
const LIVE_SETTING: &str = "updates.liveWebReload";
/// How `status` hands [`LIVE_SETTING`] to [`SCRIPT`]: `true`, `false` or `unknown`.
const LIVE_SETTING_ENV: &str = "CMUX_LIVE_WEB_RELOAD";

/// [`LIVE_SETTING`] from the app this command reaches (`--app-socket`, `--socket`, else the app
/// around this CLI or in its environment, as every app command finds it): `true` or `false`, else
/// `unknown` when no app answered or it answered no boolean.
fn live_setting(global: &GlobalArgs) -> String {
    let Ok(mut stream) = super::connect_command(global) else { return "unknown".to_owned() };
    let answer = super::exchange(
        &mut stream,
        "settings.get",
        json!({ "path": LIVE_SETTING }),
        super::READ_TIMEOUT,
    );
    match answer {
        Ok(Ok(answer)) => setting_word(&answer),
        _ => "unknown".to_owned(),
    }
}

/// `settings.get`'s answer as the word the script reads.
pub(super) fn setting_word(answer: &Value) -> String {
    match answer.get("value") {
        Some(Value::Bool(on)) => on.to_string(),
        Some(Value::String(word)) if word == "true" || word == "false" => word.clone(),
        _ => "unknown".to_owned(),
    }
}

/// Runs a `--rust` command: the checkout's [`RUST_SCRIPT`], with this process's terminal.
fn run_rust(command: &Command) -> i32 {
    let messages = &crate::localization::catalog().app_control.live;
    let Command::Rust { verb, worktree, build_host, session, socket } = command else {
        return 2;
    };
    let tree = match worktree {
        Some(worktree) => {
            worktree.canonicalize().ok().filter(|tree| tree.join(RUST_SCRIPT).is_file())
        }
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
            if let Some(socket) = socket {
                process.args(["--socket".as_ref(), socket.as_os_str()]);
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
    if swift.discard {
        args.push("--discard".to_owned());
    }
    if swift.fresh {
        args.push("--fresh".to_owned());
    }
    match swift_process(&tree, &args).status() {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            eprintln!("{}", messages.cannot_run_swift.replace("{error}", &error.to_string()));
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
    recorded_watch_tree(&state.join("watch.pid"))
        .map(|tree| tree.join(RUST_SCRIPT))
        .filter(|s| s.is_file())
}

/// The checkout in a `watch.pid` file (`<pid> <tree>`, written by `rust-live.py`).
pub(super) fn recorded_watch_tree(file: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(file).ok()?;
    let (pid, tree) = text.lines().next()?.trim().split_once(' ')?;
    (pid.parse::<u32>().is_ok() && !tree.is_empty()).then(|| PathBuf::from(tree))
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
