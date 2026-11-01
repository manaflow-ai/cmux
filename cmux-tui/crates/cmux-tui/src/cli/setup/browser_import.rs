//! `cmux setup browser-import --browser BROWSER[:PROFILE] [--cookies
//! [--domain D] [--reason TEXT]] [--dry-run]`: brings the person's
//! bookmarks, or with `--cookies` their sign-ins, from another browser on
//! this Mac into cmux. Both read `--browser` the way the app's cookie import
//! does: a browser, then optionally `:` and one profile.
//!
//! Bookmarks are not secrets: the app's `bookmark.importFromBrowser` reads
//! every readable profile of the browser (or the one named) into one
//! "Imported from ..." folder on the Bookmarks Bar per profile, tagged with
//! `source_key` `<browser id>/<profile folder>`. The state is
//! `bookmark.list` once the app has loaded it: a folder of that browser
//! there (when a profile is named, of a source key the app's
//! `bookmark.importSources` gives for it; titles are localized) is `ok`
//! and nothing runs; otherwise setup imports, reads
//! the list again, and the undo removes each folder the run added of the
//! source keys it read (`cmux bookmark remove --target bookmark:<id>`); a
//! new folder of another profile came from another import running at the
//! same time and is named in `after.other`. A folder of the same
//! source the app refreshes in place instead is named in `after.refreshed`
//! with no undo (the app's toast Undo is its only one). The app may stop
//! waiting for the import while it still runs; setup then reads the list
//! anyway.
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
use cmux_json::JsonSet as _;

const TASK: &str = "browser_import";

/// The (registry id, product name) of every browser the app imports from,
/// from the registry the app reads (build.rs). Nothing else of the registry
/// is in the client.
const BROWSERS: &[(&str, &str)] = include!(concat!(env!("OUT_DIR"), "/browser_names.rs"));

/// The command that shows the person the app's picker of found browsers.
const PICKER: &str = "cmux action run bookmark.importFromBrowser";

/// What only the person brings in, from the app's own Import from Browser.
const PERSON: &str = "History and passwords come in only when the person runs Import from \
                      Browser... in cmux (File menu or the command palette)";

/// The reason the consent panel shows when the agent gives none.
const DEFAULT_REASON: &str = "cmux setup browser-import: use your sign-ins in cmux's browser";

/// How long `bookmark.list` may say it is still loading: reads and the pause between them.
const LOAD_WAIT: std::time::Duration = std::time::Duration::from_secs(2);
const LOAD_PAUSE: std::time::Duration = std::time::Duration::from_millis(100);

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
        report.set("state", json!("not_applicable"));
        return Ok(Outcome { report, failed: false });
    }
    let Some(browser) = args.browser.clone() else {
        // The picker imports bookmarks, so it is no answer for `--cookies`.
        let (text, command) = if args.cookies {
            (
                "Ask the person which browser to import sign-ins from and pass it as `--browser`",
                None,
            )
        } else {
            (
                "Ask the person which browser to import from and pass it as `--browser`, or run \
                 the command to show them cmux's list of the browsers on this Mac",
                Some(PICKER),
            )
        };
        report.set("state", json!("needs_user"));
        report.set(
            "user_action",
            json!({"kind": "choose", "text": text, "command": command, "url": Value::Null}),
        );
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
            let browsers = imported(&listed, None, None)
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
    let usage = |text: String| Refusal::Usage(format!("cmux: setup browser-import: {text}"));
    let mut parsed =
        Args { browser: None, cookies: false, domain: None, reason: None, dry_run: false };
    let mut seen = Vec::new();
    let mut words = args.iter();
    while let Some(arg) = words.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg.as_str(), None),
        };
        if seen.contains(&flag) {
            return Err(usage(format!("{flag} is given twice")));
        }
        seen.push(flag);
        // The next word is the value unless it is a flag: `--domain --dry-run`
        // is a missing domain, not the domain "--dry-run" (`--domain=--x` is meant).
        let mut value = |name: &str| {
            inline
                .clone()
                .or_else(|| words.next().cloned())
                .filter(|v| !v.is_empty() && (inline.is_some() || !v.starts_with("--")))
                .ok_or_else(|| usage(format!("{name} needs a value")))
        };
        match flag {
            "--browser" => parsed.browser = Some(value("--browser")?),
            "--domain" => parsed.domain = Some(value("--domain")?),
            "--reason" => parsed.reason = Some(value("--reason")?),
            "--cookies" if inline.is_none() => parsed.cookies = true,
            "--dry-run" if inline.is_none() => parsed.dry_run = true,
            _ => return Err(usage(format!("unexpected argument {arg:?}"))),
        }
    }
    if !parsed.cookies && (parsed.domain.is_some() || parsed.reason.is_some()) {
        return Err(usage("--domain and --reason go with --cookies".into()));
    }
    if let Some(browser) = parsed.browser.take() {
        // `:Work` or a blank name would leave the app to open its picker.
        let (name, profile) = split(&browser);
        if name.is_empty() {
            return Err(usage("--browser needs a browser name".into()));
        }
        // `chrome:` is `chrome`, without the spaces around either part.
        parsed.browser =
            Some(profile.map_or_else(|| name.to_owned(), |profile| format!("{name}:{profile}")));
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

/// `--browser` split into the browser and the profile it may name
/// (`chrome:Work`, `brave:Profile 2`), as the app's cookie import reads it.
fn split(browser: &str) -> (&str, Option<&str>) {
    match browser.split_once(':') {
        Some((name, profile)) => (name.trim(), Some(profile.trim()).filter(|p| !p.is_empty())),
        None => (browser.trim(), None),
    }
}

fn bookmarks(global: &GlobalArgs, args: &Args, browser: &str, mut report: Value) -> Value {
    let (name, source) = split(browser);
    let id = registry_id(name);
    let listed = match list(global, None) {
        Ok(listed) => listed,
        Err(action) => return needs_user(report, action),
    };
    // The profile the app chose for this run; every later call names it, so
    // a tab focused in between cannot move the import elsewhere.
    let profile = listed["profile"].as_str().unwrap_or("default").to_owned();
    // The source keys of the profiles the app's import would read: a named
    // profile is the folders of those keys (the app matches the name, and
    // folder titles are localized), and only folders of those keys can be
    // this run's.
    let keys = match import_sources(global, &id, source) {
        Ok(keys) => keys,
        Err(action) => return needs_user(report, action),
    };
    // A profile the browser no longer has is found only by the folder in
    // the stored source key (its shown name is gone with it).
    let stored = match (source, keys.is_empty()) {
        (Some(source), true) => vec![format!("{id}/{source}")],
        _ => keys.clone(),
    };
    let before = imported(&listed, Some(&id), source.map(|_| stored.as_slice()));
    report.set("before", json!({"profile": profile, "folders": before}));
    if !before.is_empty() {
        report.set("after", report["before"].clone());
        report.set("state", json!("ok"));
        return report;
    }
    // Not imported yet, and the browser (or the profile) is gone.
    if keys.is_empty() {
        return needs_user(report, no_bookmarks(browser, "no browser profile matches."));
    }
    if args.dry_run {
        report.set("state", json!("planned"));
        report.set("undo", json!(remove("FOLDER_ID")));
        return report;
    }
    // Every folder of this browser already there: the undo names only the
    // ones this run adds, never the person's own or another import's.
    let known =
        imported(&listed, Some(&id), None).into_iter().map(|f| f["id"].clone()).collect::<Vec<_>>();
    let mut arguments = json!({"browser": id, "profile": profile});
    if let Some(source) = source {
        arguments.set("source", json!(source));
    }
    let mut params =
        action_run_params("bookmark.importFromBrowser", ActionName::Any, action_origin());
    params.insert("args".into(), arguments);
    let timeout = super::super::app::waiting_run_timeout("bookmark.importFromBrowser");
    let (failure, running) = match app_call(global, "action.run", Value::Object(params), timeout) {
        Ok(_) => (None, false),
        Err(error) if error["code"] == "daemon_error" => (Some(why(&error)), false),
        // The app stopped waiting, or its answer was lost: the import may still run.
        Err(error) if matches!(error["code"].as_str(), Some("timeout" | "app.transport")) => {
            (None, true)
        }
        Err(error) => return needs_user(report, app_problem(&error)),
    };
    let after = match list(global, Some(&profile)) {
        Ok(after) => after,
        Err(action) => return needs_user(report, action),
    };
    let (new, refreshed): (Vec<_>, Vec<_>) = imported(&after, Some(&id), None)
        .into_iter()
        .filter(|folder| {
            !known.contains(&folder["id"])
                || contents(&listed, &folder["id"]) != contents(&after, &folder["id"])
        })
        .partition(|folder| !known.contains(&folder["id"]));
    // A new folder of a profile this run did not read came from another
    // import running at the same time: the undo leaves it.
    let mine = |folder: &Value| keys.iter().any(|key| folder["source_key"] == key.as_str());
    let (added, other): (Vec<_>, Vec<_>) = new.into_iter().partition(mine);
    report.set("after", json!({"profile": profile, "folders": added, "refreshed": refreshed}));
    if !other.is_empty() {
        report.set_path(&["after", "other"], json!(other));
    }
    // The app answered that the import ran: with no new folder it refreshed
    // one already there (the app replaces a folder of the same source in place).
    // Another run's folders are no sign that this one landed.
    let ran = failure.is_none() && !running;
    if added.is_empty() && !refreshed.iter().any(mine) && !ran {
        let action = if running {
            json!({
                "kind": "wait",
                "text": format!(
                    "The import from {browser:?} is still running in cmux; run `cmux setup \
                     browser-import --browser {browser:?}` again in a few seconds"
                ),
                "command": Value::Null,
                "url": Value::Null,
            })
        } else {
            no_bookmarks(browser, failure.as_deref().unwrap_or("no bookmarks came in."))
        };
        return needs_user(report, action);
    }
    if !added.is_empty() {
        let undo = added
            .iter()
            .filter_map(|folder| folder["id"].as_str())
            .map(remove)
            .collect::<Vec<_>>()
            .join(" && ");
        report.set("undo", json!(undo));
    }
    let mut notes = Vec::new();
    if added.is_empty() || !refreshed.is_empty() {
        notes.push(
            "cmux refreshed the existing \"Imported from\" folder in place (`after.refreshed`); \
             the undo does not cover it, and the Undo on cmux's toast is its only undo"
                .to_owned(),
        );
    }
    if !other.is_empty() {
        notes.push(
            "Another import from this browser ran at the same time and added the folders in \
             `after.other`; the undo leaves them"
                .to_owned(),
        );
    }
    if running && !added.is_empty() {
        notes.push(format!(
            "The import may still be adding profiles; run `cmux setup browser-import --browser \
             {browser:?} --dry-run` again to see them"
        ));
    }
    if !notes.is_empty() {
        report.set("note", json!(notes.join(". ")));
    }
    if let Some(why) = failure {
        // Some profiles came in and some could not be read.
        report.set("unread", json!(why));
    }
    report.set("state", json!("changed"));
    report
}

/// What the person does when `browser` has nothing to import, and `why`.
fn no_bookmarks(browser: &str, why: &str) -> Value {
    json!({
        "kind": "browser",
        "text": format!(
            "cmux found no bookmarks to import from {browser:?}: {why} Check the name with the \
             person, or run the command to show them the browsers cmux found"
        ),
        "command": PICKER,
        "url": Value::Null,
    })
}

/// The undo of one imported folder.
fn remove(folder: &str) -> String {
    format!("cmux bookmark remove --target bookmark:{folder}")
}

/// A folder's title and its children in `bookmark.list`: a refresh in place
/// keeps the folder's id but gives it new children, and the title the
/// browser shows now.
fn contents(listed: &Value, folder: &Value) -> (Option<Value>, Vec<Value>) {
    let nodes = listed["bookmarks"].as_array().map(Vec::as_slice).unwrap_or_default();
    let title = nodes.iter().find(|node| node["id"] == *folder).map(|node| node["title"].clone());
    let children = nodes
        .iter()
        .filter(|node| node["parent"] == *folder)
        .map(|node| node["id"].clone())
        .collect();
    (title, children)
}

fn cookies(global: &GlobalArgs, args: &Args, browser: &str, mut report: Value) -> Value {
    report.set("undo_note", json!(COOKIES_UNDO_NOTE));
    if args.dry_run {
        report.set("state", json!("planned"));
        return report;
    }
    eprintln!(
        "cmux: setup browser-import: waiting for the person to allow the cookie import in cmux"
    );
    let mut arguments = Map::new();
    arguments.insert("from".into(), json!(browser));
    arguments.insert(
        "reason".into(),
        json!(
            args.reason
                .as_deref()
                .map(str::trim)
                .filter(|r| !r.is_empty())
                .unwrap_or(DEFAULT_REASON)
        ),
    );
    if let Some(domain) = &args.domain {
        arguments.insert("domain".into(), json!(domain));
    }
    let mut params = action_run_params("browser.importCookies", ActionName::Any, action_origin());
    params.insert("args".into(), Value::Object(arguments));
    let timeout = super::super::app::waiting_run_timeout("browser.importCookies");
    match app_call(global, "action.run", Value::Object(params), timeout) {
        Ok(_) => {
            report.set("state", json!("changed"));
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
        // The panel was up and the answer is lost: the person may have allowed it.
        Err(error) if matches!(error["code"].as_str(), Some("timeout" | "app.transport")) => {
            needs_user(
                report,
                json!({
                    "kind": "app",
                    "text": "cmux did not say how the cookie import ended: the person may have \
                             allowed it and it may have run. Do not run --cookies again without \
                             asking the person first",
                    "command": Value::Null,
                    "url": Value::Null,
                }),
            )
        }
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
    report.set("state", json!("needs_user"));
    report.set("user_action", action);
    report
}

/// The browser's registry id for a registry id or product name, ignoring
/// case, spaces and punctuation as the app's cookie import does (`chrome`,
/// `Google Chrome`, `google-chrome`); a name the registry does not know is
/// kept, and the app judges it.
fn registry_id(browser: &str) -> String {
    let key = |text: &str| {
        text.chars().filter(char::is_ascii_alphanumeric).collect::<String>().to_ascii_lowercase()
    };
    let wanted = key(browser);
    BROWSERS
        .iter()
        .find(|(id, name)| key(id) == wanted || key(name) == wanted)
        .map_or(browser, |(id, _)| *id)
        .to_owned()
}

/// The app's `bookmark.list` of `profile` (None: the profile the app picks).
/// Until the app has its stored bookmarks it answers an empty list with
/// `loaded` false, which would put folders already there in the undo: read
/// again for up to `LOAD_WAIT`, then say to run it again.
fn list(global: &GlobalArgs, profile: Option<&str>) -> Result<Value, Value> {
    let params = match profile {
        Some(profile) => json!({"profile": profile}),
        None => json!({}),
    };
    let still_loading = || {
        json!({
            "kind": "wait",
            "text": "cmux is still loading its bookmarks; run `cmux setup browser-import` again \
                     in a few seconds",
            "command": Value::Null,
            "url": Value::Null,
        })
    };
    let mut listed = app_call(global, "bookmark.list", params.clone(), READ_TIMEOUT)
        .map_err(|error| app_problem(&error))?;
    let deadline = std::time::Instant::now() + LOAD_WAIT;
    while listed["loaded"] == false {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left <= LOAD_PAUSE {
            return Err(still_loading());
        }
        std::thread::sleep(LOAD_PAUSE);
        listed = match app_call(global, "bookmark.list", params.clone(), left - LOAD_PAUSE) {
            Ok(listed) => listed,
            // The reread's time ran out: the app is still slow to answer.
            Err(error) if matches!(error["code"].as_str(), Some("timeout" | "app.transport")) => {
                return Err(still_loading());
            }
            Err(error) => return Err(app_problem(&error)),
        };
    }
    Ok(listed)
}

/// The source keys (`<browser id>/<profile folder>`) of the profiles
/// `bookmark.importFromBrowser` would import for `browser` and `source`
/// (None: every profile of the browser).
fn import_sources(
    global: &GlobalArgs,
    browser: &str,
    source: Option<&str>,
) -> Result<Vec<String>, Value> {
    let mut params = json!({"browser": browser});
    if let Some(source) = source {
        params.set("source", json!(source));
    }
    let found = app_call(global, "bookmark.importSources", params, READ_TIMEOUT)
        .map_err(|error| app_problem(&error))?;
    Ok(found["sources"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|row| row["source_key"].as_str().map(str::to_owned))
        .collect())
}

/// The imported folders of `bookmark.list`: of one browser id or of all,
/// and only those of `keys` (source keys) when given.
fn imported(listed: &Value, browser: Option<&str>, keys: Option<&[String]>) -> Vec<Value> {
    listed["bookmarks"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|node| node["kind"] == "folder")
        .filter_map(|node| {
            let key = node["source_key"].as_str()?;
            let id = key.split_once('/').map_or(key, |(id, _)| id);
            // Ignoring case, as the app matches a named profile's folder.
            let profile =
                keys.is_none_or(|keys| keys.iter().any(|k| k.to_lowercase() == key.to_lowercase()));
            (profile && browser.is_none_or(|browser| id.eq_ignore_ascii_case(browser))).then(|| {
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

#[cfg(test)]
mod tests {
    use super::{BROWSERS, registry_id};

    #[test]
    fn registry_id_reads_ids_and_product_names() {
        assert!(BROWSERS.contains(&("chrome", "Google Chrome")), "{BROWSERS:?}");
        for given in ["chrome", "Google Chrome", "google-chrome", "GOOGLE CHROME"] {
            assert_eq!(registry_id(given), "chrome", "{given}");
        }
        assert_eq!(registry_id("No Such Browser"), "No Such Browser");
    }
}
