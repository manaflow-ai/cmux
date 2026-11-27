//! A real owner and acpmux daemon, with the existing stand-in Claude harness.
//! Work is created through session/new and parsed from harness events, never
//! injected into either registry. The Channels credential reads it back over WS.
#![cfg(unix)]

#[path = "../../acpmux/tests/support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{self, Message, client::IntoClientRequest};
use wait_timeout::ChildExt;

const TIMEOUT: Duration = Duration::from_secs(30);
const TOKEN: &str = "chief-work-synthetic-owner";

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_some() {
            return;
        }
        // SAFETY: only this fixture's recorded child is signalled. acpmux's
        // SIGTERM path also shuts down the stand-in harnesses it started.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        if self.0.wait_timeout(Duration::from_secs(5)).ok().flatten().is_none() {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

fn command(root: &Path) -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    daemon_env::apply(&mut cmd, root, daemon_env::Agents::StandIn, &[]);
    cmd.env("ACPMUX_HOME", root.join("chief/acpmux"))
        .env("ACPMUX_SOCKET", root.join("chief/acpmux/acpmux.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("CMUX_TUI_CONFIG", root.join("cmux.json"))
        .env("CMUX_TUI_STATE_DIR", root.join("sessions"))
        .env("CMUX_NEXT_CONFIG_FILE", root.join("next.json"));
    cmd
}

fn start(mut cmd: Command, root: &Path, name: &str, acpmux: bool) -> Daemon {
    let log = root.join(format!("{name}.log"));
    // The owner deliberately refuses stdin/stdout/stderr as readiness fds.
    let (ready, inherited) = if acpmux {
        (None, None)
    } else {
        let (read, write) = UnixStream::pair().unwrap();
        read.set_read_timeout(Some(TIMEOUT)).unwrap();
        let fd = write.as_raw_fd();
        cmd.arg("--owner-ready-fd").arg(fd.to_string());
        // SAFETY: the child changes only its inherited readiness descriptor;
        // fcntl is async-signal-safe and no allocation happens on success.
        unsafe {
            cmd.pre_exec(move || {
                if libc::fcntl(fd, libc::F_SETFD, 0) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        (Some(read), Some(write))
    };
    let mut daemon = Daemon(
        cmd.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(fs::File::create(&log).unwrap())
            .spawn()
            .unwrap(),
    );
    drop(inherited);
    let stdout = daemon.0.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let ready = if acpmux {
            BufReader::new(stdout)
                .lines()
                .map_while(Result::ok)
                .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true))
        } else {
            let mut byte = [0];
            ready.unwrap().read_exact(&mut byte).is_ok() && byte == *b"1"
        };
        let _ = tx.send(ready);
    });
    assert_eq!(
        rx.recv_timeout(TIMEOUT),
        Ok(true),
        "{name} did not signal ready: {}",
        fs::read_to_string(log).unwrap_or_default()
    );
    daemon
}

struct Rpc(BufReader<UnixStream>, u64);

impl Rpc {
    fn connect(path: &Path) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream.set_read_timeout(Some(TIMEOUT)).unwrap();
        stream.set_write_timeout(Some(TIMEOUT)).unwrap();
        Self(BufReader::new(stream), 0)
    }

    fn exchange(&mut self, mut body: Value) -> Value {
        self.1 += 1;
        body["id"] = json!(self.1);
        writeln!(self.0.get_mut(), "{body}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.0.read_line(&mut line).unwrap() > 0, "closed before {body}");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["id"] == self.1 {
                return value;
            }
        }
    }

    fn acp(&mut self, method: &str, params: Value) -> Value {
        let reply = self.exchange(json!({"jsonrpc": "2.0", "method": method, "params": params}));
        assert!(reply.get("error").is_none(), "{method}: {reply}");
        reply["result"].clone()
    }

    fn owner(&mut self, body: Value) -> Value {
        let reply = self.exchange(body);
        assert_eq!(reply["ok"], true, "{reply}");
        reply["data"].clone()
    }
}

fn page_read(addr: &str, credential: &str) -> Value {
    let stream = TcpStream::connect(addr).unwrap();
    stream.set_read_timeout(Some(TIMEOUT)).unwrap();
    stream.set_write_timeout(Some(TIMEOUT)).unwrap();
    let mut request = format!("ws://{addr}/").into_client_request().unwrap();
    request.headers_mut().insert("Origin", "cmux-page://cmux.home-channels".parse().unwrap());
    let (mut ws, _) = tungstenite::client(request, stream).unwrap();
    for body in [
        json!({"auth": {"token": credential}}),
        json!({"id": 73, "cmd": "chief-work", "chief": "agent_mux"}),
    ] {
        ws.send(Message::Text(body.to_string().into())).unwrap();
    }
    loop {
        if let Message::Text(text) = ws.read().unwrap() {
            let value: Value = serde_json::from_str(&text).unwrap();
            if value["id"] == 73 {
                assert_eq!(value["ok"], true, "Channels read: {value}");
                return value["data"].clone();
            }
        }
    }
}

#[test]
fn chief_work_channels_reads_real_daemon_sessions_and_harness_commands() {
    let scratch = cmux_unix_socket::short_test_dir("chief-work-live");
    let root = scratch.path();
    for dir in ["chief/optchat", "chief/acpmux", "work", "claude"] {
        fs::create_dir_all(root.join(dir)).unwrap();
    }
    fs::set_permissions(root.join("chief/acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(root.join("chief/optchat/home-id"), "0123abcd\n").unwrap();
    let fake = Path::new(env!("CARGO_MANIFEST_DIR")).join("../acpmux/tests/fake_claude.py");
    let config = json!({
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["python3", fake],
            "env": {"CLAUDE_CONFIG_DIR": root.join("claude")}}},
        "defaultHarness": "claude", "permissionPolicy": "approve-all",
        "titles": {"generate": false}
    });
    let config_path = root.join("chief/acpmux/config.json");
    fs::write(&config_path, config.to_string()).unwrap();
    fs::set_permissions(&config_path, fs::Permissions::from_mode(0o600)).unwrap();
    let cwd = fs::canonicalize(root.join("work")).unwrap();
    fs::write(
        root.join("chief/acpmux/trust.json"),
        json!({cwd.to_str().unwrap(): "trusted"}).to_string(),
    )
    .unwrap();

    let mut cmd = command(root);
    cmd.args(["acp", "daemon", "run", "--ready-fd", "1", "--log", "warn"]);
    let _acpmux = start(cmd, root, "acpmux", true);
    let mut acp = Rpc::connect(&root.join("chief/acpmux/acpmux.sock"));
    acp.acp("initialize", json!({"protocolVersion": 1, "clientCapabilities": {}}));
    let mut make = |name: &str, tags: Value| {
        let created = acp.acp(
            "session/new",
            json!({"cwd": cwd, "mcpServers": [],
            "_meta": {"acpmux": {"name": name, "harness": "claude"}}}),
        );
        let id = created["sessionId"].as_str().unwrap().to_owned();
        acp.acp("_acpmux/tag", json!({"sessionId": id, "set": tags}));
        id
    };
    let _turn = make("Chief turn", json!({"cmux.chief": "0123abcd"}));
    let child = make("Build hello page", json!({"mux.parent": "optchat-chief:0123abcd"}));
    let _other = make("Other Chief's work", json!({"cmux.chief": "87654321"}));
    acp.acp(
        "session/prompt",
        json!({"sessionId": child,
        "prompt": [{"type": "text", "text": "bg-running"}]}),
    );
    let processes = acp.acp("_acpmux/process/list", json!({"sessionId": child}));
    assert_eq!(processes["processes"][0]["command"], "npm run dev", "{processes}");

    let socket = root.join("owner.sock");
    let mut cmd = command(root);
    cmd.args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(root.join("owner-state"))
        .args([
            "--ws",
            "127.0.0.1:0",
            "--ws-token",
            TOKEN,
            "--ws-allow-origin",
            "cmux-page://cmux.home-channels",
        ])
        .env("CMUX_TUI_CHIEF_TOOLS_SOCKET", root.join("chief/optchat/tools.sock"));
    let _owner = start(cmd, root, "owner", false);
    let mut owner = Rpc::connect(&socket);
    let identity = owner.owner(json!({"cmd": "identify"}));
    assert!(identity["capabilities"].as_array().unwrap().iter().any(|v| v == "chief-work-v1"));
    let local = owner.owner(json!({"cmd": "chief-work", "chief": "agent_mux"}));
    let credential = owner.owner(json!({"cmd": "page-credential", "page": "home-channels"}));
    let log = fs::read_to_string(root.join("owner.log")).unwrap();
    let addr =
        log.split("WebSocket control at ws://").nth(1).unwrap().split_whitespace().next().unwrap();
    let page = page_read(addr, credential["credential"].as_str().unwrap());
    assert_eq!(page, local, "Home's page and the owner must read the same snapshot");
    assert_eq!(page["agents"].as_array().unwrap().len(), 1, "{page}");
    assert_eq!(page["agents"][0]["id"], child, "{page}");
    assert_eq!(page["agents"][0]["name"], "Build hello page", "{page}");
    assert_eq!(page["tasks"].as_array().unwrap().len(), 1, "{page}");
    assert_eq!(page["tasks"][0]["sessionId"], child, "{page}");
    assert_eq!(page["tasks"][0]["command"], "npm run dev", "{page}");
    assert_eq!(page["tasks"][0]["status"], "running", "{page}");
    assert_eq!(page["truncated"], false, "{page}");
    assert_eq!(page["taskSources"], json!(["harness"]), "{page}");
    println!("chief-work-runtime: {page}");
}
