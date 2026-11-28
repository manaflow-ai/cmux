//! Turn frames of a native Mac app's window (RFD 0151, "the iOS simulator and native Mac windows,
//! through the resident preview worker"): in a turn that runs a Mac app it built or opened, a frame
//! with no agent-driven page is of that app's front window.
//!
//! Which app: the last one a shell call of the turn ran ([`runs_mac_app`]): `open X.app`,
//! `open -a X`, `open -b ID`, `swift run PRODUCT`, or an executable under `.build/`, `DerivedData/`
//! or an app's `Contents/MacOS/`.
//!
//! How: through the Computer Use worker the cmux Remote host keeps resident (it holds the Screen
//! Recording grant; acpmux never asks macOS for one). `status`, then `list_windows` (discovery, which
//! every mode allows) and `screenshot` of the app's front on-screen window, on a session of acpmux's
//! own per chat. Only when the person's mode lets a screenshot through with no question
//! (`fullAccess`, `lookOnly`): a frame never puts an approval card in front of the person. Denied and
//! protected apps are refused by the worker, and other apps' windows over it are painted out by it.
//! Each read is bounded by the worker connection's hello timeout; Computer Use off, a worker away,
//! no matching window: no frame, never a wait.

use std::path::Path;

use serde_json::{Value, json};

use crate::computer_use::ToolOutput;
use crate::shell_words;

/// The label the worker's audit log shows for these reads.
const LABEL: &str = "Turn frames";

/// The Mac app a tool call runs, by the name its windows go by (an app or product name, or a bundle
/// id from `open -b`). None for every other call.
pub(crate) fn runs_mac_app(update: &Value) -> Option<String> {
    let command = update.pointer("/rawInput/command")?;
    let script = match command {
        Value::String(text) => text.clone(),
        Value::Array(words) => {
            words.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")
        }
        _ => return None,
    };
    let lexed = shell_words::lex(&script)?;
    lexed.commands.iter().rev().find_map(|c| app_of(&c.words))
}

/// The app one simple command runs.
pub(crate) fn app_of(words: &[String]) -> Option<String> {
    let words = program_words(words);
    let program = words.first()?;
    let name = program.rsplit('/').next().unwrap_or(program);
    match name {
        "open" => opened(&words[1..]),
        "swift" if words.get(1).map(String::as_str) == Some("run") => swift_product(&words[2..]),
        _ => built_executable(program),
    }
}

/// `words` from the program on: leading `NAME=value` assignments and wrappers (`env`, `exec`,
/// `nohup`, `time`) dropped.
fn program_words(words: &[String]) -> &[String] {
    let mut rest = words;
    while let Some(first) = rest.first() {
        let assignment = first.contains('=') && !first.starts_with('-') && !first.contains('/');
        if assignment || matches!(first.as_str(), "env" | "exec" | "nohup" | "time" | "caffeinate") {
            rest = &rest[1..];
        } else {
            break;
        }
    }
    rest
}

/// `open`'s app: `-a NAME`, `-b BUNDLE_ID`, or an `.app` bundle path. A file or URL `open` hands to
/// another app is none.
fn opened(args: &[String]) -> Option<String> {
    let mut found = None;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "-a" => found = it.next().map(|a| app_name(a)),
            "-b" => found = it.next().cloned(),
            "--args" => break,
            a if a.trim_end_matches('/').ends_with(".app") => found = Some(app_name(a)),
            _ => {}
        }
    }
    found.filter(|n| !n.is_empty())
}

/// `/x/Build/Products/Debug/My App.app/` is `My App`.
fn app_name(path: &str) -> String {
    let base = path.trim_end_matches('/').rsplit('/').next().unwrap_or_default();
    base.strip_suffix(".app").unwrap_or(base).to_owned()
}

/// `swift run`'s product: its first argument that is not an option or an option's value. None for
/// a bare `swift run`, whose product's name the command does not say.
fn swift_product(args: &[String]) -> Option<String> {
    const TAKES_VALUE: [&str; 10] = [
        "-c",
        "--configuration",
        "--package-path",
        "--scratch-path",
        "--build-path",
        "--cache-path",
        "-Xswiftc",
        "-Xcc",
        "-Xlinker",
        "-Xcxx",
    ];
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if arg == "--" {
            return None;
        }
        if TAKES_VALUE.contains(&arg.as_str()) {
            it.next();
            continue;
        }
        if arg.starts_with('-') {
            continue;
        }
        return Some(arg.clone());
    }
    None
}

/// An executable a Mac build wrote, run by its path: under SwiftPM's `.build/`, Xcode's
/// `DerivedData/` or `Build/Products/`, or an app bundle's `Contents/MacOS/`.
fn built_executable(program: &str) -> Option<String> {
    if !program.contains('/') {
        return None;
    }
    let built = [".build/", "DerivedData/", "Build/Products/", ".app/Contents/MacOS/"]
        .iter()
        .any(|marker| program.contains(marker));
    let name = program.rsplit('/').next()?;
    (built && !name.is_empty() && !name.contains('.')).then(|| name.to_owned())
}

/// One Computer Use call. A trait so tests put a fake worker behind it.
pub(crate) trait Worker {
    fn call(&self, name: &str, arguments: Value) -> Option<ToolOutput>;
}

/// Whether the worker's `status` lets a screenshot through without asking the person.
pub(crate) fn may_capture(status: &Value) -> bool {
    let mode = status.get("mode").and_then(Value::as_str).unwrap_or_default();
    matches!(mode, "fullAccess" | "lookOnly")
        && status.get("screen_locked").and_then(Value::as_bool) != Some(true)
}

/// The front on-screen window of `app` in a `list_windows` answer (front to back): its id. An app
/// matches by its name, its id, or its bundle id's last part.
pub(crate) fn front_window(listed: &Value, app: &str) -> Option<String> {
    let app = app.to_ascii_lowercase();
    let suffix = format!(".{app}");
    listed.get("windows")?.as_array()?.iter().find_map(|w| {
        let field = |k: &str| w.get(k).and_then(Value::as_str).unwrap_or_default().to_ascii_lowercase();
        let flag = |k: &str| w.get(k).and_then(Value::as_bool).unwrap_or(false);
        let (name, id) = (field("app_name"), field("app_id"));
        let ours = name == app || id == app || id.ends_with(&suffix);
        let shown = flag("on_screen") && !flag("minimized") && !flag("denied");
        if !(ours && shown) {
            return None;
        }
        match w.get("window_id")? {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    })
}

/// A PNG of `app`'s front window through `worker`, or why there is none.
pub(crate) fn capture_with(worker: &dyn Worker, app: &str) -> Result<Vec<u8>, &'static str> {
    let ok = |out: Option<ToolOutput>| out.filter(|o| !o.is_error);
    let status = ok(worker.call("status", json!({}))).ok_or("no worker")?;
    if !may_capture(&status.body) {
        return Err("asks first");
    }
    let listed = ok(worker.call("list_windows", json!({}))).ok_or("no window list")?;
    let window = front_window(&listed.body, app).ok_or("no window")?;
    let shot = ok(worker.call("screenshot", json!({"window_id": window, "force": true})))
        .ok_or("refused")?;
    use base64::Engine as _;
    let png = shot.png_base64.as_deref().ok_or("no picture")?;
    base64::engine::general_purpose::STANDARD.decode(png).map_err(|_| "unreadable picture")
}

/// The real worker: its endpoint from the cmux-tui daemon, each call bounded
/// ([`crate::computer_use::client::call_bounded`]), on session `session`.
struct Resident {
    endpoint: crate::computer_use::client::Endpoint,
    session: String,
}

impl Worker for Resident {
    fn call(&self, name: &str, arguments: Value) -> Option<ToolOutput> {
        let request = json!({
            "id": 1,
            "method": "tools/call",
            "name": name,
            "arguments": arguments,
            "session": self.session,
            "label": LABEL,
            "call_id": crate::computer_use::client::new_call_id(),
        });
        let result = crate::computer_use::client::call_bounded(&self.endpoint, &request).ok()?;
        ToolOutput::from_json(&result)
    }
}

/// Writes a PNG of `app`'s front window at `out`, for chat `session`; true when it did. Only on a
/// Mac. Blocking.
pub(crate) fn native_shot(session: &str, app: &str, out: &Path) -> bool {
    use crate::computer_use::client::{Daemon, EndpointState, SocketDaemon};
    if !cfg!(target_os = "macos") {
        return false;
    }
    let Ok(answer) = SocketDaemon::from_env().endpoint() else { return false };
    let EndpointState::Ready(endpoint) = EndpointState::parse(&answer) else { return false };
    let worker = Resident { endpoint, session: format!("acpmux-turn-frames:{session}") };
    capture_with(&worker, app).is_ok_and(|png| {
        png.len() as u64 <= super::turn_frames::MAX_CAPTURE_BYTES
            && crate::home_fs::write(out, &png).is_ok()
    })
}

#[cfg(test)]
#[path = "turn_frames_native_tests.rs"]
mod tests;
