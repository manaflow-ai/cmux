//! Supervisor tests of link handlers (`cmux.opener/1`, `openers.rs`).

use super::*;

/// Makes the app in `dir` an opener of `urls` (and `schemes`), at `version`.
fn save_opener(dir: &Path, urls: Value, schemes: Value, version: &str) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["version"] = json!(version);
    manifest["implements"]["cmux.opener/1"] =
        json!({ "export": "openLink", "schemes": schemes, "options": { "urls": urls } });
    std::fs::write(&path, manifest.to_string()).unwrap();
}

/// A fixture whose bundled `cmux/demo` opens every https link and whose
/// local `local/spy` opens Jira's issue links.
fn opener_fixture() -> Fixture {
    let root = temp_dir();
    let bundled = root.0.join("bundled");
    let local = root.0.join("state/apps/local");
    write_app(&bundled, "demo", "cmux/demo", json!({}));
    write_app(&local, "spy", "local/spy", json!({}));
    save_opener(&bundled.join("demo"), json!([]), json!(["https"]), "1.0.0");
    save_opener(&local.join("spy"), json!(["https://jira.example/browse/*"]), json!([]), "1.0.0");
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/demo");
    f.install("local/spy");
    f
}

/// `apps-open-link` for `url`, answered.
fn open_link(f: &Fixture, url: &str) -> Value {
    let (tx, rx) = channel();
    f.supervisor.open_link(url.into(), Origin::User, Box::new(move |r| tx.send(r).unwrap()));
    rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap()
}

/// The links `app`'s opener was asked to open, in order.
fn opened(f: &Fixture, app: &str) -> Vec<String> {
    f.supervisor.logs(CLIENT, app, false)["lines"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|l| l["message"].as_str()?.strip_prefix("open ").map(str::to_string))
        .collect()
}

/// A Jira link reaches the app whose pattern names Jira, not the one that
/// takes every https link; another https link goes to that one; a link no
/// app takes is left to cmux (base red: nothing consumed `cmux.opener/1`,
/// so every click opened in the browser).
#[test]
fn a_link_reaches_the_most_specific_opener() {
    let f = opener_fixture();
    let jira = "https://jira.example/browse/ABC-1";
    assert_eq!(open_link(&f, jira), json!({ "handled": true, "app": "local/spy" }));
    assert_eq!(opened(&f, "local/spy"), vec![format!("\"{jira}\"")]);
    let other = "https://news.example/today";
    assert_eq!(open_link(&f, other), json!({ "handled": true, "app": "cmux/demo" }));
    assert_eq!(opened(&f, "cmux/demo"), vec![format!("\"{other}\"")]);
    assert_eq!(open_link(&f, "mailto:a@b.example"), json!({ "handled": false }));
}

/// A hidden or disabled app opens nothing: its links go to the next match.
#[test]
fn a_hidden_or_disabled_opener_is_passed_over() {
    let f = opener_fixture();
    let jira = "https://jira.example/browse/ABC-1";
    f.set("hide", "local/spy", Origin::User, |o| o.hidden = Some(true)).unwrap();
    assert_eq!(f.supervisor.opener_for(jira).map(|o| o.0).as_deref(), Some("cmux/demo"));
    f.set("off", "cmux/demo", Origin::User, |o| o.enabled = Some(false)).unwrap();
    assert_eq!(open_link(&f, jira), json!({ "handled": false }));
}

/// A saved manifest moves the opener's links with no relaunch: the reload
/// that says `apps-changed` also changes where the next click goes (base
/// red: no opener was consulted at all).
#[test]
fn a_saved_opener_pattern_routes_the_next_click() {
    let f = opener_fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    let spy = f.state.join("apps/local/spy");
    let (jira, tracker) = ("https://jira.example/browse/ABC-1", "https://tracker.example/t/9");
    assert_eq!(f.supervisor.opener_for(jira).map(|o| o.0).as_deref(), Some("local/spy"));
    save_opener(&spy, json!(["https://tracker.example/t/*"]), json!([]), "1.0.1");
    f.supervisor.reload_local_apps(&prints);
    f.wait("the reload's apps-changed", |e| {
        e["event"] == "apps-changed"
            && e["app"] == "local/spy"
            && e["transaction"] == "local-reload"
    });
    assert_eq!(f.supervisor.opener_for(jira).map(|o| o.0).as_deref(), Some("cmux/demo"));
    assert_eq!(open_link(&f, tracker), json!({ "handled": true, "app": "local/spy" }));
    assert_eq!(opened(&f, "local/spy"), vec![format!("\"{tracker}\"")]);
}
