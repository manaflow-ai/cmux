//! Muse Code reports its state to the cmux-tui terminal it runs in.
//!
//! Muse runs every hook command through `$SHELL -c` with a cleared
//! environment, so the hook sees none of the terminal's `CMUX_TUI_*`
//! variables. `cmux agent hook install muse` writes commands that call the
//! installed helper by absolute path, and the helper takes the session socket
//! and terminal from the muse process it runs under.
//!
//! The last test drives a real `muse` binary (CMUX_TEST_MUSE_BIN) against a
//! loopback model endpoint, so it needs no Meta account:
//! `CMUX_TEST_MUSE_BIN=/path/to/muse cargo test -p cmux-tui --test muse_agent_hooks -- --include-ignored`.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

fn socket_path(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-mu-{name}-{}-{stamp}.sock", std::process::id()))
}

/// The cmux-tui binary, linked into a folder of its own. A test build's
/// standalone `cmux-tui-hook` beside the original is larger than the installer
/// accepts, so the install writes the launcher that re-enters cmux-tui, as it
/// does on a host that received only cmux-tui.
fn cli() -> &'static Path {
    static CLI: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    CLI.get_or_init(|| {
        let dir = tempfile::Builder::new().prefix("cmux-mu-cli").tempdir().unwrap().keep();
        let path = dir.join("cmux-tui");
        let original = Path::new(env!("CARGO_BIN_EXE_cmux-tui"));
        if std::fs::hard_link(original, &path).is_err() {
            std::fs::copy(original, &path).unwrap();
        }
        path
    })
}

/// `cmux agent hook install muse` in `home`, returning settings.json.
fn install_hooks(home: &Path) -> Value {
    let output = Command::new(cli())
        .args(["--json", "agent", "hook", "install", "muse"])
        .env("HOME", home)
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("XDG_DATA_HOME")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let path = home.join(".config/muse/settings.json");
    serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap()
}

/// A journal server that answers every request and records it.
struct Journal {
    socket: PathBuf,
    requests: Arc<(Mutex<Vec<Value>>, Condvar)>,
}

impl Journal {
    fn start(name: &str) -> Self {
        let socket = socket_path(name);
        let listener = UnixListener::bind(&socket).unwrap();
        let requests = Arc::new((Mutex::new(Vec::new()), Condvar::new()));
        let recorded = Arc::clone(&requests);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let recorded = Arc::clone(&recorded);
                thread::spawn(move || {
                    let mut writer = stream.try_clone().unwrap();
                    for line in BufReader::new(stream).lines() {
                        let Ok(line) = line else { return };
                        let Ok(request) = serde_json::from_str::<Value>(&line) else { return };
                        let response = json!({
                            "protocol":"cmux.protocol/2","type":"response","id":request["id"],
                            "ok":true,"result":{"value":{"sequence":"1"}}
                        });
                        recorded.0.lock().unwrap().push(request);
                        recorded.1.notify_all();
                        if writer.write_all(format!("{response}\n").as_bytes()).is_err() {
                            return;
                        }
                    }
                });
            }
        });
        Self { socket, requests }
    }

    /// The journaled events, as (native event, kind, terminal subject).
    fn events(&self) -> Vec<(String, String, Option<String>)> {
        Self::journaled(&self.requests.0.lock().unwrap())
    }

    fn journaled(requests: &[Value]) -> Vec<(String, String, Option<String>)> {
        requests
            .iter()
            .filter(|request| request["operation"] == "session.journal.append")
            .map(|request| {
                let event = &request["params"]["event"];
                assert_eq!(event["payload"]["adapter"]["id"], "muse", "{request}");
                let terminal = event["subjects"].as_array().and_then(|subjects| {
                    subjects.iter().find(|subject| subject["kind"] == "terminal")
                });
                (
                    event["payload"]["native_event"].as_str().unwrap_or_default().to_owned(),
                    event["kind"].as_str().unwrap_or_default().to_owned(),
                    terminal.and_then(|subject| subject["id"].as_str()).map(str::to_owned),
                )
            })
            .collect()
    }

    /// Waits until `count` events arrived or `budget` passed.
    fn wait_for(&self, count: usize, budget: Duration) {
        let (requests, arrived) = &*self.requests;
        let deadline = Instant::now() + budget;
        let mut requests = requests.lock().unwrap();
        while Self::journaled(&requests).len() < count {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            requests = arrived.wait_timeout(requests, left).unwrap().0;
        }
    }
}

impl Drop for Journal {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket);
    }
}

/// Set when this test binary runs itself as the stand-in muse process.
const PARENT_HOOK: &str = "CMUX_MUSE_TEST_PARENT_HOOK";
/// Where the stand-in writes the hook's stdout and stderr.
const PARENT_OUT: &str = "CMUX_MUSE_TEST_PARENT_OUT";

/// The stand-in muse process: with `PARENT_HOOK` set, run that hook command
/// the way Muse does (`sh -c`, environment cleared to HOME, PATH and SHELL),
/// write its output beside `PARENT_OUT`, and exit with its status. Without
/// it this test does nothing. It is this binary rather than a shell because
/// macOS hides the environment of Apple-signed programs (/bin/sh) from other
/// processes, and the agent's environment must be readable, as muse's is.
#[test]
fn stand_in_muse_process() {
    let (Some(command), Some(out)) = (std::env::var_os(PARENT_HOOK), std::env::var_os(PARENT_OUT))
    else {
        return;
    };
    let out = PathBuf::from(out);
    let output = Command::new("/bin/sh")
        .arg("-c")
        .arg(command)
        .env_clear()
        .env("HOME", std::env::var_os("HOME").unwrap())
        .env("PATH", "/usr/bin:/bin")
        .env("SHELL", "/bin/sh")
        .stdin(Stdio::inherit())
        .output()
        .unwrap();
    std::fs::write(out.with_extension("stdout"), &output.stdout).unwrap();
    std::fs::write(out.with_extension("stderr"), &output.stderr).unwrap();
    std::process::exit(output.status.code().unwrap_or(1));
}

/// What a hook run under the stand-in muse process left.
struct HookRun {
    success: bool,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

/// Runs `command` the way Muse runs a hook, under a stand-in muse process
/// whose environment is HOME, PATH and `agent_env`, with `payload` on stdin.
fn run_like_muse(command: &str, home: &Path, agent_env: &[(&str, &str)], payload: &str) -> HookRun {
    let scratch = tempfile::tempdir().unwrap();
    let out = scratch.path().join("hook");
    let mut parent = Command::new(std::env::current_exe().unwrap());
    parent
        .args(["--exact", "stand_in_muse_process", "--nocapture", "--test-threads=1"])
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env(PARENT_HOOK, command)
        .env(PARENT_OUT, &out)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    for (name, value) in agent_env {
        parent.env(name, value);
    }
    let mut child = parent.spawn().unwrap();
    child.stdin.take().unwrap().write_all(payload.as_bytes()).unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(child.wait());
    });
    let status = receiver.recv_timeout(Duration::from_secs(10)).expect("the hook exits").unwrap();
    let read = |extension: &str| std::fs::read(out.with_extension(extension)).unwrap_or_default();
    HookRun { success: status.success(), stdout: read("stdout"), stderr: read("stderr") }
}

fn stop_command(settings: &Value) -> String {
    let groups = settings["hooks"]["Stop"].as_array().expect("a Stop hook");
    assert_eq!(groups.len(), 1, "{settings}");
    let handler = &groups[0]["hooks"][0];
    // Muse skips a whole event when a handler has a key it does not know.
    let mut keys: Vec<&str> = handler.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, ["command", "timeout", "type"], "{handler}");
    handler["command"].as_str().unwrap().to_owned()
}

#[test]
fn a_muse_hook_with_a_cleared_environment_reports_to_the_muse_terminal() {
    let home = tempfile::tempdir().unwrap();
    let settings = install_hooks(home.path());
    assert_eq!(settings["schema_version"], 1, "Muse refuses settings without it: {settings}");
    let command = stop_command(&settings);
    assert!(!command.contains("CMUX_TUI_HOOK"), "Muse never passes it: {command}");

    let journal = Journal::start("stop");
    let socket = journal.socket.to_str().unwrap().to_owned();
    let output = run_like_muse(
        &command,
        home.path(),
        &[("CMUX_TUI_SOCKET", &socket), ("CMUX_TUI_TERMINAL_ID", TERMINAL)],
        r#"{"hook_event_name":"Stop","session_id":"muse-session","cwd":"/tmp","model":"muse-spark-1.3","permission_mode":"default","transcript_path":null,"turn_id":"turn-1","last_assistant_message":"done","stop_hook_active":false}"#,
    );
    assert!(output.success, "{}", String::from_utf8_lossy(&output.stderr));
    // Muse can fail a hook run on stdout keys it does not know.
    assert!(output.stdout.is_empty(), "{}", String::from_utf8_lossy(&output.stdout));
    journal.wait_for(1, Duration::from_secs(5));
    assert_eq!(
        journal.events(),
        [("Stop".to_owned(), "agent.turn.completed".to_owned(), Some(TERMINAL.to_owned()))]
    );
}

#[test]
fn a_muse_hook_outside_a_cmux_terminal_does_nothing() {
    let home = tempfile::tempdir().unwrap();
    let command = stop_command(&install_hooks(home.path()));
    let output = run_like_muse(&command, home.path(), &[], r#"{"hook_event_name":"Stop"}"#);
    assert!(output.success, "{}", String::from_utf8_lossy(&output.stderr));
    assert!(output.stdout.is_empty(), "{}", String::from_utf8_lossy(&output.stdout));
    assert!(output.stderr.is_empty(), "{}", String::from_utf8_lossy(&output.stderr));
}

#[test]
fn reinstalling_keeps_one_muse_hook_and_the_users_own() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join(".config/muse/settings.json");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(
        &path,
        r#"{"schema_version":1,"model":"muse-spark-1.3","hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"my-notifier"}]}]}}"#,
    )
    .unwrap();
    install_hooks(home.path());
    let settings = install_hooks(home.path());
    assert_eq!(settings["model"], "muse-spark-1.3", "{settings}");
    let stop = settings["hooks"]["Stop"].as_array().unwrap();
    assert_eq!(stop.len(), 2, "{settings}");
    assert_eq!(stop[0]["hooks"][0]["command"], "my-notifier", "{settings}");

    let output = Command::new(cli())
        .args(["--json", "agent", "hook", "uninstall", "muse"])
        .env("HOME", home.path())
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("XDG_DATA_HOME")
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let settings: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        settings["hooks"],
        json!({"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"my-notifier"}]}]})
    );
}

/// A loopback model endpoint in the shape Muse's own SDK quickstart uses:
/// one visible model in the catalog, and a short text answer to every turn.
fn start_model_endpoint() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request_line = String::new();
                if reader.read_line(&mut request_line).is_err() {
                    return;
                }
                let mut length = 0_usize;
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).is_err() || header.trim().is_empty() {
                        break;
                    }
                    if let Some((name, value)) = header.split_once(':')
                        && name.eq_ignore_ascii_case("content-length")
                    {
                        length = value.trim().parse().unwrap_or(0);
                    }
                }
                let mut body = vec![0; length];
                let _ = reader.read_exact(&mut body);
                let (content_type, body) = if request_line.contains("/muse-code/models") {
                    ("application/json", json!({"object":"list","data":[{"id":"fake-model","object":"model","metadata":{"muse-code":{"release_date":"2026-01-01","is_hidden":false,"limit":{"context":1_000_000,"output":1024}}}}]}).to_string())
                } else {
                    let frame = |status: &str| json!({"id":"resp_cmux","object":"response","model":"fake-model","status":status,"output":[]});
                    let events = [
                        json!({"type":"response.created","sequence_number":1,"response":frame("in_progress")}),
                        json!({"type":"response.output_text.delta","sequence_number":2,"output_index":0,"item_id":"msg_cmux","content_index":0,"delta":"hello"}),
                        json!({"type":"response.completed","sequence_number":3,"response":{"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"id":"resp_cmux","object":"response","model":"fake-model","status":"completed","output":[]}}),
                    ];
                    (
                        "text/event-stream",
                        events.iter().map(|event| format!("data: {event}\n\n")).collect(),
                    )
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
            });
        }
    });
    base
}

#[test]
#[ignore = "needs a muse binary in CMUX_TEST_MUSE_BIN"]
fn a_real_muse_session_reports_its_start_turn_and_stop_to_the_terminal() {
    let muse = std::env::var_os("CMUX_TEST_MUSE_BIN").expect("CMUX_TEST_MUSE_BIN names muse");
    let home = tempfile::tempdir().unwrap();
    let config = home.path().join(".config/muse");
    std::fs::create_dir_all(&config).unwrap();
    let base = start_model_endpoint();
    std::fs::write(
        config.join("settings.json"),
        json!({"schema_version":1,"endpoint_transport":{"base_url":base,"auth":"bearer"}})
            .to_string(),
    )
    .unwrap();
    // Muse needs a stored credential; the loopback endpoint never checks it.
    std::fs::write(
        config.join("auth.json"),
        r#"{"schema_version":1,"providers":{"meta":{"api_key":"cmux-test-dummy-key"}}}"#,
    )
    .unwrap();
    let settings = install_hooks(home.path());
    assert_eq!(settings["endpoint_transport"]["base_url"], base.as_str(), "{settings}");

    let journal = Journal::start("real");
    let workspace = tempfile::tempdir().unwrap();
    let output = Command::new(&muse)
        .args(["exec", "--disable-approval", "--max-model-steps", "4"])
        .arg("Reply with the single word: hello")
        .current_dir(workspace.path())
        .env_clear()
        .env("HOME", home.path())
        .env("PATH", "/usr/bin:/bin")
        .env("SHELL", "/bin/sh")
        .env("TERM", "dumb")
        .env("CMUX_TUI_SOCKET", &journal.socket)
        .env("CMUX_TUI_TERMINAL_ID", TERMINAL)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "muse exec failed: {}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    journal.wait_for(3, Duration::from_secs(10));
    let events = journal.events();
    for (native, kind) in [
        ("SessionStart", "agent.session.started"),
        ("UserPromptSubmit", "agent.turn.started"),
        ("Stop", "agent.turn.completed"),
    ] {
        assert!(
            events
                .iter()
                .any(|event| event
                    == &(native.to_owned(), kind.to_owned(), Some(TERMINAL.to_owned()))),
            "no {native} from the terminal in {events:?}"
        );
    }
}
