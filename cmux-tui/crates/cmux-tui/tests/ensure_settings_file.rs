//! The settings file is part of an owner's launch: `server ensure` started
//! with CMUX_NEXT_CONFIG_FILE (as the app starts its daemon,
//! plans/cmux-next/settings-react.md section 7, item 1) starts a detached
//! owner that reads and writes that file and names it in `settings.snapshot`
//! (`path`). A client with a settings file of its own compares the two
//! before it sends a write, so the write never goes to another file. A
//! `server restart` from a client without the variable keeps the file.
//! A real owner process; the clients after the launch name no settings file.

// `server restart` reads the old owner's launch from the OS on these two.
#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-sf-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        Self { socket: dir.join("mux.sock"), session: "ensure-settings-file".into(), dir }
    }

    /// A `cmux-tui` process with this fixture's home and state and without
    /// a settings file variable: only the launch names the file.
    fn cmux(&self) -> Command {
        let home = self.dir.join("home");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .env("HOME", &home)
            .env("CFFIXED_USER_HOME", &home)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("SHELL", "/bin/sh")
            .env("LC_ALL", "C")
            .env_remove("CMUX_NEXT_CONFIG_FILE")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG");
        command
    }

    fn server(&self, action: &str) -> Command {
        let mut command = self.cmux();
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        command
    }

    /// `cmux --json raw operation <operation>`: the operation's result.
    fn operation(&self, operation: &str, params: Value, mutation: bool) -> Value {
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut command = self.cmux();
        command.args(["--json", "--socket"]).arg(&self.socket).args([
            "raw",
            "operation",
            operation,
            "--params-json",
            &params.to_string(),
        ]);
        if mutation {
            command.arg("--mutation");
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{operation} failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.server("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn an_owner_ensured_with_a_settings_file_names_it_in_the_snapshot_and_writes_it() {
    let fixture = Fixture::new();
    // Not the default place below the owner's HOME.
    let settings = fixture.dir.join("app").join("cmux-next.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, "{\n  \"tabs\": {\n    \"barPosition\": \"top\"\n  }\n}\n").unwrap();
    let ensured =
        fixture.server("ensure").env("CMUX_NEXT_CONFIG_FILE", &settings).output().unwrap();
    assert!(ensured.status.success(), "{}", String::from_utf8_lossy(&ensured.stderr));

    let snapshot = fixture.operation("settings.snapshot", json!({}), false);
    assert_eq!(snapshot["path"], json!(settings.to_str().unwrap()), "{snapshot}");
    assert_eq!(snapshot["file"]["tabs"]["barPosition"], "top", "{snapshot}");

    fixture.operation("settings.set", json!({"key": "tabs.barPosition", "value": "bottom"}), true);
    let text = fs::read_to_string(&settings).unwrap();
    assert!(text.contains("\"barPosition\": \"bottom\""), "the launch's file kept:\n{text}");
    let default = fixture.dir.join("home/.config/cmux/cmux-next.json");
    assert!(!default.exists(), "the owner made {}", default.display());

    // The next owner of this session keeps the file, though the client that
    // restarts it names none.
    let restarted = fixture.server("restart").output().unwrap();
    assert!(restarted.status.success(), "{}", String::from_utf8_lossy(&restarted.stderr));
    let snapshot = fixture.operation("settings.snapshot", json!({}), false);
    assert_eq!(snapshot["path"], json!(settings.to_str().unwrap()), "{snapshot}");
    assert_eq!(snapshot["file"]["tabs"]["barPosition"], "bottom", "{snapshot}");
    assert!(!default.exists(), "the restarted owner made {}", default.display());
}
