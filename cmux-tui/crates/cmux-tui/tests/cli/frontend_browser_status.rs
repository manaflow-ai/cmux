//! A browser the cmux app renders itself (CEF or WebKit, `new-frontend-browser-tab`) is live
//! in `cmux browser list` and `browser <id> show` once it exists: it streams no frames to the
//! daemon, so frame-driven status must not leave it `starting` and `loading` forever
//! (cx-d0d.82).
#![cfg(unix)]

use super::*;

#[test]
fn an_app_rendered_browser_lists_as_live_and_not_loading() {
    let server = HeadlessServer::start("frontend-browser-status");
    state_cli(&server, None, &["workspace", "create", "--name", "pages"]);
    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    let pane = tree["workspaces"][0]["screens"][0]["active_pane"]
        .as_u64()
        .unwrap_or_else(|| panic!("no pane: {tree}"));
    let created = raw_json(
        &server,
        serde_json::json!({
            "id": "open", "cmd": "new-frontend-browser-tab", "pane": pane,
            "url": "https://example.com/", "engine": "webkit",
        }),
    );
    let surface = created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"));
    let tab = created["tab_resource_id"].clone();
    // What the app sends once the page has loaded.
    raw_json(
        &server,
        serde_json::json!({
            "id": "loaded", "cmd": "update-frontend-browser-tab", "surface": surface,
            "url": "https://example.com/", "title": "Example Domain",
        }),
    );

    let output = json_cli(&server, &["browser", "list"]);
    assert_success(&output);
    let browsers = json_output(&output);
    let browser = browsers
        .as_array()
        .into_iter()
        .flatten()
        .find(|browser| browser["tab_id"] == tab)
        .unwrap_or_else(|| panic!("no browser for tab {tab}: {browsers}"))
        .clone();
    assert_eq!(browser["title"], "Example Domain", "{browser}");
    assert_eq!(browser["status"], "live", "{browser}");
    assert_eq!(browser["loading"], false, "{browser}");

    let id = browser["id"].as_str().unwrap_or_else(|| panic!("no id: {browser}"));
    let output = json_cli(&server, &["browser", id, "show"]);
    assert_success(&output);
    let shown = json_output(&output);
    assert_eq!(shown["status"], "live", "{shown}");
    assert_eq!(shown["loading"], false, "{shown}");
}
