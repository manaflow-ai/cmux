//! An `external` app server end to end (cmux-tui-core apps/server_external.rs):
//! the Hello Python sample (`samples/apps/hello-python`), a Python process the
//! person starts, answers `cmux apps run` once the person approved the app at
//! install and approved its credential in the cmux app; without that
//! credential it is refused.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_tui_core::server::frontend_proof::{NONCE_LEN, hello_proof, unhex};
use serde_json::{Value, json};

const KEY_HEX: &str = "7a6b5c4d3e2f10010203040506070809a0b1c2d3e4f5061728394a5b6c7d8e9f";
const INSTALL_ID: &str = "inst_external_server";
const APP: &str = "manaflow-ai/hello-python";

fn sample() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../samples/apps/hello-python")
}

struct Daemon {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    servers: Vec<Child>,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-xs-{name}-{}-{stamp}", std::process::id()));
        for sub in ["state", "first-party", "bundled/hello-python/catalog", "servers"] {
            std::fs::create_dir_all(dir.join(sub)).unwrap();
        }
        // The sample as the store ships it: its manifest, catalog and script.
        for file in ["cmux-app.v2.json", "catalog/hello-python-catalog.json", "server.py"] {
            std::fs::copy(sample().join(file), dir.join("bundled/hello-python").join(file))
                .unwrap();
        }
        // An app host that only says ready: the sample has no script to run.
        let host = "#!/bin/sh\nwhile IFS= read -r line <&3; do\n  case \"$line\" in\n    *'\"t\":\"init\"'*) printf '{\"t\":\"ready\",\"runtime\":\"probe\"}\\n' >&3 ;;\n  esac\ndone\n";
        let path = dir.join("app-host");
        std::fs::write(&path, host).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        let daemon = Self {
            socket: dir.join("mux.sock"),
            session: format!("xs-{name}"),
            dir,
            servers: Vec::new(),
        };
        let mut child = daemon
            .command("ensure")
            .arg("--install-key-stdin")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let key = format!("cmuxik1 {INSTALL_ID} {KEY_HEX}\n");
        child.stdin.take().unwrap().write_all(key.as_bytes()).unwrap();
        let output: Output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "ensure failed: {:?}\nstdout: {}\nstderr: {}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        daemon
    }

    fn env(&self, command: &mut Command) {
        command
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_APP_HOST_BIN", self.dir.join("app-host"))
            .env("CMUX_APP_SERVER_DIR", self.dir.join("servers"))
            .env("CMUX_APPS_FIRST_PARTY_DIR", self.dir.join("first-party"))
            .env("CMUX_APPS_DIRS", self.dir.join("bundled"))
            .env("CMUX_CUSTOMIZE_DIR", self.dir.join("customize"))
            .env_remove("XDG_RUNTIME_DIR");
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        self.env(&mut command);
        command
    }

    /// `cmux apps run APP OP [--args JSON]`, the CLI as a person or agent types it.
    fn apps_run(&self, op: &str, args: Value) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command.arg("--socket").arg(&self.socket).args([
            "apps",
            "run",
            APP,
            op,
            "--args",
            &args.to_string(),
        ]);
        self.env(&mut command);
        command.output().unwrap()
    }

    /// The verified cmux app's connection (install-key hello): origin user.
    fn app(&self) -> Client {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        let mut client = Client { reader: BufReader::new(stream), next: 100 };
        let challenge =
            client.rpc(json!({ "cmd": "client-hello", "role": "main", "install_id": INSTALL_ID }));
        let nonce = unhex::<NONCE_LEN>(challenge["data"]["nonce"].as_str().unwrap()).unwrap();
        let proof = hello_proof(&unhex::<32>(KEY_HEX).unwrap(), INSTALL_ID, &nonce);
        let proved =
            client.rpc(json!({ "cmd": "client-hello", "install_id": INSTALL_ID, "proof": proof }));
        assert_eq!(proved["data"]["verified"], true, "{proved}");
        client
    }

    /// Starts the sample's Python server with `credential`; stderr is piped.
    fn python_server(&mut self, credential: &str) -> usize {
        let child = Command::new("python3")
            .arg("-I")
            .arg(self.dir.join("bundled/hello-python/server.py"))
            .arg("--socket")
            .arg(&self.socket)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("CMUX_APP_CREDENTIAL", credential)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("python3 runs the sample server");
        self.servers.push(child);
        self.servers.len() - 1
    }

    /// The first stderr line of server `n`.
    fn server_says(&mut self, n: usize) -> String {
        let stderr = self.servers[n].stderr.as_mut().unwrap();
        let mut line = String::new();
        BufReader::new(stderr).read_line(&mut line).unwrap();
        line
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        for child in &mut self.servers {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = self.command("stop").arg("--end-terminals").output();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct Client {
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    fn rpc(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.reader.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.reader.read_line(&mut line).unwrap(), 0, "the daemon closed");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == json!(self.next) {
                return reply;
            }
        }
    }
}

#[test]
fn a_python_external_server_answers_cmux_apps_run_with_the_approved_credential() {
    let mut daemon = Daemon::start("hello-python");
    let mut app = daemon.app();
    // Installed from the consent card: it grants server:execute, which the manifest asks for.
    let installed = app.rpc(json!({ "cmd": "apps-set", "origin": "user", "idempotency_key": "i1", "app": APP, "installed": true }));
    assert_eq!(installed["ok"], true, "{installed}");

    // No server connected: the run answers at once.
    let run = daemon.apps_run("manaflow_ai.hello_python.hello", json!({}));
    assert_eq!(run.status.code(), Some(1), "{run:?}");
    assert!(String::from_utf8_lossy(&run.stderr).contains("apps.server_unavailable"), "{run:?}");

    // A server without a credential is refused, and so is one with a made-up credential.
    for credential in ["", "cmuxsrv1_madeup"] {
        let n = daemon.python_server(credential);
        let said = daemon.server_says(n);
        assert!(said.contains("refused: apps.server_credential"), "{credential:?}: {said}");
        assert_eq!(daemon.servers[n].wait().unwrap().code(), Some(1));
    }
    // Only the cmux app (origin user) approves a credential; a CLI connection cannot.
    let mut cli =
        Client { reader: BufReader::new(UnixStream::connect(&daemon.socket).unwrap()), next: 1 };
    let refused = cli.rpc(json!({ "cmd": "apps-server-credential", "app": APP }));
    assert_eq!(refused["ok"], false, "{refused}");

    let approved =
        app.rpc(json!({ "cmd": "apps-server-credential", "origin": "user", "app": APP }));
    let credential = approved["data"]["credential"].as_str().expect("a credential").to_string();
    let n = daemon.python_server(&credential);
    assert!(daemon.server_says(n).contains("serving"), "the server attached");

    let run = daemon.apps_run("manaflow_ai.hello_python.hello", json!({ "name": "Leo" }));
    assert!(run.status.success(), "{run:?}");
    let answer: Value = serde_json::from_slice(&run.stdout).unwrap();
    assert_eq!(answer["value"]["text"], "Hello, Leo, from Python", "{answer}");
    let run = daemon.apps_run("manaflow_ai.hello_python.status", json!({}));
    assert!(run.status.success(), "{run:?}");
    let answer: Value = serde_json::from_slice(&run.stdout).unwrap();
    assert_eq!(answer["value"]["served"], 2, "{answer}");

    // Revoking the approval stops the server: it reads the stop line and exits 0.
    let revoked = app.rpc(json!({ "cmd": "apps-set", "origin": "user", "idempotency_key": "r1", "app": APP, "grant": { "scope": "server:execute", "granted": false } }));
    assert_eq!(revoked["ok"], true, "{revoked}");
    assert_eq!(daemon.servers[n].wait().unwrap().code(), Some(0));
    let run = daemon.apps_run("manaflow_ai.hello_python.hello", json!({}));
    assert!(String::from_utf8_lossy(&run.stderr).contains("apps.server_unapproved"), "{run:?}");
}
