//! The daemon's keybindings.json owner (`keybindings-v1`, cx-9ce.17, K-T6)
//! through the CLI (`cmux raw operation keybindings.*`) and a real daemon:
//! the Keyboard Shortcuts page's set, remove and reset edit the file in place
//! (comments and untouched entries kept), what cmux.json cannot hold (a
//! `when`, arguments, three keys, the replacement of a default) is written,
//! the bindings survive a daemon restart, a bad key is refused without a
//! write, and a hand edit raises `keybindings-changed` on the subscribe
//! stream. The file sits beside the settings file (CMUX_NEXT_CONFIG_FILE).
#![cfg(unix)]

use super::*;

const COMMENTED: &str = "// my keys\n[\n  // split with the leader\n  { \"key\": \"cmd+j v\", \"command\": \"splitRight\" } /* kept */,\n]\n";

struct KeybindingsDaemon {
    server: HeadlessServer,
    config: PathBuf,
    keybindings: PathBuf,
}

impl KeybindingsDaemon {
    fn files(name: &str) -> (PathBuf, PathBuf) {
        let root = unique_temp_dir(&format!("{name}-files"));
        fs::create_dir_all(&root).unwrap();
        let config = root.join("cmux-next.json");
        fs::write(&config, "{}\n").unwrap();
        let keybindings = root.join("keybindings.json");
        fs::write(&keybindings, COMMENTED).unwrap();
        (config, keybindings)
    }

    fn start(name: &str, config: PathBuf, keybindings: PathBuf) -> Self {
        let server = HeadlessServer::start_with_options(
            name,
            None,
            None,
            &[("CMUX_NEXT_CONFIG_FILE", config.to_str().unwrap())],
        );
        Self { server, config, keybindings }
    }

    /// `cmux --json raw operation <op> --params-json <params>`.
    fn op(&self, operation: &str, params: serde_json::Value, mutation: bool) -> Output {
        self.op_with_key(operation, params, mutation, None)
    }

    /// `op` with a global `--idempotency-key` (a retry reuses it).
    fn op_with_key(
        &self,
        operation: &str,
        params: serde_json::Value,
        mutation: bool,
        key: Option<&str>,
    ) -> Output {
        let mut params = params;
        params["machine"] = serde_json::json!("current");
        params["session"] = serde_json::json!("current");
        let mut command = Command::new(bin());
        command
            .args(["--json", "--socket"])
            .arg(&self.server.socket)
            .args(key.map(|key| ["--idempotency-key", key]).into_iter().flatten())
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

    fn refused(&self, operation: &str, params: serde_json::Value) -> String {
        let output = self.op(operation, params, true);
        assert!(!output.status.success(), "{operation} was not refused");
        format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    }

    fn file(&self) -> String {
        fs::read_to_string(&self.keybindings).unwrap()
    }

    /// The file's entries as `keybindings.get` reports them.
    fn entries(&self) -> Vec<serde_json::Value> {
        self.ok("keybindings.get", serde_json::json!({}), false)["entries"]
            .as_array()
            .unwrap_or_else(|| panic!("keybindings.get has no entries"))
            .clone()
    }
}

#[test]
fn keybindings_owner_writes_what_cmux_json_cannot_hold_and_it_survives_a_restart() {
    let (config, keybindings) = KeybindingsDaemon::files("keybindings-owner-writes");
    let daemon = KeybindingsDaemon::start("keybindings-owner-writes", config, keybindings);
    let identify = try_json_socket_request(
        &daemon.server.socket,
        serde_json::json!({"id": 1, "cmd": "identify"}),
    )
    .unwrap();
    assert!(identify.to_string().contains("keybindings-v1"), "no keybindings-v1: {identify}");

    let entries = daemon.entries();
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(entries[0]["command"], "splitRight");
    assert_eq!(entries[0]["keys"], serde_json::json!(["cmd+j", "v"]));

    // Three keys, a `when` and arguments, replacing a default (Cmd-T): a
    // removal of the default and the new entry.
    daemon.ok(
        "keybindings.set",
        serde_json::json!({
            "command": "newTab",
            "key": "ctrl+k ctrl+t t",
            "when": "surfaceKind == terminal",
            "args": {"profile": "work"},
            "replaces": {"key": "cmd+t"},
        }),
        true,
    );
    // One of several keys of an action: only that key goes.
    daemon.ok(
        "keybindings.remove",
        serde_json::json!({"command": "closeTab", "key": "cmd+w"}),
        true,
    );
    let text = daemon.file();
    for kept in ["// my keys", "// split with the leader", "/* kept */", "\"cmd+j v\""] {
        assert!(text.contains(kept), "an edit lost {kept:?}:\n{text}");
    }
    assert!(text.contains("\"-newTab\"") && text.contains("\"-closeTab\""), "{text}");

    let before = daemon.file();
    let refusal =
        daemon.refused("keybindings.set", serde_json::json!({"command": "newTab", "key": "t"}));
    assert!(refusal.contains("keybindings.invalid"), "{refusal}");
    let refusal = daemon.refused(
        "keybindings.set",
        serde_json::json!({"command": "newTab", "key": "cmd+a b c d e"}),
    );
    assert!(refusal.contains("keybindings.invalid"), "{refusal}");
    assert_eq!(daemon.file(), before, "a refused write changed the file");

    // A relaunch reads the same bindings back from the file.
    let KeybindingsDaemon { server, config, keybindings } = daemon;
    drop(server);
    let daemon = KeybindingsDaemon::start("keybindings-owner-relaunch", config, keybindings);
    let entries = daemon.entries();
    let bound = entries
        .iter()
        .find(|entry| entry["command"] == "newTab" && entry["removal"] == false)
        .unwrap_or_else(|| panic!("the rebind did not survive the restart: {entries:?}"));
    assert_eq!(bound["keys"], serde_json::json!(["ctrl+k", "ctrl+t", "t"]));
    assert_eq!(bound["when"], "surfaceKind == terminal");
    assert_eq!(bound["args"], serde_json::json!({"profile": "work"}));
    assert!(
        entries.iter().any(|entry| entry["command"] == "newTab"
            && entry["removal"] == true
            && entry["keys"] == serde_json::json!(["cmd+t"])),
        "{entries:?}"
    );

    // Reset takes every entry and removal of the action out: its defaults return.
    daemon.ok("keybindings.reset", serde_json::json!({"command": "newTab"}), true);
    let entries = daemon.entries();
    assert!(!entries.iter().any(|entry| entry["command"] == "newTab"), "{entries:?}");
    assert!(daemon.file().contains("// split with the leader"));
    assert!(daemon.config.exists());

    // A palette key has neither cmd nor ctrl: its default can still be
    // removed (as the app's loader allows), and reset brings it back.
    daemon.ok(
        "keybindings.remove",
        serde_json::json!({"command": "paletteKey.escape", "key": "escape"}),
        true,
    );
    assert!(
        daemon.entries().iter().any(|entry| entry["command"] == "paletteKey.escape"
            && entry["removal"] == true
            && entry["keys"] == serde_json::json!(["escape"])),
        "{}",
        daemon.file()
    );
    daemon.ok("keybindings.reset", serde_json::json!({"command": "paletteKey.escape"}), true);
    assert!(!daemon.file().contains("paletteKey.escape"), "{}", daemon.file());

    // A retry with the same idempotency key writes once; the key with
    // another op is a conflict.
    let set = serde_json::json!({"command": "splitDown", "key": "cmd+j d"});
    for _ in 0..2 {
        let output = daemon.op_with_key("keybindings.set", set.clone(), true, Some("retry-1"));
        assert_success(&output);
    }
    let bound = daemon.entries().iter().filter(|entry| entry["command"] == "splitDown").count();
    assert_eq!(bound, 1, "a retry wrote the binding again:\n{}", daemon.file());
    let output = daemon.op_with_key(
        "keybindings.remove",
        serde_json::json!({"command": "splitDown", "key": "cmd+j d"}),
        true,
        Some("retry-1"),
    );
    assert!(!output.status.success(), "the reused key was not refused");
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(text.contains("idempotency.conflict"), "{text}");
}

#[test]
fn keybindings_owner_reports_a_hand_edit_of_the_file_on_the_subscribe_stream() {
    let (config, keybindings) = KeybindingsDaemon::files("keybindings-owner-watch");
    let daemon = KeybindingsDaemon::start("keybindings-owner-watch", config, keybindings);
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
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let line = rx.recv_timeout(deadline - Instant::now()).expect("subscribe answered");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["id"] == 1 {
            assert_eq!(message["ok"], true, "{message}");
            break;
        }
    }
    let next_keybindings_event = |what: &str| -> serde_json::Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .unwrap_or_else(|| panic!("no keybindings-changed event for {what}"));
            let line = rx.recv_timeout(remaining).unwrap_or_else(|_| panic!("no event for {what}"));
            let message: serde_json::Value = serde_json::from_str(&line).unwrap();
            if message["event"] == "keybindings-changed" {
                return message;
            }
        }
    };

    // A hand edit, saved the way editors do: a new file renamed over the old.
    let edited = COMMENTED.replace("\"cmd+j v\"", "\"cmd+j s\"");
    let temporary = daemon.keybindings.with_extension("json.editor-tmp");
    fs::write(&temporary, edited).unwrap();
    fs::rename(&temporary, &daemon.keybindings).unwrap();
    let event = next_keybindings_event("the hand edit");
    assert_eq!(event["origin"], "file", "{event}");
    assert_eq!(daemon.entries()[0]["keys"], serde_json::json!(["cmd+j", "s"]));

    daemon.ok(
        "keybindings.set",
        serde_json::json!({"command": "splitDown", "key": "cmd+j d"}),
        true,
    );
    let event = next_keybindings_event("the CLI write");
    assert_eq!(event["origin"], "cli", "{event}");
    assert!(event["revision"].as_u64().is_some(), "{event}");
}

/// K1 (cx-9ce.37): a bare first stroke (no cmd, ctrl or opt) binds only
/// under a `when` whose `&&` terms require a bare-key page (the diff viewer,
/// a read-only markdown page) and no context that can hold with a text
/// field; the app's loader applies the same rule (keybinding-vectors.json).
/// Other bare entries stay out of `keybindings.get` with a diagnostic, and
/// `keybindings.set` refuses them without a write.
#[test]
fn keybindings_owner_binds_a_bare_sequence_only_under_a_bare_key_page() {
    let (config, keybindings) = KeybindingsDaemon::files("keybindings-owner-bare");
    let file = r#"[
  {"key": "g g", "command": "markdownGoToTop", "when": "markdownReadOnlyFocused"},
  {"key": "] f", "command": "diffViewerNextFile", "when": "pageId == 'cmux.diff' && (diffViewerFocused)"},
  {"key": "g g", "command": "markdownGoToTop"},
  {"key": "g g", "command": "markdownGoToTop", "when": "markdownReadOnlyFocused && textInputFocus"},
  {"key": "g g", "command": "markdownGoToTop", "when": "markdownReadOnlyFocused || terminalFocused"},
  {"key": "g g", "command": "markdownGoToTop", "when": "!markdownReadOnlyFocused"},
  {"key": "g g", "command": "markdownGoToTop", "when": "pageId == 'a && markdownReadOnlyFocused'"},
  {"key": "opt+g g", "command": "markdownGoToTop", "when": "markdownReadOnlyFocused"}
]
"#;
    fs::write(&keybindings, file).unwrap();
    let daemon = KeybindingsDaemon::start("keybindings-owner-bare", config, keybindings);
    let entries = daemon.entries();
    let loaded: Vec<_> =
        entries.iter().map(|entry| (entry["keys"].clone(), entry["when"].clone())).collect();
    assert_eq!(
        loaded,
        vec![
            (serde_json::json!(["g", "g"]), serde_json::json!("markdownReadOnlyFocused")),
            (
                serde_json::json!(["]", "f"]),
                serde_json::json!("pageId == 'cmux.diff' && (diffViewerFocused)")
            ),
        ],
        "{entries:?}"
    );
    let get = daemon.ok("keybindings.get", serde_json::json!({}), false);
    let refused: Vec<_> = get["diagnostics"]
        .as_array()
        .unwrap_or_else(|| panic!("keybindings.get has no diagnostics: {get}"))
        .iter()
        .map(|diagnostic| {
            assert!(
                diagnostic["message"].as_str().is_some_and(|text| text.contains("bare-key")),
                "{diagnostic}"
            );
            diagnostic["index"].as_u64().unwrap_or(u64::MAX)
        })
        .collect();
    assert_eq!(refused, vec![2, 3, 4, 5, 6, 7], "{get}");

    let before = daemon.file();
    let refusal = daemon.refused(
        "keybindings.set",
        serde_json::json!({"command": "markdownGoToTop", "key": "g t", "when": "textInputFocus && markdownReadOnlyFocused"}),
    );
    assert!(refusal.contains("keybindings.invalid"), "{refusal}");
    assert_eq!(daemon.file(), before, "a refused write changed the file");
    daemon.ok(
        "keybindings.set",
        serde_json::json!({"command": "markdownGoToTop", "key": "g t", "when": "markdownReadOnlyFocused"}),
        true,
    );
    assert!(
        daemon.entries().iter().any(|entry| entry["keys"] == serde_json::json!(["g", "t"])),
        "{}",
        daemon.file()
    );
}
