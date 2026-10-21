//! `cmux setup browser-import --browser BROWSER [--cookies [--domain D]
//! [--reason TEXT]] [--dry-run]`: brings the person's bookmarks, or with
//! `--cookies` their sign-ins, from another browser on this Mac into cmux.
//!
//! Bookmarks are not secrets: the app's `bookmark.importFromBrowser` reads
//! every readable profile of the browser into one "Imported from ..." folder
//! on the Bookmarks Bar per profile, tagged with `source_key`
//! `<browser id>/<profile folder>`. The state is `bookmark.list`: a folder
//! of that browser there is `ok` and nothing runs; otherwise setup imports,
//! reads the list again, and the undo removes each new folder
//! (`cmux bookmark remove --target bookmark:<id>`).
//!
//! Cookies are the person's: `browser.importCookies` shows them a consent
//! panel that names the reason, then macOS asks for the browser's Keychain
//! key. The app reads no imported cookies back, so a cookie run is never
//! `ok` (running it again asks again), and it has no undo: clearing the
//! profile's cookies would clear every cookie, not only the imported ones.
//!
//! History and passwords come in only when the person runs Import from
//! Browser... in cmux; every result names that in `person`.
//!
//! The app serves all of it, so without the app the task says to open it;
//! off macOS, where there is no cmux app, it is `not_applicable`.

use serde_json::{Map, Value, json};

use super::super::GlobalArgs;
use super::super::app::{ActionName, READ_TIMEOUT, action_origin, action_run_params};
use super::{Outcome, Refusal};

const TASK: &str = "browser_import";

/// The registry of browsers the app imports from (ids and product names),
/// the same file the app reads.
const REGISTRY: &str = include_str!(
    "../../../../../../Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Resources/browser-sources.json"
);

/// The command that shows the person the app's picker of found browsers.
const PICKER: &str = "cmux action run bookmark.importFromBrowser";

/// What only the person brings in, from the app's own Import from Browser.
const PERSON: &str = "History and passwords come in only when the person runs Import from \
                      Browser... in cmux (File menu or the command palette)";

/// The reason the consent panel shows when the agent gives none.
const DEFAULT_REASON: &str = "cmux setup browser-import: use your sign-ins in cmux's browser";

const COOKIES_UNDO_NOTE: &str = "Imported cookies have no undo: clearing the browser profile's \
                                 cookies would clear every cookie, not only the imported ones";

struct Args {
    browser: Option<String>,
    cookies: bool,
    domain: Option<String>,
    reason: Option<String>,
    dry_run: bool,
}

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> Result<Outcome, Refusal> {
    let args = parse(args)?;
    let mut report = json!({
        "schema_version": 1,
        "task": TASK,
        "dry_run": args.dry_run,
        "browser": args.browser,
        "cookies": args.cookies,
        "before": Value::Null,
        "after": Value::Null,
        "undo": Value::Null,
        "user_action": Value::Null,
        "person": PERSON,
    });
    if !applies(global) {
        report["state"] = json!("not_applicable");
        return Ok(Outcome { report, failed: false });
    }
    let Some(browser) = args.browser.clone() else {
        report["state"] = json!("needs_user");
        report["user_action"] = json!({
            "kind": "choose",
            "text": "Ask the person which browser to import from and pass it as `--browser`, or \
                     run the command to show them cmux's list of the browsers on this Mac",
            "command": PICKER,
            "url": Value::Null,
        });
        return Ok(Outcome { report, failed: false });
    };
    if args.cookies {
        let report = cookies(global, &args, &browser, report);
        return Ok(Outcome { report, failed: false });
    }
    let report = bookmarks(global, &args, &browser, report);
    Ok(Outcome { report, failed: false })
}

/// The check `cmux setup status` reports: which browsers' bookmarks are in.
pub(super) fn status(global: &GlobalArgs) -> Value {
    if !applies(global) {
        return json!({"task": TASK, "state": "not_applicable"});
    }
    match list(global, None) {
        Ok(listed) => {
            let browsers = imported(&listed, None)
                .iter()
                .filter_map(|folder| folder["browser"].as_str().map(str::to_owned))
                .collect::<std::collections::BTreeSet<_>>();
            let state = if browsers.is_empty() { "needs_setup" } else { "ok" };
            let fix = (state != "ok").then_some("cmux setup browser-import");
            json!({"task": TASK, "state": state, "imported": browsers, "person": PERSON, "fix": fix})
        }
        Err(action) => json!({"task": TASK, "state": "needs_user", "user_action": action}),
    }
}

fn parse(args: &[String]) -> Result<Args, Refusal> {
    let mut parsed =
        Args { browser: None, cookies: false, domain: None, reason: None, dry_run: false };
    let mut words = args.iter();
    while let Some(arg) = words.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg.as_str(), None),
        };
        let mut value = |name: &str| {
            inline.clone().or_else(|| words.next().cloned()).filter(|v| !v.is_empty()).ok_or_else(
                || Refusal::Usage(format!("cmux: setup browser-import: {name} needs a value")),
            )
        };
        match flag {
            "--browser" => parsed.browser = Some(value("--browser")?),
            "--domain" => parsed.domain = Some(value("--domain")?),
            "--reason" => parsed.reason = Some(value("--reason")?),
            "--cookies" if inline.is_none() => parsed.cookies = true,
            "--dry-run" if inline.is_none() => parsed.dry_run = true,
            _ => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup browser-import: unexpected argument {arg:?}"
                )));
            }
        }
    }
    if !parsed.cookies && (parsed.domain.is_some() || parsed.reason.is_some()) {
        return Err(Refusal::Usage(
            "cmux: setup browser-import: --domain and --reason go with --cookies".into(),
        ));
    }
    if parsed.browser.as_deref().is_some_and(|browser| browser.starts_with('-')) {
        return Err(Refusal::Usage("cmux: setup browser-import: --browser needs a value".into()));
    }
    Ok(parsed)
}

/// Whether there is a cmux app to ask: macOS, or an app socket named by
/// `--app-socket` or `CMUX_SOCKET_PATH`.
fn applies(global: &GlobalArgs) -> bool {
    cfg!(target_os = "macos")
        || global.app_socket.is_some()
        || std::env::var_os("CMUX_SOCKET_PATH").is_some_and(|path| !path.is_empty())
}

fn bookmarks(global: &GlobalArgs, args: &Args, browser: &str, mut report: Value) -> Value {
    let id = registry_id(browser);
    let listed = match list(global, None) {
        Ok(listed) => listed,
        Err(action) => return needs_user(report, action),
    };
    // The profile the app chose for this run; every later call names it, so
    // a tab focused in between cannot move the import elsewhere.
    let profile = listed["profile"].as_str().unwrap_or("default").to_owned();
    let before = imported(&listed, Some(&id));
    report["before"] = json!({"profile": profile, "folders": before});
    if !before.is_empty() {
        report["after"] = report["before"].clone();
        report["state"] = json!("ok");
        return report;
    }
    if args.dry_run {
        report["state"] = json!("planned");
        return report;
    }
    let mut params =
        action_run_params("bookmark.importFromBrowser", ActionName::Any, action_origin());
    params.insert("args".into(), json!({"browser": browser, "profile": profile}));
    let failure = match app_call(
        global,
        "action.run",
        Value::Object(params),
        super::super::app::waiting_run_timeout("bookmark.importFromBrowser"),
    ) {
        Ok(_) => None,
        Err(error) if error["code"] == "daemon_error" => Some(why(&error)),
        Err(error) => return needs_user(report, app_problem(&error)),
    };
    let listed = match list(global, Some(&profile)) {
        Ok(listed) => listed,
        Err(action) => return needs_user(report, action),
    };
    let after = imported(&listed, Some(&id));
    report["after"] = json!({"profile": profile, "folders": after});
    if after.is_empty() {
        let why = failure.unwrap_or_else(|| "no bookmarks came in.".into());
        return needs_user(
            report,
            json!({
                "kind": "browser",
                "text": format!(
                    "cmux found no bookmarks to import from {browser:?}: {why} Check the name with \
                     the person, or run the command to show them the browsers cmux found"
                ),
                "command": PICKER,
                "url": Value::Null,
            }),
        );
    }
    let undo = after
        .iter()
        .filter_map(|folder| folder["id"].as_str())
        .map(|id| format!("cmux bookmark remove --target bookmark:{id}"))
        .collect::<Vec<_>>()
        .join(" && ");
    report["undo"] = json!(undo);
    if let Some(why) = failure {
        // Some profiles came in and some could not be read.
        report["failed"] = json!(why);
    }
    report["state"] = json!("changed");
    report
}

fn cookies(global: &GlobalArgs, args: &Args, browser: &str, mut report: Value) -> Value {
    report["undo_note"] = json!(COOKIES_UNDO_NOTE);
    if args.dry_run {
        report["state"] = json!("planned");
        return report;
    }
    eprintln!(
        "cmux: setup browser-import: waiting for the person to allow the cookie import in cmux"
    );
    let mut arguments = Map::new();
    arguments.insert("from".into(), json!(browser));
    arguments.insert("reason".into(), json!(args.reason.as_deref().unwrap_or(DEFAULT_REASON)));
    if let Some(domain) = &args.domain {
        arguments.insert("domain".into(), json!(domain));
    }
    let mut params = action_run_params("browser.importCookies", ActionName::Any, action_origin());
    params.insert("args".into(), Value::Object(arguments));
    let timeout = super::super::app::waiting_run_timeout("browser.importCookies");
    match app_call(global, "action.run", Value::Object(params), timeout) {
        Ok(_) => {
            report["state"] = json!("changed");
            report
        }
        // Denied, timed out, or another request already waiting: nothing was read.
        Err(error) if error["code"] == "unavailable" => needs_user(
            report,
            json!({
                "kind": "declined",
                "text": format!(
                    "The cookie import did not run: {} Ask the person before running it again",
                    why(&error)
                ),
                "command": Value::Null,
                "url": Value::Null,
            }),
        ),
        Err(error) if error["code"] == "daemon_error" => needs_user(
            report,
            json!({
                "kind": "browser",
                "text": format!("cmux could not import cookies from {browser:?}: {}", why(&error)),
                "command": Value::Null,
                "url": Value::Null,
            }),
        ),
        Err(error) => needs_user(report, app_problem(&error)),
    }
}

fn needs_user(mut report: Value, action: Value) -> Value {
    report["state"] = json!("needs_user");
    report["user_action"] = action;
    report
}

/// The browser's registry id for a registry id or product name (any case);
/// a name the registry does not know is kept, and the app judges it.
fn registry_id(browser: &str) -> String {
    let registry: Value = serde_json::from_str(REGISTRY).unwrap_or(Value::Null);
    registry["browsers"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| {
            [&row["id"], &row["name"]]
                .iter()
                .any(|name| name.as_str().is_some_and(|name| name.eq_ignore_ascii_case(browser)))
        })
        .and_then(|row| row["id"].as_str())
        .unwrap_or(browser)
        .to_owned()
}

/// The app's `bookmark.list` of `profile` (None: the profile the app picks).
fn list(global: &GlobalArgs, profile: Option<&str>) -> Result<Value, Value> {
    let params = match profile {
        Some(profile) => json!({"profile": profile}),
        None => json!({}),
    };
    app_call(global, "bookmark.list", params, READ_TIMEOUT).map_err(|error| app_problem(&error))
}

/// The imported folders of `bookmark.list`, of one browser id or of all.
fn imported(listed: &Value, browser: Option<&str>) -> Vec<Value> {
    listed["bookmarks"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|node| node["kind"] == "folder")
        .filter_map(|node| {
            let key = node["source_key"].as_str()?;
            let id = key.split_once('/').map_or(key, |(id, _)| id);
            browser.is_none_or(|browser| id.eq_ignore_ascii_case(browser)).then(|| {
                json!({"id": node["id"], "title": node["title"], "source_key": key, "browser": id})
            })
        })
        .collect()
}

fn app_call(
    global: &GlobalArgs,
    method: &str,
    params: Value,
    timeout: std::time::Duration,
) -> Result<Value, Value> {
    super::super::mcp::agent_app(global, method, params, timeout, None)
}

/// The app's words for a failed run, ending in a full stop.
fn why(error: &Value) -> String {
    let text = error
        .pointer("/data/reason")
        .or_else(|| error.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("cmux gave no reason")
        .trim()
        .to_owned();
    if text.ends_with('.') { text } else { format!("{text}.") }
}

/// What the person does when the app refused or did not answer.
fn app_problem(error: &Value) -> Value {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    let text = match code {
        "app.not_found" | "app.unreachable" => {
            "Open cmux: browser import runs in the cmux app, which is not running; then run \
             `cmux setup browser-import` again"
                .to_owned()
        }
        "app.transport" => "cmux did not answer; run `cmux setup browser-import` again".to_owned(),
        _ => format!("cmux refused ({code}): {}", why(error)),
    };
    json!({"kind": "app", "text": text, "command": Value::Null, "url": Value::Null})
}
