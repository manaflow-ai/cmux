//! `cmux setup browser-import` driven the way an agent drives it, against a
//! fake cmux app (a module of `setup.rs`, which shares its `World`).

use std::os::unix::net::UnixListener;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::{World, serve_app, shell_words};

/// The app's answer when it stops waiting for a run that goes on.
fn timed_out() -> Value {
    json!({"code": "timeout", "message": "action.run did not finish within 2 s"})
}

/// A fake cmux app that serves what `cmux setup browser-import` and its undo
/// ask: `bookmark.list` of the profile's bar (starting with `bookmarks`),
/// `bookmark.importFromBrowser`, `bookmark remove --target bookmark:ID` (the
/// node and its children), and `browser.importCookies`, whose consent panel
/// the person allows while `allow` is set. The import puts one "Imported
/// from" folder per browser on the bar, or refreshes the folder of that
/// source in place (same id, the new title and children) as the app's
/// `importDrafts` does, and answers as the app does: `chrome` at once; `arc` lands but the app
/// stops waiting first (`timeout`); `zen` times out with nothing landed
/// yet; `brave` lands one profile and could not read another
/// (`daemon_error`); anything else is the app's unknown-browser
/// `daemon_error`. Cookies from `arc` lose the answer after the panel
/// (`timeout`). Every request is kept.
struct FakeBrowserApp {
    bookmarks: Arc<Mutex<Vec<Value>>>,
    allow: Arc<std::sync::atomic::AtomicBool>,
    requests: Arc<Mutex<Vec<Value>>>,
}

impl FakeBrowserApp {
    fn start(world: &mut World, bookmarks: Vec<Value>) -> Self {
        let socket = world.home.parent().unwrap().join("app.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        world.app = Some(socket);
        let app = Self {
            bookmarks: Arc::new(Mutex::new(bookmarks)),
            allow: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            requests: Arc::new(Mutex::new(Vec::new())),
        };
        let (bookmarks, allow) = (app.bookmarks.clone(), app.allow.clone());
        serve_app(listener, app.requests.clone(), move |method, params| {
            let ran = json!({"action": params["action"], "ran": true, "waited": true});
            let land = |id: &str, key: &str, title: &str| {
                let mut nodes = bookmarks.lock().unwrap();
                let id = match nodes.iter_mut().find(|node| node["source_key"] == key) {
                    Some(folder) => {
                        folder["title"] = json!(title);
                        folder["id"].as_str().unwrap().to_owned()
                    }
                    None => {
                        nodes.push(json!({"id": id, "kind": "folder", "parent": "bar",
                            "title": title, "source_key": key}));
                        id.to_owned()
                    }
                };
                nodes.retain(|node| node["parent"] != id);
                nodes.push(json!({"id": format!("{id}_1"), "kind": "bookmark", "parent": id,
                    "title": "cmux", "url": "https://cmux.com/"}));
            };
            Some(match (method, params["action"].as_str()) {
                ("bookmark.list", _) => Ok(json!({
                    "profile": params["profile"].as_str().unwrap_or("default"),
                    "storage": "file",
                    "bookmarks": *bookmarks.lock().unwrap(),
                })),
                ("action.run", Some("bookmark.importFromBrowser")) => {
                    match params["args"]["browser"].as_str().unwrap_or_default() {
                        "chrome" => {
                            land(
                                "bm_1",
                                "chrome/Default",
                                "Imported from Google Chrome (Person 1)",
                            );
                            Ok(ran)
                        }
                        "arc" => {
                            land("bm_arc", "arc/Default", "Imported from Arc (Personal)");
                            Err(timed_out())
                        }
                        "zen" => Err(timed_out()),
                        "brave" => {
                            land("bm_brave", "brave/Default", "Imported from Brave (Person 1)");
                            Err(json!({"code": "daemon_error",
                                "message": "Could not read: Brave (Work).",
                                "data": {"action": "bookmark.importFromBrowser"}}))
                        }
                        browser => {
                            let message =
                                format!("No browser profile with bookmarks matches “{browser}”.");
                            Err(json!({"code": "daemon_error", "message": message,
                                "data": {"action": "bookmark.importFromBrowser"}}))
                        }
                    }
                }
                ("action.run", Some("bookmark remove")) => {
                    let id = params["target"].as_str().unwrap_or_default();
                    let id = id.strip_prefix("bookmark:").unwrap_or(id);
                    let mut nodes = bookmarks.lock().unwrap();
                    nodes.retain(|node| node["id"] != id && node["parent"] != id);
                    Ok(ran)
                }
                ("action.run", Some("browser.importCookies")) => {
                    if params["args"]["from"] == "arc" {
                        Err(timed_out())
                    } else if allow.load(Ordering::SeqCst) {
                        Ok(ran)
                    } else {
                        let reason = "The person denied the cookie import. Nothing was read.";
                        Err(json!({"code": "unavailable",
                            "message": format!("browser.importCookies unavailable: {reason}"),
                            "data": {"action": "browser.importCookies", "reason": reason}}))
                    }
                }
                _ => Err(json!({"code": "method_not_found", "message": "unknown"})),
            })
        });
        app
    }

    /// The `action.run` params the app received, in order.
    fn runs(&self) -> Vec<Value> {
        let requests = self.requests.lock().unwrap();
        requests
            .iter()
            .filter(|r| r["method"] == "action.run")
            .map(|r| r["params"].clone())
            .collect()
    }
}

/// Bookmarks from another browser, driven the way an agent drives it:
/// `status` names the task, no browser asks which one, a dry run imports
/// nothing, the import names the new folder and its undo, a rerun (by the
/// product name) changes nothing, and the undo takes the folder away again.
#[test]
fn cmux_setup_browser_import_brings_bookmarks_in_and_its_undo_takes_them_out() {
    let mut world = World::new("bi");
    let app = FakeBrowserApp::start(&mut world, Vec::new());

    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][6];
    assert_eq!(check["task"], "browser_import", "{status}");
    assert_eq!(check["state"], "needs_setup", "{check}");
    let fix = check["fix"].as_str().expect("status names its fix").to_owned();

    let choose = world.follow(&fix);
    assert_eq!(choose["state"], "needs_user", "{choose}");
    assert_eq!(choose["user_action"]["kind"], "choose", "{choose}");
    assert_eq!(choose["user_action"]["command"], "cmux action run bookmark.importFromBrowser");
    assert!(choose["person"].as_str().is_some_and(|text| text.contains("Import from Browser")));

    let planned = world.json(&["setup", "browser-import", "--browser", "chrome", "--dry-run"]);
    assert_eq!(planned["state"], "planned", "{planned}");
    assert_eq!(planned["undo"], "cmux bookmark remove --target bookmark:FOLDER_ID", "{planned}");
    assert!(app.runs().is_empty(), "a dry run imported: {:?}", app.runs());

    let changed = world.json(&["setup", "browser-import", "--browser", "chrome"]);
    assert_eq!(changed["state"], "changed", "{changed}");
    assert_eq!(changed["before"]["folders"], json!([]), "{changed}");
    assert_eq!(changed["after"]["folders"][0]["source_key"], "chrome/Default", "{changed}");
    let undo = changed["undo"].as_str().expect("an import names its undo").to_owned();
    assert_eq!(undo, "cmux bookmark remove --target bookmark:bm_1");
    let runs = app.runs();
    assert_eq!(runs.len(), 1, "{runs:?}");
    assert_eq!(runs[0]["action"], "bookmark.importFromBrowser");
    assert_eq!(runs[0]["args"], json!({"browser": "chrome", "profile": "default"}));
    assert_ne!(runs[0]["origin"], "user", "{runs:?}");

    let again = world.json(&["setup", "browser-import", "--browser", "Google Chrome"]);
    assert_eq!(again["state"], "ok", "{again}");
    assert_eq!(again["undo"], Value::Null);
    assert_eq!(app.runs().len(), 1, "an ok run imported again");
    let check = &world.json(&["setup", "status"])["checks"][6];
    assert_eq!((&check["state"], &check["imported"]), (&json!("ok"), &json!(["chrome"])));

    // The undo, as the agent's shell runs it: the folder and its bookmarks go.
    let words = shell_words(&undo);
    let args = words[1..].iter().map(String::as_str).collect::<Vec<_>>();
    let output = world.run(&args);
    assert!(output.status.success(), "{undo}: {}", String::from_utf8_lossy(&output.stderr));
    assert!(app.bookmarks.lock().unwrap().is_empty());
    let planned = world.json(&["setup", "browser-import", "--browser", "chrome", "--dry-run"]);
    assert_eq!(planned["state"], "planned", "{planned}");

    let unknown = world.json(&["setup", "browser-import", "--browser", "netscape"]);
    assert_eq!(unknown["state"], "needs_user", "{unknown}");
    assert_eq!(unknown["user_action"]["kind"], "browser", "{unknown}");
    assert_eq!(unknown["undo"], Value::Null);

    // Refused before the app is asked: a flag taken as a value, a browser
    // with no name (the app would open its picker), a flag given twice.
    let runs = app.runs().len();
    for args in [
        &["setup", "browser-import", "now"][..],
        &["setup", "browser-import", "--browser"],
        &["setup", "browser-import", "--browser", "--dry-run"],
        &["setup", "browser-import", "--browser", "chrome", "--domain", "github.com"],
        &["setup", "browser-import", "--browser", "chrome", "--cookies", "--domain", "--dry-run"],
        &["setup", "browser-import", "--browser", "chrome", "--cookies", "--reason", "--dry-run"],
        &["setup", "browser-import", "--browser", ":Work"],
        &["setup", "browser-import", "--browser", " "],
        &["setup", "browser-import", "--browser", ":"],
        &["setup", "browser-import", "--browser", "chrome", "--browser", "arc"],
        &["setup", "browser-import", "--browser", "chrome", "--dry-run", "--dry-run"],
    ] {
        let output = world.run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
    }
    assert_eq!(app.runs().len(), runs, "a refused run asked the app: {:?}", app.runs());
}

/// Cookies are the person's: the app's consent panel asks them, a denial
/// is `declined` with nothing read, an Allow is `changed`, and neither has
/// an undo (the result says why). A dry run asks nothing.
#[test]
fn cmux_setup_browser_import_asks_the_person_before_cookies() {
    let mut world = World::new("bicookie");
    let app = FakeBrowserApp::start(&mut world, Vec::new());
    let cookies = ["setup", "browser-import", "--browser", "chrome", "--cookies"];

    // No browser: the agent asks the person; the picker would import bookmarks.
    let choose = world.json(&["setup", "browser-import", "--cookies"]);
    assert_eq!(choose["user_action"]["kind"], "choose", "{choose}");
    assert_eq!(choose["user_action"]["command"], Value::Null, "{choose}");

    let planned = world.json(&[&cookies[..], &["--dry-run"][..]].concat());
    assert_eq!(planned["state"], "planned", "{planned}");
    assert!(planned["undo_note"].is_string(), "{planned}");
    assert!(app.runs().is_empty(), "a dry run asked the person");

    let declined = world.json(&[&cookies[..], &["--domain", "github.com"][..]].concat());
    assert_eq!(declined["state"], "needs_user", "{declined}");
    assert_eq!(declined["user_action"]["kind"], "declined", "{declined}");
    assert_eq!(declined["undo"], Value::Null);
    let run = &app.runs()[0];
    assert_eq!(run["action"], "browser.importCookies");
    assert_eq!(run["args"]["from"], "chrome");
    assert_eq!(run["args"]["domain"], "github.com");
    assert!(run["args"]["reason"].as_str().is_some_and(|reason| !reason.is_empty()), "{run}");
    // From an agent or a script, so the app always shows the person its panel.
    assert!(matches!(run["origin"].as_str(), Some(origin) if origin != "user"), "{run}");

    app.allow.store(true, Ordering::SeqCst);
    let allowed = world.json(&[&cookies[..], &["--reason", "sign in to GitHub"][..]].concat());
    assert_eq!(allowed["state"], "changed", "{allowed}");
    assert_eq!(allowed["undo"], Value::Null);
    assert!(allowed["undo_note"].is_string(), "{allowed}");
    assert_eq!(app.runs()[1]["args"]["reason"], "sign in to GitHub");

    // The answer is lost after the panel: it may have run, so the agent must
    // not show the person a second panel without asking them.
    let unknown = world.json(&["setup", "browser-import", "--browser", "arc", "--cookies"]);
    assert_eq!(unknown["state"], "needs_user", "{unknown}");
    assert_eq!(unknown["user_action"]["kind"], "app", "{unknown}");
    let text = unknown["user_action"]["text"].as_str().unwrap();
    assert!(text.contains("may have run") && text.contains("without asking"), "{text}");
}

/// The undo names only the folders the run added: the person's own folder
/// and another browser's import stay out of it. A profile named with
/// `BROWSER:PROFILE` goes to the app and decides `ok`; an import the app
/// stops waiting for is read back (or `wait`), and a profile it could not
/// read is named in `unread`.
#[test]
fn cmux_setup_browser_import_undoes_only_what_it_imported() {
    let mut world = World::new("biown");
    let own = json!({"id": "own", "kind": "folder", "parent": "bar", "title": "Work"});
    let firefox = json!({"id": "ff", "kind": "folder", "parent": "bar",
        "title": "Imported from Firefox (default-release)",
        "source_key": "firefox/abcd.default-release"});
    let app = FakeBrowserApp::start(&mut world, vec![own.clone(), firefox.clone()]);
    let run = |args: &[&str]| world.json(&[&["setup", "browser-import"][..], args].concat());

    let check = &world.json(&["setup", "status"])["checks"][6];
    assert_eq!((&check["state"], &check["imported"]), (&json!("ok"), &json!(["firefox"])));
    assert_eq!(run(&["--browser", "Firefox"])["state"], "ok");

    let changed = run(&["--browser", "Google Chrome:Default"]);
    assert_eq!(changed["state"], "changed", "{changed}");
    assert_eq!(changed["undo"], "cmux bookmark remove --target bookmark:bm_1", "{changed}");
    let runs = app.runs();
    assert_eq!(
        runs[0]["args"],
        json!({"browser": "chrome", "source": "Default", "profile": "default"})
    );
    // The profile matches by folder or by the name the title shows.
    assert_eq!(run(&["--browser", "chrome:default"])["state"], "ok");
    assert_eq!(run(&["--browser", "chrome:Person 1"])["state"], "ok");
    assert_eq!(run(&["--browser", "chrome:Work", "--dry-run"])["state"], "planned");
    let bare = run(&["--browser", "chrome:"]);
    assert_eq!((&bare["state"], &bare["browser"]), (&json!("ok"), &json!("chrome")), "{bare}");
    assert_eq!(app.runs().len(), 1, "an ok run imported again");

    // The app stops waiting, the folder lands anyway: the run still owns it.
    let late = run(&["--browser", "arc"]);
    assert_eq!(late["state"], "changed", "{late}");
    assert_eq!(late["undo"], "cmux bookmark remove --target bookmark:bm_arc", "{late}");
    // It may still be adding other profiles: the note says how to see them.
    let note = late["note"].as_str().expect("a late import has a note");
    assert!(note.contains(r#"--browser "arc" --dry-run"#), "{note}");
    let pending = run(&["--browser", "zen"]);
    assert_eq!(pending["state"], "needs_user", "{pending}");
    assert_eq!(pending["user_action"]["kind"], "wait", "{pending}");

    let partial = run(&["--browser", "brave"]);
    assert_eq!(partial["state"], "changed", "{partial}");
    assert_eq!(partial["undo"], "cmux bookmark remove --target bookmark:bm_brave");
    assert_eq!(partial["unread"], "Could not read: Brave (Work).", "{partial}");

    for undo in [&changed["undo"], &late["undo"], &partial["undo"]] {
        let words = shell_words(undo.as_str().unwrap());
        let output = world.run(&words[1..].iter().map(String::as_str).collect::<Vec<_>>());
        assert!(output.status.success(), "{undo}: {}", String::from_utf8_lossy(&output.stderr));
    }
    assert_eq!(*app.bookmarks.lock().unwrap(), vec![own, firefox]);
}

/// A profile named in a way the folder no longer shows (the person renamed
/// it) imports again, and the app refreshes that folder in place: `changed`
/// with the folder in `after.refreshed`, no undo (setup's remove would take
/// the person's folder), and a note naming the app's toast Undo.
#[test]
fn cmux_setup_browser_import_reports_a_folder_refreshed_in_place() {
    let mut world = World::new("bifresh");
    let renamed = json!({"id": "mine", "kind": "folder", "parent": "bar", "title": "Chrome",
        "source_key": "chrome/Default"});
    let app = FakeBrowserApp::start(&mut world, vec![renamed]);

    let refreshed = world.json(&["setup", "browser-import", "--browser", "chrome:Person 1"]);
    assert_eq!(refreshed["state"], "changed", "{refreshed}");
    assert_eq!(refreshed["undo"], Value::Null, "{refreshed}");
    assert_eq!(refreshed["after"]["folders"], json!([]), "{refreshed}");
    let folder = &refreshed["after"]["refreshed"][0];
    assert_eq!((&folder["id"], &folder["source_key"]), (&json!("mine"), &json!("chrome/Default")));
    let note = refreshed["note"].as_str().expect("a refresh in place has a note");
    assert!(note.contains("in place") && note.contains("toast"), "{note}");
    assert_eq!(app.runs().len(), 1, "{:?}", app.runs());
    // The folder kept its id: it is the person's, with the new bookmarks in it.
    let ids = app.bookmarks.lock().unwrap().iter().map(|n| n["id"].clone()).collect::<Vec<_>>();
    assert_eq!(ids, [json!("mine"), json!("mine_1")]);
}
