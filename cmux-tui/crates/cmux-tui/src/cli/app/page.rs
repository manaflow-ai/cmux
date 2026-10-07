//! `cmux browser <tab_…|page> <verb> …`: page commands for a browser tab the
//! app hosts (`page` is the focused tab), served by the app's
//! `browser.page.*` control methods (CmuxNextControl BrowserPageService). A
//! daemon browser (`browser_…`) is the mux grammar's.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Map, Value, json};

use super::{AppCommand, Options, READ_TIMEOUT, failure};
use crate::cli::{OutputMode, UsageError};

/// `browser.page.wait` answers by its own timeout (default 5 s, the old
/// `cmux browser wait`); the CLI waits that long plus this margin.
const DEFAULT_WAIT_MS: u64 = 5_000;
const WAIT_MARGIN: Duration = Duration::from_secs(5);
/// The app gives a screenshot 30 s (a full page is captured tile by tile).
pub(super) const SCREENSHOT_TIMEOUT: Duration = Duration::from_secs(35);

pub(super) fn parse_page(target: &str, args: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let usage = || UsageError::new(messages.browser_page_usage);
    let Some((verb, rest)) = args.split_first() else { return Err(usage()) };
    let mut params = Map::new();
    if target != "page" {
        params.insert("tab".into(), json!(target));
    }
    let words: Vec<&String> = rest.iter().filter(|arg| !arg.starts_with("--")).collect();
    let mut timeout = READ_TIMEOUT;
    let method = match (verb.as_str(), words.as_slice()) {
        ("navigate" | "goto" | "open", [url]) => {
            params.insert("url".into(), json!(url));
            "browser.page.navigate"
        }
        ("back", []) => "browser.page.back",
        ("forward", []) => "browser.page.forward",
        ("reload", []) => "browser.page.reload",
        ("state" | "url" | "title", []) => "browser.page.state",
        ("eval", [script]) => {
            params.insert("script".into(), json!(script));
            "browser.page.eval"
        }
        ("snapshot", _) => {
            let options = Options::parse(rest, &["selector", "max-depth"], &["interactive"])?;
            if let Some(selector) = options.value("selector") {
                params.insert("selector".into(), json!(selector));
            }
            if let Some(depth) = options.value("max-depth") {
                let depth: u32 = depth.parse().map_err(|_| usage())?;
                params.insert("max_depth".into(), json!(depth));
            }
            if options.flag("interactive") {
                params.insert("interactive".into(), json!(true));
            }
            "browser.page.snapshot"
        }
        ("wait", _) => {
            let timeout_ms = parse_wait(rest, &mut params, usage)?;
            timeout = Duration::from_millis(timeout_ms.unwrap_or(DEFAULT_WAIT_MS)) + WAIT_MARGIN;
            "browser.page.wait"
        }
        ("screenshot", _) => {
            let options = Options::parse(rest, &["out", "selector"], &["full-page"])?;
            if options.value("selector").is_some() && options.flag("full-page") {
                return Err(usage());
            }
            if let Some(selector) = options.value("selector") {
                params.insert("selector".into(), json!(selector));
            }
            if options.flag("full-page") {
                params.insert("full_page".into(), json!(true));
            }
            let out = options.value("out").map(str::to_owned);
            return Ok(AppCommand::Screenshot { params: Value::Object(params), out });
        }
        ("click" | "focus" | "text" | "value", [selector]) => {
            params.insert("selector".into(), json!(selector));
            match verb.as_str() {
                "click" => "browser.page.click",
                "focus" => "browser.page.focus",
                "text" => "browser.page.text",
                _ => "browser.page.value",
            }
        }
        ("fill" | "type", [selector, text]) => {
            params.insert("selector".into(), json!(selector));
            params.insert("text".into(), json!(text));
            if verb == "fill" { "browser.page.fill" } else { "browser.page.type" }
        }
        ("cookies", _) => cookies(rest, &mut params, usage)?,
        ("storage", _) => storage(rest, &mut params).ok_or_else(usage)?,
        _ => return Err(usage()),
    };
    if !matches!(verb.as_str(), "snapshot" | "wait" | "cookies" | "storage")
        && words.len() != rest.len()
    {
        return Err(usage());
    }
    Ok(AppCommand::Call {
        method,
        params: Value::Object(params),
        timeout: Some(timeout),
        pick: None,
    })
}

/// `wait [SELECTOR] [--selector S] …`: one condition, chosen by the app.
/// Fills `params` and returns the wait's own `timeout_ms`, if given.
fn parse_wait(
    rest: &[String],
    params: &mut Map<String, Value>,
    usage: impl Fn() -> UsageError,
) -> Result<Option<u64>, UsageError> {
    let (selector, flags) = match rest.split_first() {
        Some((first, flags)) if !first.starts_with("--") => (Some(first.as_str()), flags),
        _ => (None, rest),
    };
    let valued = [
        "selector",
        "text",
        "url-contains",
        "url",
        "load-state",
        "function",
        "timeout-ms",
        "timeout",
    ];
    let options = Options::parse(flags, &valued, &[])?;
    if let Some(selector) = options.value("selector").or(selector) {
        params.insert("selector".into(), json!(selector));
    }
    for (flag, key) in [
        ("text", "text_contains"),
        ("url", "url_contains"),
        ("url-contains", "url_contains"),
        ("load-state", "load_state"),
        ("function", "function"),
    ] {
        if let Some(value) = options.value(flag) {
            params.insert(key.into(), json!(value));
        }
    }
    let timeout_ms = match (options.value("timeout-ms"), options.value("timeout")) {
        (Some(ms), _) => Some(ms.parse::<u64>().map_err(|_| usage())?),
        (None, Some(seconds)) => {
            let seconds = seconds.parse::<f64>().map_err(|_| usage())?;
            if !seconds.is_finite() || seconds < 0.0 {
                return Err(usage());
            }
            Some(((seconds * 1000.0) as u64).max(1))
        }
        (None, None) => None,
    };
    if let Some(timeout_ms) = timeout_ms {
        params.insert("timeout_ms".into(), json!(timeout_ms));
    }
    Ok(timeout_ms)
}

/// Leading words, then `--flags`.
fn split_words(args: &[String]) -> (&[String], &[String]) {
    args.split_at(args.iter().position(|arg| arg.starts_with("--")).unwrap_or(args.len()))
}

/// `cookies [get] [--name N] [--domain D] [--path P]`,
/// `cookies set NAME VALUE [--url U | --domain D] [--path P] [--expires UNIX] [--secure] [--http-only]`,
/// `cookies clear [--name N] [--url U] [--domain D] [--path P]` (the app refuses `--all`).
fn cookies(
    args: &[String],
    params: &mut Map<String, Value>,
    usage: impl Fn() -> UsageError,
) -> Result<&'static str, UsageError> {
    let (words, flags) = split_words(args);
    let (action, words) = match words.split_first() {
        Some((action, words)) => (action.as_str(), words),
        None => ("get", words),
    };
    let (valued, switches): (&[&str], &[&str]) = match action {
        "get" => (&["name", "domain", "path"], &[]),
        "set" => (&["name", "value", "url", "domain", "path", "expires"], &["secure", "http-only"]),
        "clear" => (&["name", "url", "domain", "path"], &["all"]),
        _ => return Err(usage()),
    };
    let options = Options::parse(flags, valued, switches)?;
    match (action, words) {
        ("set", [name, value]) => {
            params.insert("name".into(), json!(name));
            params.insert("value".into(), json!(value));
        }
        ("set", []) if options.value("name").is_some() && options.value("value").is_some() => {}
        (_, []) if action != "set" => {}
        _ => return Err(usage()),
    }
    for key in valued {
        let Some(value) = options.value(key) else { continue };
        let value = if *key == "expires" {
            json!(value.parse::<i64>().map_err(|_| usage())?)
        } else {
            json!(value)
        };
        params.insert((*key).into(), value);
    }
    for key in switches {
        if options.flag(key) {
            params.insert(key.replace('-', "_"), json!(true));
        }
    }
    Ok(match action {
        "get" => "browser.page.cookies.get",
        "set" => "browser.page.cookies.set",
        _ => "browser.page.cookies.clear",
    })
}

/// `storage [local|session] [get [KEY] | set KEY VALUE | clear]`.
fn storage(args: &[String], params: &mut Map<String, Value>) -> Option<&'static str> {
    let mut words = args;
    if let Some((area, rest)) = words.split_first()
        && matches!(area.as_str(), "local" | "session")
    {
        params.insert("type".into(), json!(area));
        words = rest;
    }
    match words {
        [] => Some("browser.page.storage.get"),
        [get] if get == "get" => Some("browser.page.storage.get"),
        [get, key] if get == "get" => {
            params.insert("key".into(), json!(key));
            Some("browser.page.storage.get")
        }
        [set, key, value] if set == "set" => {
            params.insert("key".into(), json!(key));
            params.insert("value".into(), json!(value));
            Some("browser.page.storage.set")
        }
        [clear] if clear == "clear" => Some("browser.page.storage.clear"),
        _ => None,
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    matches!((std::fs::canonicalize(a), std::fs::canonicalize(b)), (Ok(a), Ok(b)) if a == b)
}

/// Puts a `browser.page.screenshot` PNG where `out` says and prints where it
/// went: the path, or with `--json` the result without the image data.
/// The app saves the PNG to a file and returns its `path` (the old `cmux
/// browser screenshot` did too); `png_base64` comes inline only when small.
/// Without `--out` the app's file is the result; `--out -` writes only the
/// PNG to stdout.
pub(super) fn save_screenshot(mut result: Value, out: Option<&str>, output: OutputMode) -> i32 {
    let messages = &crate::localization::catalog().app_control;
    let invalid = || failure("app.invalid_response", messages.invalid_response, output, 3);
    let Some(object) = result.as_object_mut() else { return invalid() };
    let inline = object.remove("png_base64");
    let saved = object.get("path").and_then(Value::as_str).map(PathBuf::from);
    let inline = match inline.as_ref().and_then(Value::as_str).map(|data| BASE64.decode(data)) {
        Some(Ok(png)) => Some(png),
        Some(Err(_)) => return invalid(),
        None => None,
    };
    let source = match (inline, saved) {
        (Some(png), _) => Source::Inline(png),
        (None, Some(saved)) => Source::File(saved),
        (None, None) => return invalid(),
    };
    let write_failed = |path: &Path, error: std::io::Error| {
        let message = messages
            .screenshot_write_failed
            .replace("{path}", &path.display().to_string())
            .replace("{error}", &error.to_string());
        failure("io.write_failed", &message, output, 1)
    };
    if out == Some("-") {
        let png = match source {
            Source::Inline(png) => png,
            Source::File(saved) => match std::fs::read(&saved) {
                Ok(png) => png,
                Err(error) => return write_failed(&saved, error),
            },
        };
        let mut stdout = std::io::stdout().lock();
        return match stdout.write_all(&png).and_then(|()| stdout.flush()) {
            Ok(()) => 0,
            Err(_) => 3,
        };
    }
    let path = match (out, source) {
        (None, Source::File(saved)) => saved,
        (target, source) => {
            let path = target.map_or_else(new_screenshot_path, PathBuf::from);
            let created = path
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
                .map_or(Ok(()), std::fs::create_dir_all);
            let written = created.and_then(|()| match &source {
                Source::Inline(png) => std::fs::write(&path, png),
                // Copying a file onto itself truncates it first.
                Source::File(saved) if same_file(saved, &path) => Ok(()),
                Source::File(saved) => std::fs::copy(saved, &path).map(|_| ()),
            });
            if let Err(error) = written {
                return write_failed(&path, error);
            }
            path
        }
    };
    let path = std::fs::canonicalize(&path).unwrap_or(path).display().to_string();
    match output {
        OutputMode::Human => super::super::wire::print_local_success(&Value::String(path), output),
        _ => {
            result["path"] = json!(path);
            super::super::wire::print_local_success(&result, output)
        }
    }
}

/// Where the app's answer has the PNG.
enum Source {
    Inline(Vec<u8>),
    File(PathBuf),
}

/// A new file in the temporary directory, for inline data without `--out`.
fn new_screenshot_path() -> PathBuf {
    let name = super::super::command::random_prefixed("screenshot")
        .unwrap_or_else(|_| format!("screenshot-{}", std::process::id()));
    std::env::temp_dir().join("cmux-browser-screenshots").join(format!("{name}.png"))
}
