//! Customize by asking, agent and person taking turns, through the real
//! binary: the `customize_*` MCP tools on `cmux-tui mcp serve` and the
//! `cmux customize` CLI act on one set of generations, so what an agent
//! previews a person can apply, and what either applied either can roll back.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, ChildStdout, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn cmux(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("HOME", dir)
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .env("CMUX_NEXT_CONFIG_FILE", dir.join("cmux-next.json"))
        .env("XDG_RUNTIME_DIR", dir.join("rt"))
        .env("CMUX_TUI_SOCKET", dir.join("own.sock"))
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("CMUX_CUSTOMIZE_DIR")
        .env_remove("CMUX_CUSTOMIZE_STATE_DIR")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_AGENT_SESSION");
    command
}

struct Server {
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next: u64,
}

impl Server {
    /// One tool call: `(is an error, the structured answer or the whole result)`.
    fn call(&mut self, name: &str, arguments: Value) -> (bool, Value) {
        self.next += 1;
        let id = self.next;
        writeln!(
            self.stdin,
            "{}",
            json!({"jsonrpc": "2.0", "id": id, "method": "tools/call",
                   "params": {"name": name, "arguments": arguments}})
        )
        .unwrap();
        loop {
            let mut line = String::new();
            assert!(
                self.stdout.read_line(&mut line).unwrap() > 0,
                "the server closed before answering {name}"
            );
            let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
            if message["id"] == id {
                let result = message["result"].clone();
                let failed = result["isError"] == true;
                return (failed, if failed { result } else { result["structuredContent"].clone() });
            }
        }
    }

    fn ok(&mut self, name: &str, arguments: Value) -> Value {
        let (failed, answer) = self.call(name, arguments);
        assert!(!failed, "{name}: {answer}");
        answer
    }
}

#[test]
fn customize_mcp_and_cli_share_one_draft_and_one_history() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
    let dir = PathBuf::from(format!("/tmp/cmux-cz-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(dir.join("rt")).unwrap();
    std::fs::create_dir_all(dir.join("themes")).unwrap();
    std::fs::write(
        dir.join("cmux-next.json"),
        "{\n  \"mcp\": {\"enabled\": true},\n  \"browser\": {\"newTabPage\": \"https://alice:fixture-secret-937@example.com\"},\n  \"updates\": {\"channel\": \"nightly\"}\n}\n",
    )
    .unwrap();
    let theme = dir.join("themes/night.json");

    let mut child = cmux(&dir)
        .arg("--app-socket")
        .arg(dir.join("app.sock"))
        .args(["mcp", "serve"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut server = Server {
        stdin: child.stdin.take().unwrap(),
        stdout: BufReader::new(child.stdout.take().unwrap()),
        next: 0,
    };
    writeln!(
        server.stdin,
        "{}",
        json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "customize-tools", "version": "1"}}})
    )
    .unwrap();
    writeln!(server.stdin, "{}", json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        .unwrap();

    // The agent is asked, and gets the brief instead of a second agent.
    let asked = server.ok("customize_ask", json!({"wish": "a night theme"}));
    let brief = asked["brief"].as_str().unwrap_or_else(|| panic!("{asked}"));
    assert!(brief.contains("> a night theme"), "{brief}");
    assert!(brief.contains(&dir.join("themes").display().to_string()), "{brief}");
    assert_eq!(asked["status"]["previewing"], false);
    assert_eq!(asked["status"]["current"]["n"], 1);

    // Its first save is broken: the check says where, and apply is refused.
    std::fs::write(&theme, "{ \"name\": }\n").unwrap();
    let checked = server.ok("customize_check", json!({}));
    assert_eq!(checked["can_apply"], false, "{checked}");
    assert_eq!(checked["problems"][0]["path"], "themes/night.json", "{checked}");
    assert_eq!(checked["problems"][0]["line"], 1, "{checked}");
    let (refused, why) = server.call("customize_apply", json!({}));
    assert!(refused && why.to_string().contains("customize.invalid"), "{why}");

    // Fixed, it previews; the person looks from the CLI and applies it there.
    std::fs::write(&theme, "{ \"name\": \"night\" }\n").unwrap();
    let checked = server.ok("customize_check", json!({}));
    assert_eq!(checked["can_apply"], true, "{checked}");
    assert_eq!(checked["changes"][0]["by_hand"], false, "{checked}");
    let diff = server.ok("customize_diff", json!({}));
    assert_eq!(diff["files"][0]["path"], "themes/night.json", "{diff}");
    let status = cmux(&dir).args(["customize", "--json"]).output().unwrap();
    let status: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(status["previewing"], true, "{status}");
    assert_eq!(status["draft"]["asks"][0]["text"], "a night theme", "{status}");
    let applied = cmux(&dir).args(["--json", "customize", "apply"]).output().unwrap();
    assert!(applied.status.success(), "{}", String::from_utf8_lossy(&applied.stderr));
    let applied: Value = serde_json::from_slice(&applied.stdout).unwrap();
    assert_eq!(applied["generation"]["n"], 2, "{applied}");
    assert_eq!(applied["generation"]["label"], "a night theme", "{applied}");

    // The first generation is the whole setup. The agent reads it as the
    // settings tools would show it: no credential, and no setting that only
    // the person may read. The person's own terminal masks the credential too.
    let first = server.ok("customize_show", json!({"generation": 1}));
    let shown = first.to_string();
    assert_eq!(first["files"][0]["path"], "settings.json", "{first}");
    assert!(
        shown.contains("[redacted]@example.com") || shown.contains("\\\"[redacted]\\\""),
        "{shown}"
    );
    assert!(!shown.contains("fixture-secret-937") && !shown.contains("nightly"), "{shown}");
    let mine = cmux(&dir).args(["customize", "show", "1"]).output().unwrap();
    let mine = String::from_utf8_lossy(&mine.stdout).into_owned();
    assert!(mine.contains("nightly") && !mine.contains("fixture-secret-937"), "{mine}");

    // The person edits by hand; the agent is told so before it writes again.
    std::fs::write(&theme, "{ \"name\": \"midnight\" }\n").unwrap();
    let status = server.ok("customize_status", json!({}));
    assert_eq!(status["changes"][0]["by_hand"], true, "{status}");

    // The agent rolls back: the hand edit is kept by number, and the first
    // generation is live. The CLI goes forward again.
    let back = server.ok("customize_rollback", json!({"generation": 1}));
    assert_eq!(back["generation"]["n"], 1, "{back}");
    assert_eq!(back["kept_as"], 3, "{back}");
    assert!(!theme.exists());
    let history = server.ok("customize_generations", json!({}));
    assert_eq!(history["current"], 1, "{history}");
    assert_eq!(history["generations"].as_array().map(Vec::len), Some(3), "{history}");
    let forward = cmux(&dir).args(["customize", "rollback", "3"]).output().unwrap();
    let said = String::from_utf8_lossy(&forward.stdout).into_owned();
    assert!(
        forward.status.success() && said.starts_with("rolled back: generation 3 is live"),
        "{said}"
    );
    assert_eq!(std::fs::read_to_string(&theme).unwrap(), "{ \"name\": \"midnight\" }\n");

    // A profile the agent may not use is refused by the setting's name: the
    // value it carried is not in the answer.
    let leaky = dir.join("leaky-profile.json");
    std::fs::write(
        &leaky,
        "{\"cmuxProfile\":1,\"name\":\"x\",\"settings\":{\"appearance.density\":{\"token\":\"private-value\"}},\"files\":{}}\n",
    )
    .unwrap();
    let (failed, refused) = server.call("customize_use", json!({"profile": leaky}));
    let refused = refused.to_string();
    assert!(failed && refused.contains("appearance.density"), "{refused}");
    assert!(!refused.contains("private-value"), "{refused}");

    // A typo is a usage error with a suggestion, never an ask.
    let typo = cmux(&dir).args(["customize", "aply"]).output().unwrap();
    assert_eq!(typo.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&typo.stderr).contains("did you mean `apply`?"));

    drop(server);
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
}

/// `cmux customize use` of a look that brings its own New Tab page returns
/// only once the daemon has loaded the look's app: it asks for the pass its
/// folder watch would run (`apps-reload-local`, naming the views folder) and
/// waits for the answer. Before, it returned on the file write, and on a
/// loaded Mac the watch's event came seconds later: a New Tab page opened at
/// once found no `local/customize` and kept cmux's own page for its life.
/// The fake daemon here has no watch at all, so only the asked pass loads.
#[test]
fn customize_use_returns_with_the_looks_views_loaded() {
    use std::os::unix::net::UnixListener;
    use std::sync::{Arc, Mutex};

    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
    let dir = PathBuf::from(format!("/tmp/cmux-cv-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(dir.join("rt")).unwrap();
    std::fs::write(dir.join("cmux-next.json"), "{}\n").unwrap();
    // A look shaped like the demo's: its New Tab page is its own view.
    let app = json!({
        "manifestVersion": 2,
        "id": "local/customize",
        "name": "Look",
        "version": "1.0.0",
        "description": "A New Tab page of its own.",
        "engines": {"cmux": "^2.0"},
        "runtime": {"main": "main.js"},
        "implements": {"cmux.newtab/1": {"export": "renderHome", "title": "Look"}},
    });
    let look = dir.join("look.json");
    let profile = json!({
        "cmuxProfile": 1,
        "name": "look",
        "created_ms": 0,
        "settings": {"tabs.newTabApp": "local/customize"},
        "files": {
            "customize/cmux-app.json": serde_json::to_string_pretty(&app).unwrap(),
            "customize/main.js": "export function renderHome() { return null; }\n",
        },
    });
    std::fs::write(&look, profile.to_string()).unwrap();

    let paths = cmux(&dir).args(["customize", "paths", "--json"]).output().unwrap();
    let paths: Value = serde_json::from_slice(&paths.stdout).unwrap();
    let views = PathBuf::from(paths["views"].as_str().expect("the views folder"));

    // Each request, with whether the look's app was on disk when it came.
    let socket = dir.join("rt/daemon.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let seen: Arc<Mutex<Vec<(Value, bool)>>> = Arc::default();
    let (record, manifest) = (seen.clone(), views.join("cmux-app.json"));
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let mut writer = stream.try_clone().unwrap();
            for line in BufReader::new(stream).lines() {
                let Ok(line) = line else { break };
                let request: Value = serde_json::from_str(&line).unwrap();
                record.lock().unwrap().push((request.clone(), manifest.is_file()));
                let data = json!({"safeMode": false, "rejected": []});
                let reply = json!({"id": request["id"], "ok": true, "data": data});
                if writeln!(writer, "{reply}").is_err() {
                    break;
                }
            }
        }
    });

    let used = cmux(&dir)
        .arg("--socket")
        .arg(&socket)
        .args(["customize", "use"])
        .arg(&look)
        .output()
        .unwrap();
    assert!(used.status.success(), "{}", String::from_utf8_lossy(&used.stderr));
    let seen = seen.lock().unwrap().clone();
    let asked: Vec<_> = seen.iter().filter(|(r, _)| r["cmd"] == "apps-reload-local").collect();
    assert_eq!(asked.len(), 1, "one asked load before `use` returned: {seen:?}");
    let (request, written) = asked[0];
    assert_eq!(request["folders"], json!([views.display().to_string()]), "{request}");
    assert!(written, "the daemon was asked after the look's app was written");

    // With no daemon it is the file change it always was.
    let alone = cmux(&dir)
        .arg("--socket")
        .arg(dir.join("rt/none.sock"))
        .args(["customize", "discard"])
        .output()
        .unwrap();
    assert!(alone.status.success(), "{}", String::from_utf8_lossy(&alone.stderr));
    let _ = std::fs::remove_dir_all(&dir);
}
