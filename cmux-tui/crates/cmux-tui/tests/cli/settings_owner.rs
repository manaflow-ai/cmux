//! The daemon's settings owner (`settings-v1`, cx-9ce.10) through the CLI
//! (`cmux raw operation settings.*`) and a real daemon: in-place edits keep
//! the comments of the settings file, a managed key and an invalid value are
//! refused, an agent may not change a user-only key, and a hand edit of the
//! file raises `settings-changed` on the subscribe stream. The managed key
//! comes from CMUX_NEXT_MANAGED_PREFS_FILE, which only debug builds read.
#![cfg(unix)]

use super::*;

const COMMENTED: &str = "// my cmux settings\n{\n  // the tab bar stays on top\n  \"tabs\": {\n    \"barPosition\": \"top\" /* inline */\n  },\n  \"unknownKey\": 1,\n}\n";

struct SettingsDaemon {
    server: HeadlessServer,
    config: PathBuf,
}

impl SettingsDaemon {
    fn start(name: &str) -> Self {
        let root = unique_temp_dir(&format!("{name}-files"));
        fs::create_dir_all(&root).unwrap();
        let config = root.join("cmux-next.json");
        fs::write(&config, COMMENTED).unwrap();
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
        for code in ["settings.managed", "settings.invalid", "settings.agent_refused"] {
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
}
