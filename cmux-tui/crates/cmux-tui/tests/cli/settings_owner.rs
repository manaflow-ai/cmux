//! The daemon's settings owner (`settings-v1`, cx-9ce.10) through the CLI
//! (`cmux raw operation settings.*`) and a real daemon: in-place edits keep
//! the comments of the settings file, a managed key and an invalid value are
//! refused, an agent may not change a user-only key, a retired key is refused
//! as removed, and a hand edit of the file raises `settings-changed` on the
//! subscribe stream. The managed key
//! comes from CMUX_NEXT_MANAGED_PREFS_FILE, which only debug builds read.
#![cfg(unix)]

use super::*;

// The keybindings.json owner beside the settings file (cx-9ce.17).
#[path = "keybindings_owner.rs"]
mod keybindings_owner;

const COMMENTED: &str = "// my cmux settings\n{\n  // the tab bar stays on top\n  \"tabs\": {\n    \"barPosition\": \"top\" /* inline */\n  },\n  \"unknownKey\": 1,\n}\n";

#[test]
fn settings_list_reads_the_daemon_without_an_app() {
    use serde_json::json;
    use std::os::unix::process::CommandExt as _;

    let daemon = SettingsDaemon::start_with(
        "settings-list",
        r#"{"sidebar":{"side":"right","density":"invalid"},"credentials":{"token":"private-fixture-token"}}"#,
    );
    let list = |args: &[&str]| {
        Command::new(bin())
            .arg0("cmux")
            .args(["--json", "--socket"])
            .arg(&daemon.server.socket)
            .args(["--app-socket"])
            .arg(daemon.server.dir.join("no-app.sock"))
            .args(args)
            .env("HOME", &daemon.server.dir)
            .env("CFFIXED_USER_HOME", &daemon.server.dir)
            .env("CMUX_NEXT_CONFIG_FILE", &daemon.config)
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .output()
            .unwrap()
    };
    let output = list(&["settings", "list"]);
    assert_success(&output);
    let rows = json_output(&output);
    assert_eq!(rows, daemon.ok("settings.list", json!({}), false));
    let keys: Vec<_> =
        rows.as_array().unwrap().iter().map(|row| row["key"].as_str().unwrap()).collect();
    let schema = cmux_config::Schema::embedded();
    assert_eq!(keys, schema.rows.iter().map(|row| row.key.as_str()).collect::<Vec<_>>());
    assert!(!String::from_utf8_lossy(&output.stdout).contains("private-fixture-token"));
    let row = |key: &str| rows.as_array().unwrap().iter().find(|row| row["key"] == key).unwrap();
    assert_eq!(row("sidebar.side")["value"], "right");
    assert_eq!(row("sidebar.side")["customized"], true);
    assert_eq!(row("sidebar.density")["value"], row("sidebar.density")["default"]);
    assert_eq!(row("window.titlebar")["value"], "standard");
    assert!(!row("window.titlebar")["managed"].is_null());
    let filtered = list(&["config", "list", "--section", "appearance"]);
    assert_success(&filtered);
    assert_eq!(
        json_output(&filtered),
        daemon.ok("settings.list", json!({"section":"appearance"}), false)
    );
    assert_eq!(json_output(&list(&["settings", "list"])), rows, "stable order");

    for args in [
        vec!["settings", "list", "--section"],
        vec!["settings", "list", "--section", ""],
        vec!["settings", "list", "--section", "unknown-section"],
        vec!["settings", "list", "--section", "browser", "--section", "appearance"],
        vec!["settings", "list", "--bogus"],
        vec!["settings", "list", "extra"],
    ] {
        let output = list(&args);
        assert_eq!(output.status.code(), Some(2), "{args:?}: {output:?}");
    }
}

struct SettingsDaemon {
    server: HeadlessServer,
    config: PathBuf,
}

impl SettingsDaemon {
    fn start(name: &str) -> Self {
        Self::start_with(name, COMMENTED)
    }

    /// A daemon whose settings file starts as `text`.
    fn start_with(name: &str, text: &str) -> Self {
        let root = unique_temp_dir(&format!("{name}-files"));
        fs::create_dir_all(&root).unwrap();
        let config = root.join("cmux-next.json");
        fs::write(&config, text).unwrap();
        // `window.titlebar` is forced by the administrator.
        let managed = if cfg!(target_os = "macos") {
            let path = root.join("managed.plist");
            fs::write(
                &path,
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
                 <key>window.titlebar</key><string>standard</string></dict></plist>\n",
            )
            .unwrap();
            path
        } else {
            let path = root.join("managed.json");
            fs::write(&path, r#"{"window.titlebar": "standard"}"#).unwrap();
            path
        };
        let server = HeadlessServer::start_with_options(
            name,
            None,
            None,
            &[
                ("CMUX_NEXT_CONFIG_FILE", config.to_str().unwrap()),
                ("CMUX_NEXT_MANAGED_PREFS_FILE", managed.to_str().unwrap()),
            ],
        );
        Self { server, config }
    }

    /// `cmux --json raw operation <op> --params-json <params>`.
    fn op(&self, operation: &str, params: serde_json::Value, mutation: bool) -> Output {
        let mut params = params;
        params["machine"] = serde_json::json!("current");
        params["session"] = serde_json::json!("current");
        let mut command = Command::new(bin());
        command
            .args(["--json", "--socket"])
            .arg(&self.server.socket)
            .args(["raw", "operation", operation, "--params-json", &params.to_string()])
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID");
        if mutation {
            command.arg("--mutation");
        }
        command.output().unwrap()
    }

    fn ok(&self, operation: &str, params: serde_json::Value, mutation: bool) -> serde_json::Value {
        let output = self.op(operation, params, mutation);
        assert_success(&output);
        json_output(&output)
    }

    /// The refusal's code, from a failed write.
    fn refused(&self, operation: &str, params: serde_json::Value) -> String {
        let output = self.op(operation, params, true);
        assert!(!output.status.success(), "{operation} was not refused");
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        for code in
            ["settings.managed", "settings.invalid", "settings.agent_refused", "settings.removed"]
        {
            if text.contains(code) {
                return code.to_owned();
            }
        }
        panic!("{operation}: no settings refusal code in {text}");
    }

    fn file(&self) -> String {
        fs::read_to_string(&self.config).unwrap()
    }

    fn get(&self, key: &str) -> serde_json::Value {
        self.ok("settings.get", serde_json::json!({"key": key}), false)
    }
}

#[test]
fn settings_owner_edits_the_file_in_place_and_refuses_managed_invalid_and_agent_writes() {
    let daemon = SettingsDaemon::start("settings-owner-writes");
    let identify = try_json_socket_request(
        &daemon.server.socket,
        serde_json::json!({"id": 1, "cmd": "identify"}),
    )
    .unwrap();
    assert!(identify.to_string().contains("settings-v1"), "no settings-v1: {identify}");

    assert_eq!(daemon.get("tabs.barPosition")["value"], "top");

    daemon.ok(
        "settings.set",
        serde_json::json!({"key": "tabs.barPosition", "value": "bottom"}),
        true,
    );
    let text = daemon.file();
    assert!(text.contains("\"barPosition\": \"bottom\""), "{text}");
    for kept in
        ["// my cmux settings", "// the tab bar stays on top", "/* inline */", "\"unknownKey\": 1"]
    {
        assert!(text.contains(kept), "the set lost {kept:?}:\n{text}");
    }
    assert_eq!(daemon.get("tabs.barPosition")["value"], "bottom");

    daemon.ok(
        "settings.set",
        serde_json::json!({"key": "layout.defaultColumnWidth", "value": 0.75}),
        true,
    );
    assert_eq!(daemon.get("layout.defaultColumnWidth")["value"], 0.75);

    let before = daemon.file();
    assert_eq!(
        daemon.refused(
            "settings.set",
            serde_json::json!({"key": "window.titlebar", "value": "minimal"})
        ),
        "settings.managed"
    );
    assert_eq!(daemon.get("window.titlebar")["value"], "standard", "the forced value applies");
    assert_eq!(
        daemon.refused(
            "settings.set",
            serde_json::json!({"key": "layout.defaultColumnWidth", "value": 7})
        ),
        "settings.invalid"
    );
    assert_eq!(
        daemon.refused(
            "settings.set",
            serde_json::json!({"key": "tabs.barPosition", "value": "sideways"})
        ),
        "settings.invalid"
    );
    assert_eq!(
        daemon.refused(
            "settings.set",
            serde_json::json!({"key": "history.terminalCommands", "value": true, "origin": "mcp"})
        ),
        "settings.agent_refused"
    );
    assert_eq!(
        daemon.refused(
            "settings.set",
            serde_json::json!({"key": "history.terminalCommands", "value": true})
        ),
        "settings.agent_refused",
        "a user-only key needs origin user, like the app socket's --confirm"
    );
    assert_eq!(
        daemon.refused("settings.reset_all", serde_json::json!({})),
        "settings.agent_refused"
    );
    assert_eq!(daemon.file(), before, "a refused write changed the file");
    daemon.ok(
        "settings.set",
        serde_json::json!({"key": "history.terminalCommands", "value": true, "origin": "user"}),
        true,
    );
    assert_eq!(daemon.get("history.terminalCommands")["value"], true);

    let rows = daemon.ok("settings.list", serde_json::json!({}), false);
    let row =
        |key: &str| rows.as_array().unwrap().iter().find(|row| row["key"] == key).cloned().unwrap();
    assert_eq!(row("window.titlebar")["managed"]["source"], "mdm", "{rows}");
    assert_eq!(row("tabs.barPosition")["customized"], true);

    daemon.ok("settings.reset", serde_json::json!({"key": "layout.defaultColumnWidth"}), true);
    let text = daemon.file();
    assert!(!text.contains("defaultColumnWidth"), "{text}");
    assert!(text.contains("// the tab bar stays on top"), "the reset lost a comment:\n{text}");
}

/// The retired keys (schemas/settings/retired-keys.json, cx-d5b5d): an old
/// file that still sets them loads, a write of any of them is refused as
/// removed and leaves the file alone, and a reset prunes one from the file.
#[test]
fn settings_owner_refuses_a_write_of_a_retired_key_and_prunes_it_on_reset() {
    let old = COMMENTED.replace(
        "\"top\" /* inline */",
        "\"top\" /* inline */,\n    \"newTabKind\": \"terminal\",\n    \"hiddenButtons\": [\"pane.split.right\"]",
    );
    let daemon = SettingsDaemon::start_with("settings-owner-retired", &old);
    assert_eq!(daemon.get("tabs.barPosition")["value"], "top", "the old file loads");

    let before = daemon.file();
    for (key, value) in [
        ("tabs.hiddenButtons", serde_json::json!(["pane.split.right", "pane.close"])),
        ("tabs.newTabKind", serde_json::json!("same-kind")),
        ("appearance.tabBarBackground", serde_json::json!("#000000")),
        ("updates.quietHours", serde_json::json!(true)),
    ] {
        assert_eq!(
            daemon.refused("settings.set", serde_json::json!({"key": key, "value": value})),
            "settings.removed",
            "{key} is retired"
        );
    }
    assert_eq!(daemon.file(), before, "a refused write of a retired key changed the file");

    daemon.ok("settings.reset", serde_json::json!({"key": "tabs.hiddenButtons"}), true);
    daemon.ok("settings.reset", serde_json::json!({"key": "tabs.newTabKind"}), true);
    let text = daemon.file();
    for gone in ["hiddenButtons", "newTabKind"] {
        assert!(!text.contains(gone), "the reset kept {gone}:\n{text}");
    }
    for kept in ["// the tab bar stays on top", "\"barPosition\": \"top\"", "\"unknownKey\": 1"] {
        assert!(text.contains(kept), "the reset lost {kept:?}:\n{text}");
    }
}

#[test]
fn settings_owner_reports_a_hand_edit_of_the_file_on_the_subscribe_stream() {
    let daemon = SettingsDaemon::start("settings-owner-watch");
    let stream = transport::connect(&daemon.server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stream).lines() {
            if tx.send(line.unwrap()).is_err() {
                break;
            }
        }
    });
    writeln!(writer, r#"{{"id":1,"cmd":"subscribe"}}"#).unwrap();
    writer.flush().unwrap();
    let next_settings_event = |what: &str| -> serde_json::Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .unwrap_or_else(|| panic!("no settings-changed event for {what}"));
            let line = rx.recv_timeout(remaining).unwrap_or_else(|_| panic!("no event for {what}"));
            let message: serde_json::Value = serde_json::from_str(&line).unwrap();
            if message["event"] == "settings-changed" {
                return message;
            }
        }
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let line = rx.recv_timeout(deadline - Instant::now()).expect("subscribe answered");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["id"] == 1 {
            assert_eq!(message["ok"], true, "{message}");
            break;
        }
    }

    // A hand edit, saved the way editors do: a new file renamed over the old.
    let edited = COMMENTED.replace("\"top\"", "\"bottom\"");
    let temporary = daemon.config.with_extension("json.editor-tmp");
    fs::write(&temporary, edited).unwrap();
    fs::rename(&temporary, &daemon.config).unwrap();
    let event = next_settings_event("the hand edit");
    assert_eq!(event["origin"], "file", "{event}");
    assert!(
        event["keys"].as_array().unwrap().iter().any(|key| key == "tabs.barPosition"),
        "{event}"
    );
    assert_eq!(daemon.get("tabs.barPosition")["value"], "bottom");

    daemon.ok("settings.set", serde_json::json!({"key": "tabs.barPosition", "value": "top"}), true);
    let event = next_settings_event("the CLI write");
    assert_eq!(event["origin"], "cli", "{event}");
    assert!(event["revision"].as_u64().is_some(), "{event}");

    // Two saves right after each other end in the second file: the reload
    // after the burst reports both keys (one settings-changed when the saves
    // fall into one burst, as they do unless the runner stalls between them).
    let first = COMMENTED.replace("\"top\"", "\"bottom\"");
    let second = first.replace("/* inline */", "/* inline */,\n    \"cmdWClosesPinnedTabs\": true");
    for text in [&first, &second] {
        fs::write(&temporary, text).unwrap();
        fs::rename(&temporary, &daemon.config).unwrap();
    }
    let mut reported = std::collections::BTreeSet::new();
    while !(reported.contains("tabs.barPosition") && reported.contains("tabs.cmdWClosesPinnedTabs"))
    {
        let event = next_settings_event("the burst of two saves");
        assert_eq!(event["origin"], "file", "{event}");
        reported.extend(
            event["keys"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|key| key.as_str().map(String::from)),
        );
    }
    assert_eq!(daemon.get("tabs.barPosition")["value"], "bottom");
    assert_eq!(daemon.get("tabs.cmdWClosesPinnedTabs")["value"], true);
}
