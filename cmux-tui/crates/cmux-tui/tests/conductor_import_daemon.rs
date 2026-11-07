//! Import from Conductor (`conductor-import-v1`) on a real headless daemon
//! over its socket: the plan of a fixture `conductor.db` under the daemon's
//! HOME, the ledger the app records into, and a replayed record.
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

fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false"])
        .args(["-c", "init.defaultBranch=main"])
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

/// One repository and its Conductor worktree `lima` under `home`, and the
/// `conductor.db` that lists them.
fn conductor_home(home: &Path) {
    let repo = home.join("src/app");
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    fs::write(repo.join("README"), "app\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "init"]);
    let lima = home.join("conductor/workspaces/app/lima");
    fs::create_dir_all(lima.parent().unwrap()).unwrap();
    git(&repo, &["worktree", "add", "-q", "-b", "leo/lima", lima.to_str().unwrap()]);
    let db = home.join("Library/Application Support/com.conductor.app/conductor.db");
    fs::create_dir_all(db.parent().unwrap()).unwrap();
    rusqlite::Connection::open(&db)
        .unwrap()
        .execute_batch(&format!(
            "CREATE TABLE repos (id TEXT PRIMARY KEY, root_path TEXT, name TEXT, is_hidden INTEGER);
             CREATE TABLE workspaces (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, state TEXT,
                 path TEXT, archive_commit TEXT, directory_name TEXT);
             INSERT INTO repos VALUES ('r1', '{repo}', 'app', 0);
             INSERT INTO workspaces VALUES ('w-lima', 'r1', 'leo/lima', 'ready', '{lima}', NULL, 'lima');",
            repo = repo.display(),
            lima = lima.display(),
        ))
        .unwrap();
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-conductor-{name}-{}-{stamp}", std::process::id()));
        let home = dir.join("home");
        fs::create_dir_all(&home).unwrap();
        conductor_home(&home.canonicalize().unwrap());
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("HOME", home.canonicalize().unwrap())
            .env("CMUX_PROJECT_SOURCES", "off")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_DATA_HOME")
            .env_remove("CODEX_HOME")
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

    fn plan(&self) -> Value {
        self.send("conductor_import.plan", json!({}), None).unwrap()
    }

    fn record(&self, params: Value, key: &str) -> Value {
        self.send("conductor_import.record", params, Some(key))
            .unwrap_or_else(|error| panic!("conductor_import.record: {error}"))
    }

    /// A new workspace's public id.
    fn open_workspace(&self, name: &str) -> String {
        self.send(
            "workspace.create",
            json!({"name": name, "initial_content": "empty"}),
            Some(&format!("create-{name}")),
        )
        .unwrap();
        let list = self.send("workspace.list", json!({}), None).unwrap();
        list.as_array()
            .unwrap()
            .iter()
            .find(|workspace| workspace["name"] == name)
            .and_then(|workspace| workspace["id"].as_str())
            .unwrap_or_else(|| panic!("no workspace {name} in {list}"))
            .to_string()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn lima(plan: &Value) -> Value {
    plan["plan"]["projects"][0]["workspaces"]
        .as_array()
        .unwrap_or_else(|| panic!("no workspaces in {plan}"))
        .iter()
        .find(|workspace| workspace["id"] == "w-lima")
        .cloned()
        .unwrap_or_else(|| panic!("no w-lima in {plan}"))
}

#[test]
fn conductor_import_plans_records_and_replays_over_the_socket() {
    let daemon = Daemon::start("flow");

    let first = daemon.plan();
    assert!(first["found"]["database"].as_str().unwrap().ends_with("conductor.db"), "{first}");
    assert_eq!(lima(&first)["disposition"], json!({"kind": "adopt"}));

    let pending = daemon.record(json!({"workspace": "w-lima", "stage": "pending"}), "pending");
    assert_eq!(pending["replayed"], false);
    assert_eq!(pending["value"]["stage"], "pending");

    let made = daemon.open_workspace("lima");
    let done = json!({"workspace": "w-lima", "stage": "done", "cmux_workspace": made,
                      "run_completed": true});
    let recorded = daemon.record(done.clone(), "done");
    assert_eq!(recorded["value"]["runs"], 1);

    let after = daemon.plan();
    assert_eq!(
        lima(&after)["disposition"],
        json!({"kind": "already-imported", "cmux_workspace": made})
    );

    let replay = daemon.record(done, "done");
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"]["runs"], 1);

    let refused = daemon
        .send("conductor_import.record", json!({"workspace": "w-lima", "stage": "done"}), Some("x"))
        .unwrap_err();
    assert_eq!(refused["code"], "validation.invalid", "{refused}");
    // A caller never names the folder Conductor is read from.
    let refused = daemon.send("conductor_import.plan", json!({"home": "/elsewhere"}), None);
    assert_eq!(refused.unwrap_err()["code"], "validation.invalid");
}
