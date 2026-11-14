//! `cmux <cli.name> <path…>` runs an installed app's op through a real
//! daemon (plans/cmux-next/app-commands-codemode.md section 1): the daemon
//! resolves the manifest `cli.name` and the op's `cli.path` (`apps-cli`),
//! the CLI builds the arguments from the op's input schema and runs it with
//! `apps-run`. The app host is a script that answers each run with the run
//! frame it got, so the test sees the export and arguments the op ran with.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};

const KEY_HEX: &str = "8f0e1d2c3b4a59687766554433221100ffeeddccbbaa99887766554433221100";
const INSTALL_ID: &str = "inst_app_commands";

/// The app host: ready on init; a run answers `{ran: <the run frame>}`.
const HOST: &str = r#"#!/bin/sh
while IFS= read -r line <&3; do
  case "$line" in
    *'"t":"init"'*) printf '{"t":"ready","runtime":"probe"}\n' >&3 ;;
    *'"t":"run"'*)
      cb=$(printf '%s' "$line" | sed 's/.*"cb":\([0-9]*\).*/\1/')
      printf '{"t":"done","cb":%s,"ok":true,"body":{"ran":%s}}\n' "$cb" "$line" >&3 ;;
  esac
done
"#;

/// One daemon with its own state, app folder and scripted app host.
struct Daemon {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Daemon {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-ac-{name}-{}-{stamp}", std::process::id()));
        for sub in ["state", "first-party", "bundled", "servers"] {
            std::fs::create_dir_all(dir.join(sub)).unwrap();
        }
        let host = dir.join("app-host");
        std::fs::write(&host, HOST).unwrap();
        std::fs::set_permissions(&host, std::fs::Permissions::from_mode(0o755)).unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("ac-{name}"), dir }
    }

    fn server(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_APP_HOST_BIN", self.dir.join("app-host"))
            .env("CMUX_APP_SERVER_DIR", self.dir.join("servers"))
            .env("CMUX_APPS_FIRST_PARTY_DIR", self.dir.join("first-party"))
            .env("CMUX_APPS_DIRS", self.dir.join("bundled"))
            .env("CMUX_CUSTOMIZE_DIR", self.dir.join("customize"))
            .env_remove("XDG_RUNTIME_DIR");
        command
    }

    /// Starts the daemon with the app's install key, so a connection can
    /// prove itself the verified cmux app (an install needs it).
    fn start(&self) {
        let mut child = self
            .server("ensure")
            .arg("--install-key-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL_ID} {KEY_HEX}\n");
        child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success(), "ensure failed: {output:?}");
    }

    /// Installs `app` as the person does: the verified app, origin user.
    fn install(&self, app: &str) {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        let mut reader = BufReader::new(stream);
        let mut next = 0;
        let mut rpc = |mut request: Value| -> Value {
            next += 1;
            request["id"] = json!(next);
            writeln!(reader.get_mut(), "{request}").unwrap();
            loop {
                let mut line = String::new();
                assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == json!(next) {
                    return reply;
                }
            }
        };
        let challenge =
            rpc(json!({ "cmd": "client-hello", "role": "main", "install_id": INSTALL_ID }));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL_ID, &nonce);
        let proved =
            rpc(json!({ "cmd": "client-hello", "install_id": INSTALL_ID, "proof": proof }));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        let reply = rpc(json!({ "cmd": "apps-store", "op": "cmux.apps.install", "origin": "user",
            "args": { "app": app, "idempotency_key": format!("install-{app}") } }));
        assert_eq!(reply["data"]["app"]["state"]["installed"], true, "{reply}");
    }

    /// `cmux --socket <this daemon> WORDS`.
    fn cmux(&self, words: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--socket")
            .arg(&self.socket)
            .args(words)
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env("LANG", "en_US.UTF-8")
            .output()
            .unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Writes the app `acme/demo`, called `demo`, into `root`: the op
/// `acme.demo.ping` at `cmux demo ping` and `acme.demo.start` at
/// `cmux demo session start`.
fn write_demo(root: &Path) {
    let app = root.join("demo");
    std::fs::create_dir_all(app.join("dist")).unwrap();
    std::fs::write(app.join("dist/main.js"), "var __cmuxAppExports = {};\n").unwrap();
    let op = |verb: &str, path: &str| {
        json!({
            "name": format!("acme.demo.{verb}"), "owner": "app:acme/demo", "class": "read",
            "risk": "read", "idempotency": "forbidden", "docs": format!("{verb} the demo"),
            "since": "demo/1", "export": verb,
            "input": { "type": "object", "properties": {
                "text": { "type": "string" }, "loud": { "type": "boolean" }, "count": { "type": "integer" }
            } },
            "cli": { "path": path, "positional": ["text"] },
        })
    };
    let catalog = json!({ "family": "acme.demo", "operations": [op("ping", "ping"), op("start", "session start")] });
    std::fs::write(app.join("catalog.json"), catalog.to_string()).unwrap();
    let manifest = json!({
        "manifestVersion": 2, "id": "acme/demo", "name": "Demo", "version": "1.0.0",
        "description": "d", "engines": { "cmux": "^2.0" },
        "repository": "https://github.com/acme/demo",
        "runtime": { "main": "dist/main.js" }, "catalog": "catalog.json",
        "files": ["dist/", "catalog.json"], "cli": { "name": "demo" },
    });
    std::fs::write(app.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
}

/// The op's run frame from a run's printed result.
fn ran(output: &Output) -> Value {
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{output:?}");
    let data: Value = serde_json::from_str(stdout.trim()).unwrap_or_else(|_| panic!("{stdout}"));
    data["ran"].clone()
}

#[test]
fn an_apps_cli_name_runs_its_op_with_arguments_from_the_words() {
    let daemon = Daemon::new("run");
    write_demo(&daemon.dir.join("bundled"));
    daemon.start();
    daemon.install("acme/demo");

    let ping = ran(&daemon.cmux(&["demo", "ping", "hello", "--loud", "--count", "3"]));
    assert_eq!(ping["export"], "ping", "{ping}");
    assert_eq!(ping["args"], json!({ "text": "hello", "loud": true, "count": 3 }), "{ping}");
    let start = ran(&daemon.cmux(&["demo", "session", "start"]));
    assert_eq!((start["export"].clone(), start["args"].clone()), (json!("start"), json!({})));

    // `cmux demo` lists the app's commands; a wrong word points at that list.
    let help = daemon.cmux(&["demo"]);
    let text = String::from_utf8_lossy(&help.stdout);
    assert!(help.status.success() && text.contains("cmux demo session start"), "{help:?}");
    let wrong = daemon.cmux(&["demo", "pong"]);
    let stderr = String::from_utf8_lossy(&wrong.stderr);
    assert_eq!(wrong.status.code(), Some(2), "{wrong:?}");
    assert!(stderr.contains("`cmux demo`"), "{stderr}");
    let bad = daemon.cmux(&["demo", "ping", "--count", "many"]);
    assert_eq!(bad.status.code(), Some(2), "{bad:?}");

    // A word no app took is still the usage error.
    let unknown = daemon.cmux(&["nosuchapp", "ping"]);
    assert_eq!(unknown.status.code(), Some(2), "{unknown:?}");
}
