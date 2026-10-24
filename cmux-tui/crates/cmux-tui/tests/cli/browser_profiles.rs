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
    let tab = text(find(&opened, "tab_id"));
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

/// Calls `tools` on a real `cmux mcp serve` (stdio JSON-RPC) whose daemon
/// is `server`, one call each, and answers each call's result in order.
fn mcp_calls(
    server: &HeadlessServer,
    tools: &[(&str, serde_json::Value)],
) -> Vec<serde_json::Value> {
    let config = server.dir.join("cmux-next-mcp.json");
    fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();
    let mut child = Command::new(bin())
        .arg("--app-socket")
        .arg(server.dir.join("no-app.sock"))
        .args(["mcp", "serve"])
        .env("HOME", &server.dir)
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .env("CMUX_TUI_SOCKET", &server.socket)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_AGENT_SESSION")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_MUX_SOCKET")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut stdin = child.stdin.take().unwrap();
        let mut messages = vec![
            serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "cx-2kl68", "version": "1"}}}),
            serde_json::json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        ];
        for (index, (name, arguments)) in tools.iter().enumerate() {
            messages.push(serde_json::json!({"jsonrpc": "2.0", "id": 100 + index,
                "method": "tools/call", "params": {"name": name, "arguments": arguments}}));
        }
        for message in messages {
            writeln!(stdin, "{message}").unwrap();
        }
    }
    let output = child.wait_with_output().unwrap();
    let replies: Vec<serde_json::Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    (0..tools.len())
        .map(|index| {
            replies.iter().find(|reply| reply["id"] == 100 + index).unwrap_or_else(|| {
                panic!(
                    "no answer to {}: stderr {}",
                    tools[index].0,
                    String::from_utf8_lossy(&output.stderr)
                )
            })["result"]
                .clone()
        })
        .collect()
}

/// cx-2kl68: an agent with only `cmux mcp` lists browser profiles, creates
/// one and opens a tab in it, through `browser.profile.list`,
/// `browser.profile.create` and `browser.profile.open` (the CLI's
/// `cmux browser profile list|create|open` send the same operations). The
/// list shows names and ids, never a profile's import origin; a bad name or
/// a non-web URL is refused and changes nothing.
#[test]
fn agents_list_create_and_open_browser_profiles_through_mcp_and_the_cli() {
    let server = HeadlessServer::start("browser-profiles-mcp");
    let results = mcp_calls(
        &server,
        &[
            ("browser_profile_create", serde_json::json!({"name": "Work"})),
            ("browser_profile_list", serde_json::json!({})),
            (
                "browser_profile_open",
                serde_json::json!({"url": "https://example.com/mcp", "profile": "Work"}),
            ),
            ("browser_profile_create", serde_json::json!({"name": "bad\u{7}name"})),
            (
                "browser_profile_open",
                serde_json::json!({"url": "file:///etc/hosts", "profile": "Work"}),
            ),
        ],
    );
    for (index, result) in results.iter().take(3).enumerate() {
        assert_eq!(result["isError"], false, "call {index}: {result}");
    }
    let created = &results[0]["structuredContent"];
    let work = text(find(created, "id"));
    assert_eq!(work.len(), 36, "{created}");
    assert_eq!(text(find(created, "name")), "Work", "{created}");

    let listed = find(&results[1]["structuredContent"], "browser_profiles")
        .and_then(|profiles| profiles.as_array())
        .cloned()
        .unwrap_or_else(|| panic!("no browser_profiles: {}", results[1]));
    let names: Vec<&str> = listed.iter().filter_map(|p| p["name"].as_str()).collect();
    assert_eq!(names, ["Default", "Work"], "{listed:?}");
    assert!(listed.iter().all(|p| p.get("source").is_none()), "{listed:?}");

    let opened = &results[2]["structuredContent"];
    let tab = text(find(opened, "tab_id"));
    assert!(tab.starts_with("tab_"), "{opened}");
    assert_eq!(text(find(opened, "profile_id")), work, "{opened}");
    assert_eq!(profile_of(&server, &tab), work);

    for refused_call in &results[3..] {
        assert_eq!(refused_call["isError"], true, "{refused_call}");
        assert_eq!(
            text(find(&refused_call["structuredContent"], "code")),
            "validation.invalid",
            "{refused_call}"
        );
    }

    // The noun-first CLI sends the same operations.
    let listed = ok(&server, &["browser", "profile", "list"]);
    assert!(find(&listed, "workspaces").is_none(), "the list shows personal state: {listed}");
    let rows = find(&listed, "browser_profiles").and_then(|p| p.as_array()).cloned();
    assert_eq!(rows.map(|rows| rows.len()), Some(2), "{listed}");
    let client =
        text(find(&ok(&server, &["browser", "profile", "create", "--name", "Client"]), "id"));
    assert_eq!(client.len(), 36);
    let opened =
        ok(&server, &["browser", "profile", "open", "https://example.org/", "--profile", &client]);
    let second = text(find(&opened, "tab_id"));
    assert!(second.starts_with("tab_") && second != tab, "{opened}");
    assert_eq!(profile_of(&server, &second), client);
    let error = refused(
        &server,
        &["browser", "profile", "open", "javascript:alert(1)", "--profile", "Work"],
    );
    assert!(error.contains("url"), "{error}");
}

/// The frontend tab record and its pane's active tab, from the raw tree.
fn tab_record(server: &HeadlessServer, tab: &str) -> (serde_json::Value, String, bool) {
    let tree = raw_json(server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    for workspace in tree["workspaces"].as_array().into_iter().flatten() {
        for screen in workspace["screens"].as_array().into_iter().flatten() {
            for pane in screen["panes"].as_array().into_iter().flatten() {
                let tabs = pane["tabs"].as_array().cloned().unwrap_or_default();
                if let Some(record) = tabs.iter().find(|row| row["tab_resource_id"] == tab) {
                    let active = pane["active_tab"].as_u64().and_then(|i| tabs.get(i as usize));
                    let selected = active.is_some_and(|row| row["tab_resource_id"] == tab);
                    return (record.clone(), text(pane.get("resource_id")), selected);
                }
            }
        }
    }
    panic!("no tab {tab} in {tree}");
}

/// cx-2kl68 review: a retry with the same idempotency key answers the same
/// profile and the same tab; another key makes another profile; any key the
/// envelope accepts works for open (128 bytes too); open honors an explicit
/// pane and background; with no engine the tab opens in the person's
/// `browser.defaultEngine` (chromium is the cef engine).
#[test]
fn agents_retry_browser_profile_create_and_open_with_their_keys_through_mcp() {
    let config = unique_temp_dir("browser-profiles-keys-config");
    fs::create_dir_all(&config).unwrap();
    let settings = config.join("cmux-next.json");
    fs::write(&settings, r#"{"browser": {"defaultEngine": "chromium"}}"#).unwrap();
    let server = HeadlessServer::start_with_options(
        "browser-profiles-keys",
        None,
        None,
        &[("CMUX_NEXT_CONFIG_FILE", settings.to_str().unwrap())],
    );
    let created = mcp_calls(
        &server,
        &[
            (
                "browser_profile_create",
                serde_json::json!({"name": "Work", "idempotency_key": "k1"}),
            ),
            (
                "browser_profile_create",
                serde_json::json!({"name": "Work", "idempotency_key": "k1"}),
            ),
            (
                "browser_profile_create",
                serde_json::json!({"name": "Work", "idempotency_key": "k2"}),
            ),
        ],
    );
    for (index, result) in created.iter().enumerate() {
        assert_eq!(result["isError"], false, "create {index}: {result}");
    }
    let id = |index: usize| text(find(&created[index]["structuredContent"], "id"));
    assert_eq!(id(0).len(), 36, "{}", created[0]);
    assert_eq!(id(1), id(0), "a retry made another profile: {}", created[1]);
    assert_ne!(id(2), id(0), "another key found the first profile: {}", created[2]);
    let work = id(0);

    // A fresh headless daemon has no workspace until something opens one.
    ok(&server, &["tab", "create", "terminal"]);
    let tree = raw_json(&server, serde_json::json!({"id": "tree", "cmd": "list-workspaces"}));
    let pane = text(
        find(&tree, "panes").and_then(|panes| panes.get(0)).and_then(|p| p.get("resource_id")),
    );
    assert!(pane.starts_with("pane_"), "{tree}");
    let long_key = "k".repeat(128);
    let open = serde_json::json!({"url": "https://example.com/keys", "profile": work,
        "pane": pane, "activate": false, "idempotency_key": long_key});
    let opened = mcp_calls(
        &server,
        &[("browser_profile_open", open.clone()), ("browser_profile_open", open)],
    );
    for (index, result) in opened.iter().enumerate() {
        assert_eq!(result["isError"], false, "open {index}: {result}");
    }
    let tab = text(find(&opened[0]["structuredContent"], "tab_id"));
    assert!(tab.starts_with("tab_"), "{}", opened[0]);
    assert_eq!(text(find(&opened[1]["structuredContent"], "tab_id")), tab, "{}", opened[1]);
    let (record, in_pane, selected) = tab_record(&server, &tab);
    assert_eq!(in_pane, pane, "{record}");
    assert!(!selected, "activate false selected the tab: {record}");
    assert_eq!(record["browser_profile_id"], work.as_str(), "{record}");
    assert_eq!(
        record["browser_engine"], "cef",
        "the default engine is not the setting's: {record}"
    );

    // The CLI's --pane and --background send the same fields.
    let cli = ok(
        &server,
        &[
            "browser",
            "profile",
            "open",
            "https://example.org/keys",
            "--profile",
            &work,
            "--pane",
            &pane,
            "--background",
            "true",
            "--engine",
            "webkit",
        ],
    );
    let second = text(find(&cli, "tab_id"));
    let (record, in_pane, selected) = tab_record(&server, &second);
    assert_eq!(in_pane, pane, "{record}");
    assert!(!selected, "--background true selected the tab: {record}");
    assert_eq!(record["browser_engine"], "webkit", "{record}");
}

/// #24432: `cmux browser profile proxy set|clear` binds a proxy to a profile
/// (by name or id); `browser profile list` shows it. A URL with credentials
/// is refused before anything is sent, so no secret reaches a record.
#[test]
fn a_profile_proxy_is_set_listed_and_cleared_through_the_cli() {
    let server = HeadlessServer::start("browser-profile-proxy");
    let work = text(find(&ok(&server, &["browser", "profile", "create", "--name", "US-A"]), "id"));
    let set = ok(
        &server,
        &[
            "browser",
            "profile",
            "proxy",
            "set",
            "--profile",
            "US-A",
            "--url",
            "socks5://127.0.0.1:1080",
        ],
    );
    assert_eq!(find(&set, "proxy").unwrap()["scheme"], "socks5", "{set}");
    let listed = ok(&server, &["browser", "profile", "list"]);
    let profiles = find(&listed, "profiles").or_else(|| find(&listed, "browser_profiles")).cloned();
    let profiles = profiles.unwrap_or(listed.clone());
    let us_a = profiles
        .as_array()
        .and_then(|all| all.iter().find(|p| p["id"] == work.as_str()))
        .cloned()
        .unwrap_or_else(|| panic!("no US-A in {listed}"));
    assert_eq!(
        us_a["proxy"],
        serde_json::json!({"scheme":"socks5","host":"127.0.0.1","port":1080})
    );

    let secret = refused(
        &server,
        &[
            "browser",
            "profile",
            "proxy",
            "set",
            "--profile",
            "US-A",
            "--url",
            "http://me:pw@gw.test:8080",
        ],
    );
    assert!(secret.contains("local relay"), "{secret}");
    assert!(!secret.contains("pw@"), "the refusal echoed the secret: {secret}");
    refused(
        &server,
        &["browser", "profile", "proxy", "set", "--profile", "US-A", "--url", "ftp://gw.test:21"],
    );

    ok(&server, &["browser", "profile", "proxy", "clear", "--profile", "US-A"]);
    let listed = ok(&server, &["browser", "profile", "list"]);
    assert!(listed.to_string().contains(&work), "{listed}");
    assert!(!listed.to_string().contains("1080"), "the proxy stayed: {listed}");
}
