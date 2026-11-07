//! `cmux automation teleport` and `import` through the real binary
//! (docs/automations-teleport-teams.md, section 2): this Mac to cmux Cloud
//! through a fake cmux app (`cloud.automation`), Cloud back home, this Mac to
//! another machine through a fake `ssh`, the refusals that keep an automation
//! where it is, and the idempotent `import --json -`.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const CLOUD_ID: &str = "auto_cloudcloudcloudcloud";

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(label: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
        let dir = PathBuf::from(format!("/tmp/cmux-tp-{label}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("bin/cmux")).unwrap();
        // A fake ssh: drops its options, logs the host, runs the command here
        // against the "remote" store.
        let ssh = dir.join("bin/ssh");
        std::fs::write(
            &ssh,
            "#!/bin/sh\nwhile [ $# -gt 0 ]; do case \"$1\" in -o) shift 2;; --) shift; break;; -*) shift;; *) break;; esac; done\nprintf '%s\\n' \"$1\" >> \"$SSH_LOG\"\nshift\nCMUX_AUTOMATIONS_DIR=\"$REMOTE_STORE\" exec /bin/sh -c \"$*\"\n",
        )
        .unwrap();
        std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o755)).unwrap();
        Self { dir }
    }

    fn socket(&self) -> PathBuf {
        self.dir.join("app.sock")
    }

    fn command(&self, store: &str, args: &[&str]) -> Command {
        let mut c = Command::new(self.dir.join("bin/cmux"));
        c.arg("--app-socket")
            .arg(self.socket())
            .args(args)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("HOME", &self.dir)
            .env("TZ", "America/Los_Angeles")
            .env("PATH", format!("{}:/usr/bin:/bin", self.dir.join("bin").display()))
            .env("CMUX_AUTOMATIONS_DIR", self.dir.join(store))
            .env("REMOTE_STORE", self.dir.join("remote"))
            .env("SSH_LOG", self.dir.join("ssh.log"))
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG");
        c
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command("store", args).output().unwrap()
    }

    fn json_in(&self, store: &str, args: &[&str]) -> Value {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        let out = self.command(store, &all).output().unwrap();
        assert!(out.status.success(), "cmux {args:?}: {}{}", text(&out.stdout), text(&out.stderr));
        serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
            panic!("cmux {args:?} printed no JSON ({e}): {}", text(&out.stdout))
        })
    }

    fn json(&self, args: &[&str]) -> Value {
        self.json_in("store", args)
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

fn is_handoff_id(id: &str) -> bool {
    id.len() == 35
        && id.strip_prefix("tp_").is_some_and(|hex| {
            hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

/// A fake cmux app. `automation.import` refuses an automation named
/// "Refused" with the plan refusal; everything else is accepted.
fn answer(request: &Value) -> Value {
    if request["method"] != "cloud.automation" {
        return json!({"id": request["id"], "ok": true, "result": {"pong": true}});
    }
    let p = &request["params"];
    let params = &p["params"];
    let value = match p["op"].as_str().unwrap_or("") {
        "chief.list" => json!({"ok": true, "value": {"chiefs": [
            {"id": "agent_A", "is_default": true, "archived_at": null, "main_conversation": "conv_main"}
        ]}}),
        "automation.import" if params["name"] == "Refused" => {
            json!({"ok": false, "error": {"code": "automation.plan.required", "message": "the free plan has 1 Cloud job",
                   "details": {"checkout": "https://api.test/v1/billing/plan/abc"}}})
        }
        "automation.import" => json!({"ok": true, "value": {
            "id": CLOUD_ID, "name": params["name"], "enabled": true, "home": "cloud",
            "epoch": params["handoff"]["epoch"], "triggers": params["triggers"]}}),
        "automation.list" => json!({"ok": true, "value": {"automations": [
            {"id": CLOUD_ID, "name": "Cloud brief", "enabled": true, "home": "cloud", "epoch": 2}
        ]}}),
        "automation.get" => json!({"ok": true, "value": {"automation": {
            "id": CLOUD_ID, "name": "Cloud brief", "enabled": true, "home": "cloud", "epoch": 2, "handoff": null}}}),
        "automation.teleport.begin" => json!({"ok": true, "value": {
            "automation": {"id": CLOUD_ID, "name": "Cloud brief", "enabled": true, "home": "cloud", "epoch": 2,
                "triggers": [{"spec": {"type": "cron", "expr": "0 9 * * *", "tz": "America/Los_Angeles"}}, {"spec": {"type": "manual"}}],
                "body": {"type": "chief", "chief": "agent_A", "conversation": "conv_main", "prompt": "Summarize PRs"},
                "catch_up": "latest"},
            "epoch": 3, "last_slot": 1_793_350_800_000_i64}}),
        "automation.teleport.complete" => json!({"ok": true, "value": {
            "id": CLOUD_ID, "name": "Cloud brief", "moved_to": "home", "moved_id": params["moved_id"], "epoch": 3}}),
        "automation.teleport.abort" => json!({"ok": true, "value": {"id": CLOUD_ID}}),
        "automation.create" => {
            json!({"ok": true, "value": {"id": "auto_madecloudmadecloudma", "name": params["name"], "enabled": true}})
        }
        "automation.update" => {
            json!({"ok": true, "value": {"id": CLOUD_ID, "name": "Cloud brief", "enabled": true}})
        }
        "automation.audit.list" => json!({"ok": true, "value": {"entries": [
            {"n": 1, "at": 1_793_350_800_000_i64, "actor": "user_a", "op": "create", "automation": CLOUD_ID, "summary": "created Cloud brief"}
        ]}}),
        other => {
            json!({"ok": false, "error": {"code": "automation.op_not_allowed", "message": other}})
        }
    };
    json!({"id": request["id"], "ok": true, "result": value})
}

struct FakeApp {
    done: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
    received: Arc<Mutex<Vec<Value>>>,
}

impl FakeApp {
    fn start(socket: &Path) -> FakeApp {
        let listener = UnixListener::bind(socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let received = Arc::new(Mutex::new(Vec::<Value>::new()));
        let done = Arc::new(AtomicBool::new(false));
        let (seen, stop) = (received.clone(), done.clone());
        let handle = std::thread::spawn(move || {
            loop {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                        let mut reader = BufReader::new(stream.try_clone().unwrap());
                        let mut writer = stream;
                        let mut line = String::new();
                        while reader.read_line(&mut line).unwrap_or(0) > 0 {
                            let request: Value = serde_json::from_str(&line).unwrap();
                            line.clear();
                            let response = answer(&request);
                            seen.lock().unwrap().push(request);
                            if writeln!(writer, "{response}").is_err() {
                                break;
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(e) => panic!("accept: {e}"),
                }
            }
        });
        FakeApp { done, handle: Some(handle), received }
    }

    /// The `cloud.automation` ops so far: `{op, params, idempotency_key}`.
    fn ops(&self) -> Vec<Value> {
        self.received
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r["method"] == "cloud.automation")
            .map(|r| r["params"].clone())
            .collect()
    }

    fn op(&self, name: &str) -> Vec<Value> {
        self.ops().into_iter().filter(|p| p["op"] == name).collect()
    }
}

impl Drop for FakeApp {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

#[test]
fn teleport_this_mac_to_cloud_fences_imports_and_leaves_a_tombstone() {
    let env = Env::new("cloud");
    let app = FakeApp::start(&env.socket());
    let made = env.json(&[
        "automation",
        "create",
        "Morning brief",
        "--prompt",
        "Summarize merged PRs",
        "--weekdays",
        "09:00",
        "--catch-up",
        "all",
    ]);
    let local_id = made["id"].as_str().unwrap().to_string();
    assert_eq!(made["epoch"], 1);
    assert!(made["home"].as_str().unwrap().starts_with("mac:"), "{made}");

    let moved = env.json(&["automation", "teleport", "Morning brief", "--to", "cloud"]);
    assert_eq!(moved["moved_to"], "cloud", "{moved}");
    assert_eq!(moved["moved_id"], CLOUD_ID, "{moved}");

    let imports = app.op("automation.import");
    assert_eq!(imports.len(), 1, "{imports:?}");
    let import = &imports[0];
    let p = &import["params"];
    assert_eq!(p["name"], "Morning brief");
    assert_eq!(
        p["triggers"],
        json!([{"type": "cron", "expr": "0 9 * * 1-5", "tz": "America/Los_Angeles"}, {"type": "manual"}])
    );
    assert_eq!(
        p["body"],
        json!({"type": "chief", "chief": "agent_A", "conversation": "conv_main", "prompt": "Summarize merged PRs"})
    );
    assert_eq!(p["catch_up"], "all");
    let handoff = &p["handoff"];
    let id = handoff["id"].as_str().unwrap();
    assert!(is_handoff_id(id), "{handoff}");
    assert!(handoff["from"].as_str().unwrap().starts_with("mac:"), "{handoff}");
    assert_eq!(handoff["source_id"], local_id);
    assert_eq!(handoff["epoch"], 2);
    assert_eq!(handoff["last_slot"], Value::Null);
    assert_eq!(import["idempotency_key"], format!("teleport:{id}"));

    let list = env.json(&["automation", "list"]);
    assert_eq!(list["automations"], json!([]), "{list}");
    let tomb = &list["moved"][0];
    assert_eq!(tomb["id"], local_id.as_str());
    assert_eq!(tomb["name"], "Morning brief");
    assert_eq!(tomb["moved_to"], "cloud");
    assert_eq!(tomb["moved_id"], CLOUD_ID);
    assert_eq!(tomb["epoch"], 2);
    assert!(tomb["moved_at"].as_i64().is_some_and(|ms| ms > 1_700_000_000_000), "{tomb}");
    let human = env.run(&["automation", "list"]);
    assert!(text(&human.stdout).contains("moved to cloud"), "{}", text(&human.stdout));

    // Re-running finds the tombstone and sends nothing more.
    let again = env.run(&["automation", "teleport", "Morning brief", "--to", "cloud"]);
    assert!(again.status.success(), "{}", text(&again.stderr));
    assert_eq!(app.op("automation.import").len(), 1);
}

#[test]
fn teleport_refusals_keep_the_automation_here_and_firing() {
    let env = Env::new("refuse");
    let app = FakeApp::start(&env.socket());
    env.json(&["automation", "create", "Shell job", "--command", "make", "--daily", "09:00"]);
    env.json(&["automation", "create", "Odd", "--prompt", "x", "--every", "7m"]);
    env.json(&["automation", "create", "Refused", "--prompt", "x", "--daily", "08:00"]);

    let shell = env.run(&["automation", "teleport", "Shell job", "--to", "cloud"]);
    assert_eq!(shell.status.code(), Some(2), "{}", text(&shell.stderr));
    assert!(
        text(&shell.stderr).contains("a shell command needs a machine: teleport it to ssh:HOST"),
        "{}",
        text(&shell.stderr)
    );
    let odd = env.run(&["automation", "teleport", "Odd", "--to", "cloud"]);
    assert_eq!(odd.status.code(), Some(2), "{}", text(&odd.stderr));
    let bad = env.run(&["automation", "teleport", "Odd", "--to", "mars"]);
    assert_eq!(bad.status.code(), Some(2), "{}", text(&bad.stderr));
    let home = env.run(&["automation", "teleport", "Odd", "--to", "home"]);
    assert_eq!(home.status.code(), Some(2), "already on this Mac: {}", text(&home.stderr));
    assert!(app.op("automation.import").is_empty(), "nothing is sent for a refused move");

    // The destination refuses: the fence is cleared and it stays here.
    let refused = env.run(&["automation", "teleport", "Refused", "--to", "cloud"]);
    assert_eq!(refused.status.code(), Some(4), "{}", text(&refused.stderr));
    assert_eq!(app.op("automation.import").len(), 1);
    let list = env.json(&["automation", "list"]);
    let all = list["automations"].as_array().unwrap();
    assert_eq!(all.len(), 3, "{list}");
    assert!(all.iter().all(|a| a["handoff"].is_null()), "no fence is left: {list}");
}

#[test]
fn teleport_cloud_to_home_begins_imports_here_and_completes() {
    let env = Env::new("home");
    let app = FakeApp::start(&env.socket());
    let out = env.json(&["automation", "teleport", "Cloud brief", "--to", "home"]);
    let begin = app.op("automation.teleport.begin");
    assert_eq!(begin.len(), 1, "{:?}", app.ops());
    let id = begin[0]["params"]["handoff"]["id"].as_str().unwrap().to_string();
    assert!(is_handoff_id(&id));
    assert_eq!(begin[0]["params"]["automation"], CLOUD_ID);
    assert_eq!(begin[0]["params"]["handoff"]["to"], "home");
    assert_eq!(begin[0]["idempotency_key"], format!("teleport-begin:{id}"));

    let list = env.json(&["automation", "list"]);
    let here = &list["automations"][0];
    assert_eq!(here["name"], "Cloud brief", "{list}");
    assert_eq!(here["epoch"], 3);
    assert_eq!(here["last_slot"], 1_793_350_800_000_i64);
    assert!(here["home"].as_str().unwrap().starts_with("mac:"));
    assert_eq!(here["trigger"], json!({"type": "cron", "expr": "0 9 * * *", "tz": "local"}));
    assert_eq!(here["body"]["type"], "prompt");
    assert_eq!(here["body"]["prompt"], "Summarize PRs");

    let complete = app.op("automation.teleport.complete");
    assert_eq!(complete.len(), 1);
    assert_eq!(
        complete[0]["params"],
        json!({"automation": CLOUD_ID, "handoff": id, "moved_id": here["id"]})
    );
    assert_eq!(complete[0]["idempotency_key"], format!("teleport-complete:{id}"));
    assert_eq!(out["moved_id"], here["id"], "{out}");
}

#[test]
fn teleport_this_mac_to_ssh_imports_on_the_host_and_tombstones() {
    let env = Env::new("ssh");
    let made = env.json(&["automation", "create", "Build", "--command", "make", "--every", "30m"]);
    let moved = env.json(&["automation", "teleport", "Build", "--to", "ssh:mini:/srv/work"]);
    assert_eq!(moved["moved_to"], "ssh:mini:/srv/work", "{moved}");
    let log = std::fs::read_to_string(env.dir.join("ssh.log")).unwrap();
    assert_eq!(log.trim(), "mini");

    let remote = env.json_in("remote", &["automation", "list"]);
    let there = &remote["automations"][0];
    assert_eq!(there["name"], "Build", "{remote}");
    assert_eq!(there["id"], moved["moved_id"]);
    assert_eq!(there["epoch"], 2);
    assert_eq!(there["body"], json!({"type": "command", "command": "make", "folder": "/srv/work"}));
    assert_eq!(there["trigger"]["type"], "every");
    assert_eq!(there["trigger"]["seconds"], 1_800);
    assert_eq!(there["trigger"]["anchor"], made["trigger"]["anchor"]);

    let here = env.json(&["automation", "list"]);
    assert_eq!(here["automations"], json!([]));
    assert_eq!(here["moved"][0]["moved_to"], "ssh:mini:/srv/work");
}

#[test]
fn teleport_import_from_stdin_is_idempotent_by_handoff_id() {
    let env = Env::new("import");
    let spec = json!({
        "name": "Arrived", "enabled": true, "catch_up": "latest",
        "triggers": [{"type": "cron", "expr": "30 8 * * *", "tz": "UTC"}],
        "body": {"type": "prompt", "prompt": "Check the queue"},
        "handoff": {"id": "tp_0123456789abcdef0123456789abcdef", "from": "mac:machine_other",
                    "source_id": "auto_sourcesourcesourceso", "epoch": 4, "last_slot": 1_793_350_800_000_i64}
    });
    let import = |env: &Env| -> Value {
        let mut child = env
            .command("store", &["automation", "import", "--json", "-"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(spec.to_string().as_bytes()).unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "{}{}", text(&out.stdout), text(&out.stderr));
        serde_json::from_slice(&out.stdout).unwrap()
    };
    let first = import(&env);
    let second = import(&env);
    assert_eq!(first["id"], second["id"]);
    assert_eq!(first["epoch"], 4);
    assert_eq!(first["last_slot"], 1_793_350_800_000_i64);
    assert_eq!(second["replayed"], true);
    let list = env.json(&["automation", "list"]);
    assert_eq!(list["automations"].as_array().unwrap().len(), 1, "{list}");
}

#[test]
fn teleport_slice_cloud_audit_and_team_fields() {
    let env = Env::new("audit");
    let app = FakeApp::start(&env.socket());
    let one = env.json(&["automation", "audit", "Cloud brief", "--target", "cloud"]);
    assert_eq!(one["entries"][0]["op"], "create", "{one}");
    let all = env.run(&["automation", "audit", "--target", "cloud"]);
    assert!(all.status.success(), "{}", text(&all.stderr));
    assert!(text(&all.stdout).contains("created Cloud brief"), "{}", text(&all.stdout));
    let audits = app.op("automation.audit.list");
    assert_eq!(audits.len(), 2, "{audits:?}");
    assert_eq!(audits[0]["params"]["automation"], CLOUD_ID);
    assert!(audits[1]["params"].get("automation").is_none(), "{}", audits[1]);
    assert!(audits.iter().all(|a| a.get("idempotency_key").is_none()), "a read has no key");

    env.json(&[
        "automation",
        "create",
        "Team job",
        "--target",
        "cloud",
        "--prompt",
        "x",
        "--daily",
        "9:00",
        "--private",
        "--editor",
        "user_a",
        "--editor",
        "user_b",
        "--catch-up",
        "none",
    ]);
    let create = &app.op("automation.create")[0]["params"];
    assert_eq!(create["sharing"], "private", "{create}");
    assert_eq!(create["editors"], json!(["user_a", "user_b"]));
    assert_eq!(create["catch_up"], "none");

    env.json(&[
        "automation",
        "edit",
        "Cloud brief",
        "--target",
        "cloud",
        "--catch-up",
        "all",
        "--shared",
    ]);
    let update = &app.op("automation.update")[0];
    assert_eq!(
        update["params"],
        json!({"automation": CLOUD_ID, "catch_up": "all", "sharing": "team"})
    );
    assert!(update["idempotency_key"].as_str().is_some());
}
