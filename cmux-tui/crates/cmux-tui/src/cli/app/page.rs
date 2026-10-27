//! `cmux browser <tab_…|page> <verb> …`: page commands for a browser tab the
//! cmux app hosts, sent as `browser.page.*` app control methods, and where a
//! screenshot's PNG is written. Kept out of app.rs for its line budget.

use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Map, Value, json};

use super::super::OutputMode;
use super::{AppCommand, Options, READ_TIMEOUT, UsageError, WAITING_RUN_TIMEOUT, failure};

/// `browser.page.wait` answers by its own timeout (default 5 s, the old
/// `cmux browser wait`); the CLI waits that long plus this margin.
const DEFAULT_WAIT_MS: u64 = 5_000;
pub(super) const WAIT_MARGIN: Duration = Duration::from_secs(5);
/// The app gives a screenshot 30 s (a full page is captured tile by tile).
pub(super) const SCREENSHOT_TIMEOUT: Duration = Duration::from_secs(35);

/// `cmux browser <tab_…|page> <verb> …`: page commands for a browser tab the
/// app hosts (`page` is the focused tab). A daemon browser (`browser_…`) is
/// the mux grammar's.
pub(super) fn parse_page(target: &str, args: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let usage = || UsageError::new(messages.browser_page_usage);
    let (args, agent) = take_agent(args).ok_or_else(usage)?;
    let agent = agent.or_else(|| agent_from_env(|key| std::env::var(key).ok()));
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
            // `wait [SELECTOR] [--selector S] …`: one condition, chosen by the app.
            let (selector, flags) = match rest.split_first() {
                Some((first, flags)) if !first.starts_with("--") => (Some(first.as_str()), flags),
                _ => (None, rest),
            };
            let options = Options::parse(
                flags,
                &[
                    "selector",
                    "text",
                    "url-contains",
                    "url",
                    "load-state",
                    "function",
                    "timeout-ms",
                    "timeout",
                ],
                &[],
            )?;
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
        // An agent at a passkey step asks the person: the app brings the tab forward on
        // their click, then clicks SELECTOR (plans/cmux-next/agent-browser-passkey-DESIGN.md).
        ("passkey", [] | [_]) => {
            if let [selector] = words.as_slice() {
                params.insert("selector".into(), json!(selector));
            }
            "browser.page.passkey"
        }
        // `fill-login [--submit]`: the app fills the login the person saved for the tab's site
        // (the Secure Store) into the page itself; the answer says only what it filled, never
        // the username or the password.
        ("fill-login" | "fill_login", []) => {
            if Options::parse(rest, &[], &["submit"])?.flag("submit") {
                params.insert("submit".into(), json!(true));
            }
            "browser.page.fill_login"
        }
        ("tabs", []) => {
            if Options::parse(rest, &[], &["all"])?.flag("all") {
                params.insert("all".into(), json!(true));
            }
            "browser.page.tabs"
        }
        // These run the app's tab actions and wait for them unless `--no-wait`,
        // as `action run` does.
        ("new-tab", [] | [_]) | ("select" | "switch" | "close", []) => {
            if let [url] = words.as_slice() {
                params.insert("url".into(), json!(url));
            }
            let flags: Vec<String> =
                rest.iter().filter(|arg| arg.starts_with("--")).cloned().collect();
            if Options::parse(&flags, &[], &["wait", "no-wait"])?.flag("no-wait") {
                params.insert("wait".into(), json!(false));
            } else {
                timeout = WAITING_RUN_TIMEOUT;
            }
            match verb.as_str() {
                "new-tab" => "browser.page.new_tab",
                "close" => "browser.page.close",
                _ => "browser.page.select_tab",
            }
        }
        // After the tab verbs: `select` with words is `select SELECTOR VALUE`.
        (
            "hover" | "scroll-into-view" | "scrollintoview" | "scrollinto" | "check" | "uncheck"
            | "select" | "press" | "key" | "scroll",
            _,
        ) => input_verb(verb, rest, &mut params).ok_or_else(usage)??,
        ("drag", [selector, target]) => {
            params.insert("selector".into(), json!(selector));
            params.insert("target".into(), json!(target));
            "browser.page.drag"
        }
        // `upload SELECTOR FILE… [--timeout-ms N]`: the app clicks SELECTOR and answers the page's file
        // chooser with the files (N: how long the chooser may take to open, default 3 s).
        ("upload", _) => {
            let (words, options) = words_and_options(rest, &["timeout-ms"], &[])?;
            let [selector, files @ ..] = words.as_slice() else { return Err(usage()) };
            if files.is_empty() {
                return Err(usage());
            }
            params.insert("selector".into(), json!(selector));
            let files: Vec<String> = files.iter().map(|file| absolute(file)).collect();
            params.insert("files".into(), json!(files));
            let ms = match options.value("timeout-ms") {
                Some(ms) => {
                    let ms: u64 = ms.parse().map_err(|_| usage())?;
                    params.insert("timeout_ms".into(), json!(ms));
                    ms
                }
                None => DEFAULT_CHOOSER_WAIT_MS,
            };
            // The app may first wait for the page's load, then the chooser, then the page-script fallback.
            timeout = UPLOAD_MARGIN + Duration::from_millis(ms);
            "browser.page.upload"
        }
        // `download list [--limit N]`, `download [wait] [--id ID] [--path P] [--timeout-ms N]` (the old
        // CLI's verbs): the app's downloads, this tab's (`page`: every tab's).
        ("download" | "downloads", _) => {
            download(rest, &mut params, &mut timeout).ok_or_else(usage)??
        }
        // `mirror [--pane P] [--off]`: the tab shows in a second pane too (default: right of the
        // Home chat), the same live page (plans/cmux-next/shared-browser-tabs.md).
        ("mirror", _) => {
            let (words, options) = words_and_options(rest, &["pane"], &["off"])?;
            if !words.is_empty() {
                return Err(usage());
            }
            if let Some(pane) = options.value("pane") {
                params.insert("pane".into(), json!(pane));
            }
            if options.flag("off") {
                params.insert("off".into(), json!(true));
            }
            "browser.page.mirror"
        }
        ("cookies", _) => cookies(rest, &mut params).ok_or_else(usage)??,
        ("storage", _) => storage(rest, &mut params).ok_or_else(usage)?,
        _ => return Err(usage()),
    };
    let flagged = [
        "snapshot",
        "wait",
        "tabs",
        "new-tab",
        "select",
        "switch",
        "close",
        "hover",
        "scroll-into-view",
        "scrollintoview",
        "scrollinto",
        "check",
        "uncheck",
        "press",
        "key",
        "scroll",
        "cookies",
        "storage",
        "upload",
        "download",
        "downloads",
        "mirror",
        "fill-login",
        "fill_login",
    ];
    if !flagged.contains(&verb.as_str()) && words.len() != rest.len() {
        return Err(usage());
    }
    if let Some(agent) = agent
        && AGENT_METHODS.contains(&method)
    {
        params.insert("agent".into(), json!(agent));
    }
    Ok(AppCommand::Call {
        method,
        params: Value::Object(params),
        timeout: Some(timeout),
        pick: None,
    })
}

/// The page methods an agent's input goes through: they take `agent`, the
/// name its cursor shows.
const AGENT_METHODS: &[&str] = &[
    "browser.page.passkey",
    "browser.page.click",
    "browser.page.focus",
    "browser.page.fill",
    "browser.page.fill_login",
    "browser.page.type",
    "browser.page.hover",
    "browser.page.check",
    "browser.page.uncheck",
    "browser.page.select",
    "browser.page.press",
    "browser.page.scroll",
    "browser.page.drag",
    "browser.page.upload",
];

/// The methods the CLI names its caller on: [`super::CALLER_METHODS`], and
/// every page input verb, so the agent cursor's tag says who drives and where
/// and a click on it goes there (user, 2026-10-20).
pub(super) fn takes_caller(method: &str) -> bool {
    super::CALLER_METHODS.contains(&method) || AGENT_METHODS.contains(&method)
}

/// `--agent NAME` (or `--agent=NAME`) anywhere in `args`, taken out; None
/// when the flag has no name.
pub(super) fn take_agent(args: &[String]) -> Option<(Vec<String>, Option<String>)> {
    let (mut kept, mut agent) = (Vec::with_capacity(args.len()), None);
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if arg == "--agent" {
            let name = args.get(index + 1)?;
            agent = Some(name.clone());
            index += 2;
            continue;
        }
        if let Some(name) = arg.strip_prefix("--agent=") {
            agent = Some(name.to_owned());
        } else {
            kept.push(arg.clone());
        }
        index += 1;
    }
    let agent = agent.map(|name| name.trim().to_owned());
    if agent.as_deref() == Some("") {
        return None;
    }
    Some((kept, agent))
}

/// The agent's name when the caller gave none: `CMUX_AGENT_NAME`, else
/// Claude (`CLAUDECODE`) or Codex (`CODEX_SANDBOX`, `CODEX_THREAD_ID`).
pub(super) fn agent_from_env(get: impl Fn(&str) -> Option<String>) -> Option<String> {
    if let Some(name) = get("CMUX_AGENT_NAME") {
        let name = name.trim();
        return (!name.is_empty()).then(|| name.to_owned());
    }
    if get("CLAUDECODE").is_some_and(|value| !value.is_empty()) {
        return Some("Claude".into());
    }
    if get("CODEX_SANDBOX")
        .or_else(|| get("CODEX_THREAD_ID"))
        .is_some_and(|value| !value.is_empty())
    {
        return Some("Codex".into());
    }
    None
}

/// Positional words and `--flags` in any order; a valued flag takes the next word.
fn words_and_options(
    args: &[String],
    valued: &[&str],
    flags: &[&str],
) -> Result<(Vec<String>, Options), UsageError> {
    let (mut words, mut options) = (Vec::new(), Vec::new());
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        match arg.strip_prefix("--") {
            Some(name) => {
                options.push(arg.clone());
                if valued.contains(&name) && index + 1 < args.len() {
                    options.push(args[index + 1].clone());
                    index += 1;
                }
            }
            None => words.push(arg.clone()),
        }
        index += 1;
    }
    Ok((words, Options::parse(&options, valued, flags)?))
}

/// `hover|check|uncheck|scroll-into-view SELECTOR`, `select SELECTOR VALUE`,
/// `press KEY`, `scroll [SELECTOR|DY] [--dx N] [--dy N]`. Each positional
/// also takes the old CLI's flag (`--selector`, `--value`, `--key`). None is
/// a usage error.
fn input_verb(
    verb: &str,
    args: &[String],
    params: &mut Map<String, Value>,
) -> Option<Result<&'static str, UsageError>> {
    let (words, options) =
        match words_and_options(args, &["selector", "value", "key", "dx", "dy"], &[]) {
            Ok(parsed) => parsed,
            Err(error) => return Some(Err(error)),
        };
    let mut words = words.into_iter();
    let mut take = |flag: &str| options.value(flag).map(str::to_owned).or_else(|| words.next());
    let (method, needs): (&'static str, &[&str]) = match verb {
        "hover" => ("browser.page.hover", &["selector"]),
        "check" => ("browser.page.check", &["selector"]),
        "uncheck" => ("browser.page.uncheck", &["selector"]),
        "select" => ("browser.page.select", &["selector", "value"]),
        "press" | "key" => ("browser.page.press", &["key"]),
        "scroll" => ("browser.page.scroll", &[]),
        _ => ("browser.page.scroll_into_view", &["selector"]),
    };
    for key in needs {
        params.insert((*key).into(), json!(take(key)?));
    }
    if method == "browser.page.press"
        && let Some(selector) = options.value("selector")
    {
        params.insert("selector".into(), json!(selector));
    }
    if method == "browser.page.scroll" {
        // The old `scroll N` scrolled by N down; any other word is a selector.
        let mut dy = options.value("dy").map(str::to_owned);
        let mut selector = options.value("selector").map(str::to_owned);
        if let Some(word) = words.next() {
            match word.parse::<f64>() {
                Ok(_) if dy.is_none() => dy = Some(word),
                _ if selector.is_none() => selector = Some(word),
                _ => return None,
            }
        }
        if let Some(selector) = selector {
            params.insert("selector".into(), json!(selector));
        }
        for (key, offset) in [("dx", options.value("dx").map(str::to_owned)), ("dy", dy)] {
            let Some(offset) = offset else { continue };
            let offset: f64 = offset.parse().ok().filter(|offset: &f64| offset.is_finite())?;
            params.insert(key.into(), json!(offset));
        }
        if !params.contains_key("dx") && !params.contains_key("dy") {
            return None;
        }
    } else if options.value("dx").or(options.value("dy")).is_some() {
        return None;
    }
    if words.next().is_some() {
        return None;
    }
    Some(Ok(method))
}

fn same_file(a: &std::path::Path, b: &std::path::Path) -> bool {
    matches!((std::fs::canonicalize(a), std::fs::canonicalize(b)), (Ok(a), Ok(b)) if a == b)
}

/// Where a screenshot's PNG bytes are: inline in the result, or in the file the app saved.
enum ScreenshotSource {
    Inline(Vec<u8>),
    Saved(PathBuf),
}

/// Puts a `browser.page.screenshot` PNG where `out` says and prints where it
/// went: the path, or with `--json` the result without the image data.
/// The app saves the PNG to a file and returns its `path` (the old `cmux
/// browser screenshot` did too); `png_base64` comes inline only when small.
/// Without `--out` the app's file is the result; `--out -` writes only the
/// PNG to stdout.
pub(super) fn save_screenshot(mut result: Value, out: Option<&str>, output: OutputMode) -> i32 {
    let messages = &crate::localization::catalog().app_control;
    let Some(object) = result.as_object_mut() else {
        return failure("app.invalid_response", messages.invalid_response, output, 3);
    };
    let inline = object.remove("png_base64");
    let saved = object.get("path").and_then(Value::as_str).map(PathBuf::from);
    let inline = match inline.as_ref().and_then(Value::as_str).map(|data| BASE64.decode(data)) {
        Some(Ok(png)) => Some(png),
        Some(Err(_)) => {
            return failure("app.invalid_response", messages.invalid_response, output, 3);
        }
        None => None,
    };
    // The PNG comes inline or as the app's saved file; a result with neither is invalid.
    let source = match (inline, saved.clone()) {
        (Some(png), _) => ScreenshotSource::Inline(png),
        (None, Some(saved)) => ScreenshotSource::Saved(saved),
        (None, None) => {
            return failure("app.invalid_response", messages.invalid_response, output, 3);
        }
    };
    let write_failed = |path: &std::path::Path, error: std::io::Error| {
        let message = messages
            .screenshot_write_failed
            .replace("{path}", &path.display().to_string())
            .replace("{error}", &error.to_string());
        failure("io.write_failed", &message, output, 1)
    };
    if out == Some("-") {
        let png = match source {
            ScreenshotSource::Inline(png) => png,
            ScreenshotSource::Saved(saved) => match std::fs::read(&saved) {
                Ok(png) => png,
                Err(error) => return write_failed(saved.as_path(), error),
            },
        };
        let mut stdout = std::io::stdout().lock();
        return match stdout.write_all(&png).and_then(|()| stdout.flush()) {
            Ok(()) => 0,
            Err(_) => 3,
        };
    }
    let path = match (out, &saved) {
        (None, Some(saved)) => saved.clone(),
        (target, _) => {
            let path = match target {
                Some(path) => PathBuf::from(path),
                None => {
                    let name = super::super::command::random_prefixed("screenshot")
                        .unwrap_or_else(|_| format!("screenshot-{}", std::process::id()));
                    std::env::temp_dir()
                        .join("cmux-browser-screenshots")
                        .join(format!("{name}.png"))
                }
            };
            let created = path
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
                .map_or(Ok(()), std::fs::create_dir_all);
            let written = created.and_then(|()| match &source {
                ScreenshotSource::Inline(png) => std::fs::write(&path, png),
                // Copying a file onto itself truncates it first.
                ScreenshotSource::Saved(saved) if same_file(saved, &path) => Ok(()),
                ScreenshotSource::Saved(saved) => std::fs::copy(saved, &path).map(|_| ()),
            });
            if let Err(error) = written {
                return write_failed(path.as_path(), error);
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

/// `path` against the working directory: the app resolves no relative path.
fn absolute(path: &str) -> String {
    std::env::current_dir().unwrap_or_default().join(path).to_string_lossy().into_owned()
}

/// How long the app gives a chooser to open after an upload's click, by default.
const DEFAULT_CHOOSER_WAIT_MS: u64 = 3_000;
/// An upload's time besides the chooser wait: the page's first load (15 s at most) and the fallback.
const UPLOAD_MARGIN: Duration = Duration::from_secs(30);

/// A download wait's own default (the app's `browser.page.download.wait`).
const DEFAULT_DOWNLOAD_WAIT_MS: u64 = 30_000;

/// `download list [--limit N]` and `download [wait] [--id ID] [--path P] [--timeout-ms N]`. None is a
/// usage error.
fn download(
    args: &[String],
    params: &mut Map<String, Value>,
    timeout: &mut Duration,
) -> Option<Result<&'static str, UsageError>> {
    let (words, options) =
        match words_and_options(args, &["limit", "id", "path", "timeout-ms"], &[]) {
            Ok(parsed) => parsed,
            Err(error) => return Some(Err(error)),
        };
    match words.as_slice() {
        [list] if list == "list" || list == "ls" => {
            if ["id", "path", "timeout-ms"].iter().any(|flag| options.value(flag).is_some()) {
                return None;
            }
            if let Some(limit) = options.value("limit") {
                params.insert("limit".into(), json!(limit.parse::<u32>().ok()?));
            }
            Some(Ok("browser.page.downloads"))
        }
        [] | [_] if words.first().is_none_or(|word| word == "wait") => {
            if options.value("limit").is_some() {
                return None;
            }
            if let Some(id) = options.value("id") {
                params.insert("id".into(), json!(id));
            }
            if let Some(path) = options.value("path") {
                params.insert("path".into(), json!(absolute(path)));
            }
            let ms = match options.value("timeout-ms") {
                Some(ms) => ms.parse::<u64>().ok()?,
                None => DEFAULT_DOWNLOAD_WAIT_MS,
            };
            params.insert("timeout_ms".into(), json!(ms));
            *timeout = Duration::from_millis(ms) + WAIT_MARGIN;
            Some(Ok("browser.page.download.wait"))
        }
        _ => None,
    }
}

/// Leading words, then `--flags`.
fn split_words(args: &[String]) -> (&[String], &[String]) {
    args.split_at(args.iter().position(|arg| arg.starts_with("--")).unwrap_or(args.len()))
}

/// `cookies [get|clear] [--name N] [--value V] [--url U] [--domain D] [--path P]
/// [--expires UNIX] [--secure] [--http-only]` (the old filters; the app refuses
/// `clear --all`), `cookies set NAME VALUE [--url U | --domain D] [--path P]
/// [--expires UNIX] [--secure] [--http-only]`. None is a usage error.
fn cookies(
    args: &[String],
    params: &mut Map<String, Value>,
) -> Option<Result<&'static str, UsageError>> {
    let (words, flags) = split_words(args);
    let (action, words) = match words.split_first() {
        Some((action, words)) => (action.as_str(), words),
        None => ("get", words),
    };
    let valued: &[&str] = &["name", "value", "url", "domain", "path", "expires"];
    let switches: &[&str] = match action {
        "get" | "set" => &["secure", "http-only"],
        "clear" => &["secure", "http-only", "all"],
        _ => return None,
    };
    let options = match Options::parse(flags, valued, switches) {
        Ok(options) => options,
        Err(error) => return Some(Err(error)),
    };
    match (action, words) {
        ("set", [name, value]) => {
            params.insert("name".into(), json!(name));
            params.insert("value".into(), json!(value));
        }
        ("set", []) if options.value("name").is_some() && options.value("value").is_some() => {}
        (_, []) if action != "set" => {}
        _ => return None,
    }
    for key in valued {
        let Some(value) = options.value(key) else { continue };
        let value =
            if *key == "expires" { json!(value.parse::<i64>().ok()?) } else { json!(value) };
        params.insert((*key).into(), value);
    }
    for key in switches {
        if options.flag(key) {
            params.insert(key.replace('-', "_"), json!(true));
        }
    }
    Some(Ok(match action {
        "get" => "browser.page.cookies.get",
        "set" => "browser.page.cookies.set",
        _ => "browser.page.cookies.clear",
    }))
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

#[cfg(test)]
#[path = "page_browser_use_tests.rs"]
mod browser_use_tests;
