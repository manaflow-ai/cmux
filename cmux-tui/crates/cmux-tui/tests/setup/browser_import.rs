//! `cmux setup browser-import` driven the way an agent drives it, against a
//! fake cmux app (a module of `setup.rs`, which shares its `World`).

use std::os::unix::net::UnixListener;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use super::{World, serve_app, shell_words};

/// A fake cmux app that serves what `cmux setup browser-import` and its undo
/// ask: `bookmark.list` of the profile's bar, `bookmark.importFromBrowser`
/// (Chrome, by id or name, adds one "Imported from" folder tagged
/// `chrome/Default`; any other browser is the app's `daemon_error`),
/// `bookmark remove --target bookmark:ID`, and `browser.importCookies`,
/// whose consent panel the person allows while `allow` is set. Every
/// request is kept.
struct FakeBrowserApp {
    bookmarks: Arc<Mutex<Vec<Value>>>,
    allow: Arc<std::sync::atomic::AtomicBool>,
    requests: Arc<Mutex<Vec<Value>>>,
}

impl FakeBrowserApp {
    fn start(world: &mut World) -> Self {
        let socket = world.home.parent().unwrap().join("app.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        world.app = Some(socket);
        let app = Self {
            bookmarks: Arc::new(Mutex::new(Vec::new())),
            allow: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            requests: Arc::new(Mutex::new(Vec::new())),
        };
        let (bookmarks, allow) = (app.bookmarks.clone(), app.allow.clone());
        serve_app(listener, app.requests.clone(), move |method, params| {
            let ran = json!({"action": params["action"], "ran": true, "waited": true});
            Some(match (method, params["action"].as_str()) {
                ("bookmark.list", _) => Ok(json!({
                    "profile": params["profile"].as_str().unwrap_or("default"),
                    "storage": "file",
                    "bookmarks": *bookmarks.lock().unwrap(),
                })),
                ("action.run", Some("bookmark.importFromBrowser")) => {
                    let browser = params["args"]["browser"].as_str().unwrap_or_default();
                    if ["chrome", "google chrome"].contains(&browser.to_lowercase().as_str()) {
                        *bookmarks.lock().unwrap() = vec![
                            json!({"id": "bm_1", "kind": "folder", "parent": "bar",
                                "title": "Imported from Google Chrome",
                                "source_key": "chrome/Default"}),
                            json!({"id": "bm_2", "kind": "bookmark", "parent": "bm_1",
                                "title": "cmux", "url": "https://cmux.com/"}),
                        ];
                        Ok(ran)
                    } else {
                        let message =
                            format!("No browser profile with bookmarks matches “{browser}”.");
                        Err(json!({"code": "daemon_error", "message": message,
                            "data": {"action": "bookmark.importFromBrowser"}}))
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
                    if allow.load(Ordering::SeqCst) {
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
    let app = FakeBrowserApp::start(&mut world);

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

    for args in [
        &["setup", "browser-import", "now"][..],
        &["setup", "browser-import", "--browser"],
        &["setup", "browser-import", "--browser", "--dry-run"],
        &["setup", "browser-import", "--browser", "chrome", "--domain", "github.com"],
    ] {
        let output = world.run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
    }
}

/// Cookies are the person's: the app's consent panel asks them, a denial
/// is `declined` with nothing read, an Allow is `changed`, and neither has
/// an undo (the result says why). A dry run asks nothing.
#[test]
fn cmux_setup_browser_import_asks_the_person_before_cookies() {
    let mut world = World::new("bicookie");
    let app = FakeBrowserApp::start(&mut world);
    let cookies = ["setup", "browser-import", "--browser", "chrome", "--cookies"];

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

    app.allow.store(true, Ordering::SeqCst);
    let allowed = world.json(&[&cookies[..], &["--reason", "sign in to GitHub"][..]].concat());
    assert_eq!(allowed["state"], "changed", "{allowed}");
    assert_eq!(allowed["undo"], Value::Null);
    assert!(allowed["undo_note"].is_string(), "{allowed}");
    assert_eq!(app.runs()[1]["args"]["reason"], "sign in to GitHub");
}
