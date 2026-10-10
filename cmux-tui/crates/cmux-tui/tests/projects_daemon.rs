//! The device project list (`project-list-v1`, plans/cmux-next/projects.md)
//! on a real headless daemon over its socket: a source's report, the user's
//! overlay, refusals, hiding on remove, replay, and the app's disk facts.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-projects-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("home")).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            // The editor sources read under HOME: an empty one has none.
            .env("HOME", dir.join("home"))
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_DATA_HOME")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
            .ok()
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(1)
            .clamp(1, 16);
        let deadline = Instant::now() + Duration::from_secs(15) * scale;
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    /// One `cmux.protocol/2` request; the reply's `result`, or its `error`.
    fn send(&self, operation: &str, mut params: Value, key: Option<&str>) -> Result<Value, Value> {
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "1",
                                 "operation": operation, "params": params});
        if let Some(key) = key {
            request["idempotency_key"] = json!(key);
        }
        let stream = transport::connect(&self.socket).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(writer, "{request}").unwrap();
        let mut line = String::new();
        loop {
            line.clear();
            assert!(reader.read_line(&mut line).unwrap() > 0, "{operation}: connection closed");
            let reply: Value = serde_json::from_str(line.trim()).unwrap();
            if reply["id"] == "1" {
                return if reply["ok"] == true {
                    Ok(reply["result"].clone())
                } else {
                    Err(reply["error"].clone())
                };
            }
        }
    }

    fn mutate(&self, operation: &str, params: Value, key: &str) -> Value {
        self.send(operation, params, Some(key))
            .unwrap_or_else(|error| panic!("{operation}: {error}"))
    }

    fn list(&self, params: Value) -> Vec<Value> {
        let list = self.send("project.list", params, None).unwrap();
        list["projects"].as_array().cloned().unwrap_or_default()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn find<'a>(projects: &'a [Value], path: &str) -> &'a Value {
    projects
        .iter()
        .find(|project| project["path"] == path)
        .unwrap_or_else(|| panic!("{path} not listed"))
}

#[test]
fn projects_daemon_observe_edit_remove_and_sync_over_the_socket() {
    let daemon = Daemon::start("list");
    let app = "/srv/cx-m0p7-fixture/app";
    let observe = json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "50"}], "complete": true});
    let observed = daemon.mutate("project.observe", observe.clone(), "p-1");
    assert_eq!(observed["value"]["changed"], json!([app]), "{observed}");
    assert_eq!(
        daemon.mutate("project.observe", observe, "p-1")["replayed"],
        true,
        "same key replays"
    );

    let projects = daemon.list(json!({}));
    let project = find(&projects, app);
    assert_eq!(project["name"], "app");
    assert_eq!(project["last_used_ms"], "50", "wire times are decimal strings");
    assert_eq!(project["sources"]["codex"]["last_used_ms"], "50");
    assert_eq!(project["state"], "present");

    // The user's rename and pin survive the source's next report.
    daemon.mutate(
        "project.update",
        json!({"path": app, "rename": "The App", "pinned": true}),
        "p-2",
    );
    daemon.mutate(
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "90"}]}),
        "p-3",
    );
    let picked = daemon.dir.join("picked");
    fs::create_dir_all(&picked).unwrap();
    let picked = picked.canonicalize().unwrap().to_string_lossy().into_owned();
    daemon.mutate("project.add", json!({"path": picked}), "p-4");
    let projects = daemon.list(json!({}));
    assert_eq!(projects.len(), 2, "{projects:?}");
    assert_eq!(projects[0]["name"], "The App", "pinned first");
    assert_eq!(find(&projects, app)["last_used_ms"], "90");
    assert_eq!(daemon.list(json!({"query": "the app"})).len(), 1);

    // JSON null clears the rename.
    daemon.mutate("project.update", json!({"path": app, "rename": null}), "p-5");
    assert_eq!(find(&daemon.list(json!({})), app)["name"], "app");

    // The home folder and the root are never projects; an unknown path is refused.
    let refused = daemon.send("project.add", json!({"path": "/"}), Some("p-6")).unwrap_err();
    assert_eq!(refused["code"], "validation.invalid", "{refused}");
    let home = daemon.dir.join("home").canonicalize().unwrap().to_string_lossy().into_owned();
    let skipped = daemon.mutate(
        "project.observe",
        json!({"source": "claude", "entries": [{"path": home, "last_used_ms": "1"}, {"path": "/", "last_used_ms": "1"}]}),
        "p-7",
    );
    assert_eq!(skipped["value"]["changed"], json!([]), "refused paths are skipped: {skipped}");
    let unknown =
        daemon.send("project.update", json!({"path": "/srv/none", "pinned": true}), Some("p-8"));
    assert_eq!(unknown.unwrap_err()["code"], "validation.invalid");

    // Removed while a source still reports it: hidden, and a resync keeps it hidden.
    daemon.mutate("project.remove", json!({"path": app}), "p-9");
    daemon.mutate(
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "99"}], "complete": true}),
        "p-10",
    );
    assert_eq!(daemon.list(json!({})).len(), 1);
    let all = daemon.list(json!({"include_hidden": true}));
    assert_eq!(all.len(), 2);
    assert_eq!(find(&all, app)["overlay"]["hidden"], true);

    // The app found both gone: the reported one stays present, the user's own goes missing.
    daemon.mutate("project.sync", json!({"existing": [], "gone": [app, picked]}), "p-11");
    let all = daemon.list(json!({"include_hidden": true}));
    assert_eq!(find(&all, app)["state"], "present");
    assert_eq!(find(&all, &picked)["state"], "missing");

    // Removing the user's own folder deletes it. A source that no longer
    // lists a path leaves it, and the user's edits keep the project.
    daemon.mutate("project.remove", json!({"path": picked}), "p-12");
    daemon.mutate(
        "project.observe",
        json!({"source": "codex", "entries": [], "complete": true}),
        "p-13",
    );
    let left = daemon.list(json!({"include_hidden": true}));
    assert!(left.iter().all(|project| project["path"] != picked), "{left:?}");
    assert_eq!(find(&left, app)["sources"], json!({}), "{left:?}");
}
