//! Agent browser profiles (`browser-profile-agent-v1`, cx-d0d.85) through the
//! curated CLI and a real daemon: an agent lists and creates browser
//! profiles, opens a tab in one, and moves a tab to another. The tab keeps
//! its id and shows its profile as `extra.browser_profile_id`; the app that
//! shows the tab only follows that record.
#![cfg(unix)]

use super::*;

fn cmux(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap()
}

fn ok(server: &HeadlessServer, args: &[&str]) -> serde_json::Value {
    let output = cmux(server, args);
    assert_success(&output);
    json_output(&output)
}

fn refused(server: &HeadlessServer, args: &[&str]) -> String {
    let output = cmux(server, args);
    assert!(!output.status.success(), "{args:?}: {}", String::from_utf8_lossy(&output.stdout));
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// The first object under `value` that has `key` (results nest a snapshot).
fn find<'a>(value: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(map) => {
            map.get(key).or_else(|| map.values().find_map(|child| find(child, key)))
        }
        serde_json::Value::Array(items) => items.iter().find_map(|child| find(child, key)),
        _ => None,
    }
}

fn text(value: Option<&serde_json::Value>) -> String {
    value.and_then(|value| value.as_str()).unwrap_or_default().to_string()
}

fn profile_of(server: &HeadlessServer, tab: &str) -> String {
    text(find(&ok(server, &["tab", tab, "show"]), "browser_profile_id"))
}

#[test]
fn agents_move_tabs_between_profiles_and_read_the_profile_through_a_real_daemon() {
    let server = HeadlessServer::start("browser-profiles");
    let identity = raw_json(&server, serde_json::json!({"id": "who", "cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "browser-profile-agent-v1"),
        "{identity}"
    );
    let id_of = |args: &[&str]| text(find(&ok(&server, args), "id"));
    let work = id_of(&["browser", "profile", "create", "--name", "Work"]);
    let client = id_of(&["browser", "profile", "create", "--name", "Client"]);
    assert!(work.len() == 36 && client.len() == 36 && work != client, "{work} {client}");

    // A tab opened straight in a profile shows it in tab info.
    let opened = ok(
        &server,
        &[
            "browser",
            "profile",
            "open",
            "https://example.com/",
            "--engine",
            "webkit",
            "--profile",
            "Work",
        ],
    );
    let tab = text(find(&opened, "tab_resource_id"));
    assert!(tab.starts_with("tab_"), "{opened}");
    assert_eq!(profile_of(&server, &tab), work);

    // Move it by id: same tab id, the record names the new profile.
    let moved = ok(&server, &["browser", "tab", &tab, "set-profile", "--profile", &client]);
    assert_eq!(text(find(&moved, "tab_id")), tab, "{moved}");
    assert_eq!(find(&moved, "changed").and_then(|v| v.as_bool()), Some(true), "{moved}");
    assert_eq!(profile_of(&server, &tab), client);
    // Back by name; the same profile again changes nothing.
    ok(&server, &["browser", "tab", &tab, "set-profile", "--profile", "Work"]);
    assert_eq!(profile_of(&server, &tab), work);
    let again = ok(&server, &["browser", "tab", &tab, "set-profile", "--profile", "Work"]);
    assert_eq!(find(&again, "changed").and_then(|v| v.as_bool()), Some(false), "{again}");

    // A frontend tab with no profile is in default.
    raw_json(
        &server,
        serde_json::json!({"id": "b", "cmd": "new-frontend-browser-tab",
                           "url": "https://example.org/", "engine": "webkit"}),
    );
    let tabs = ok(&server, &["tab", "list"]);
    let rows = find(&tabs, "items")
        .or(Some(&tabs))
        .and_then(|items| items.as_array())
        .cloned()
        .unwrap_or_default();
    let tab_where = |pick: &dyn Fn(&serde_json::Value) -> bool| -> String {
        rows.iter()
            .find(|row| pick(row))
            .and_then(|row| row["id"].as_str())
            .unwrap_or_default()
            .to_string()
    };
    let plain = tab_where(&|row| row["content_kind"] == "browser" && row["id"] != tab.as_str());
    assert_eq!(profile_of(&server, &plain), "default", "{tabs}");

    // Unknown profiles and non-browser tabs are refused and change nothing.
    let error = refused(&server, &["browser", "tab", &tab, "set-profile", "--profile", "Nope"]);
    assert!(error.contains("Nope"), "{error}");
    assert_eq!(profile_of(&server, &tab), work);
    ok(&server, &["tab", "create", "terminal"]);
    let tabs = ok(&server, &["tab", "list"]);
    let terminal = find(&tabs, "items")
        .or(Some(&tabs))
        .and_then(|items| items.as_array())
        .and_then(|items| items.iter().find(|tab| tab["content_kind"] == "terminal"))
        .and_then(|tab| tab["id"].as_str())
        .unwrap_or_else(|| panic!("no terminal tab in {tabs}"))
        .to_string();
    refused(&server, &["browser", "tab", &terminal, "set-profile", "--profile", "Work"]);
}
