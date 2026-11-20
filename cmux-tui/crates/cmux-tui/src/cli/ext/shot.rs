//! `cmux ext shot [DIR] [--out PATH] [--json]`: one `ext dev --once` reload,
//! then what it rendered, two ways: the view's scene as a text outline (from
//! the load check's first scene, no window needed) and a PNG of the cmux
//! window that shows it (`cmux window screenshot`, the app's own capture: no
//! Screen Recording grant, no focus change). An agent reads the outline and
//! looks at the picture before it says the extension is done.
//!
//! The picture is taken by the same `cmux` in a child process
//! (`window screenshot --out PATH --json`), so it reaches the app the way a
//! person's `cmux window screenshot` does, with the same global options.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::dev::{self, Outcome, Problem};
use super::{DevOptions, Field as _, exit};
use crate::cli::GlobalArgs;

/// `ext shot`'s options: the reload's, and where the PNG goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct ShotOptions {
    pub dev: DevOptions,
    /// `--out PATH`; none: a temporary file the app picks (the reply names it).
    pub out: Option<PathBuf>,
}

/// The picture `window screenshot` took: where, and its size in pixels.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Picture {
    pub path: String,
    pub width: Option<u64>,
    pub height: Option<u64>,
}

/// The first value named `key` in `value`, depth first (the app's run reply
/// nests the capture's result under the run).
fn find<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Object(map) => {
            map.get(key).or_else(|| map.values().find_map(|child| find(child, key)))
        }
        Value::Array(items) => items.iter().find_map(|child| find(child, key)),
        _ => None,
    }
}

/// Reads `window screenshot --json`'s answer: the picture, or why there is none.
pub(super) fn picture_from(status: i32, stdout: &str, stderr: &str) -> Result<Picture, Problem> {
    let reply: Option<Value> = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str(line.trim()).ok())
        .or_else(|| serde_json::from_str(stdout.trim()).ok());
    let path = reply.as_ref().and_then(|r| find(r, "path")).and_then(Value::as_str);
    if let (0, Some(path)) = (status, path) {
        let size = |key| reply.as_ref().and_then(|r| find(r, key)).and_then(Value::as_u64);
        return Ok(Picture {
            path: path.to_string(),
            width: size("width"),
            height: size("height"),
        });
    }
    let said = reply
        .as_ref()
        .and_then(|r| find(r, "reason").or_else(|| find(r, "message")))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| Some(stderr.trim().to_string()).filter(|s| !s.is_empty()))
        .unwrap_or_else(|| format!("cmux window screenshot ended with {status} and no picture"));
    Err(Problem::message(format!("no picture: {said}")))
}

/// The `window screenshot` child's words: the global ones but an output mode
/// (the child's is always `--json`, which another mode cannot join), then the verb.
pub(super) fn screenshot_argv(globals: &[String], out: Option<&Path>) -> Vec<String> {
    let mut argv: Vec<String> = globals
        .iter()
        .filter(|word| !matches!(word.as_str(), "--json" | "--jsonl" | "--quiet"))
        .cloned()
        .collect();
    argv.extend(["window".into(), "screenshot".into()]);
    if let Some(out) = out {
        argv.extend(["--out".into(), out.display().to_string()]);
    }
    argv.push("--json".into());
    argv
}

/// Takes the picture with this same `cmux`.
fn take(globals: &[String], out: Option<&Path>) -> Result<Picture, Problem> {
    let exe = std::env::current_exe()
        .map_err(|error| Problem::message(format!("no picture: cannot find this cmux: {error}")))?;
    let ran = cmux_process::Command::new(exe)
        .args(screenshot_argv(globals, out))
        .stdin(cmux_process::Stdio::null())
        .output()
        .map_err(|error| Problem::message(format!("no picture: {error}")))?;
    picture_from(
        ran.status.code().unwrap_or(1),
        &String::from_utf8_lossy(&ran.stdout),
        &String::from_utf8_lossy(&ran.stderr),
    )
}

/// The interfaces a window always shows once installed: the sidebar's. A
/// pane or a Session Info section shows only where a person opens it.
const ALWAYS_ON_SCREEN: [&str; 2] = ["cmux.section/1", "cmux.sidebar.rows/1"];

/// The placement a window shows now: installed, on, not hidden, in the
/// sidebar (a preview mount renders, but no window shows it).
fn on_screen(outcome: &Outcome) -> Option<&Value> {
    if outcome.installed != Some(true) {
        return None;
    }
    outcome.placed.iter().find(|place| {
        place.field("shown").as_bool() == Some(true)
            && place.field("interface").as_str().is_some_and(|i| ALWAYS_ON_SCREEN.contains(&i))
    })
}

/// Whether a window shows the extension now ([`on_screen`]).
pub(super) fn shown(outcome: &Outcome) -> bool {
    on_screen(outcome).is_some()
}

/// What `ext shot` prints and exits with, from the reload and the picture.
pub(super) fn report(
    outcome: &Outcome,
    dir: &Path,
    picture: Option<&Result<Picture, Problem>>,
    json_out: bool,
) -> (String, i32) {
    let code = match picture {
        _ if !outcome.ok() => outcome.exit_code(),
        Some(Ok(_)) => exit::OK,
        _ => exit::SHOT_FAILED,
    };
    let not_shown = || {
        match &outcome.next {
        Some(next) => next.clone(),
        None if outcome.installed == Some(true) && outcome.placed.iter().any(|place| {
            place.field("interface").as_str().is_some_and(|i| ALWAYS_ON_SCREEN.contains(&i))
        }) =>
        {
            "no window shows it now (its section is hidden)".to_string()
        }
        None => "it is not in the sidebar, so no window shows it until it is opened; the outline is what it rendered".to_string(),
    }
    };
    if json_out {
        let mut value = outcome.to_json(dir);
        let shot = match picture {
            Some(Ok(p)) => json!({ "path": p.path, "width": p.width, "height": p.height }),
            Some(Err(problem)) => json!({ "error": problem.text() }),
            None if outcome.ok() => json!({ "error": format!("no picture: {}", not_shown()) }),
            None => Value::Null,
        };
        if let Some(object) = value.as_object_mut() {
            object.insert("ok".into(), json!(code == exit::OK));
            object.insert("exitCode".into(), json!(code));
            if outcome.ok() && code != exit::OK {
                object.insert("phase".into(), json!("shot"));
            }
            object.insert("shot".into(), shot);
        }
        return (value.to_string(), code);
    }
    let mut text = outcome.line();
    if !outcome.scene.is_empty() {
        text.push_str(&format!("\nrendered {}:", outcome.probe.as_deref().unwrap_or("the view")));
        for line in &outcome.scene {
            text.push_str("\n  ");
            text.push_str(line);
        }
    }
    match picture {
        Some(Ok(p)) => {
            let size = match (p.width, p.height) {
                (Some(w), Some(h)) => format!(" ({w}x{h})"),
                _ => String::new(),
            };
            let place = on_screen(outcome)
                .and_then(|place| place.field("where").as_str())
                .map(|place| format!("; the extension is in the {place}"))
                .unwrap_or_default();
            text.push_str(&format!("\npicture of the window{size}: {}{place}", p.path));
        }
        Some(Err(problem)) => text.push_str(&format!("\n{}", problem.text())),
        None if outcome.ok() => text.push_str(&format!("\nno picture: {}", not_shown())),
        None => {}
    }
    (text, code)
}

/// `ext shot`: reload once, outline the scene, take the picture.
pub(super) fn run(
    global: &GlobalArgs,
    options: &ShotOptions,
    globals: &[String],
    json_out: bool,
) -> i32 {
    let dir = options.dev.dir.clone();
    let outcome = dev::once(global, &options.dev, true);
    let picture = (outcome.ok() && shown(&outcome)).then(|| take(globals, options.out.as_deref()));
    let (text, code) = report(&outcome, &dir, picture.as_ref(), json_out);
    println!("{text}");
    code
}
