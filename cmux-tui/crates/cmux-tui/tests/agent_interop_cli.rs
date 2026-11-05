//! What a coding agent (Claude Code, Codex, Gemini, opencode, an OpenAI
//! computer-use loop) relies on when it drives cmux through the CLI:
//!
//! - every failure under `--json` is one JSON error object on stderr, also
//!   when the session closed the connection or spoke another protocol, so an
//!   agent can branch on `code` instead of parsing prose;
//! - a command run inside an agent's terminal (which carries a launch
//!   credential) does not pay an extra `identify` round trip per call: the
//!   capability answer is remembered per session process.
#![cfg(unix)]

/// One module, so `cargo nextest run agent_interop_cli` selects these tests.
mod agent_interop_cli {
    use std::fs;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::thread::JoinHandle;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use serde_json::{Value, json};

    const CREDENTIAL: &str = "cmuxlc1.k1.e30.dGFn";

    fn temp_dir(label: &str) -> PathBuf {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        // Short: Unix socket paths are limited to about 100 bytes.
        let dir = PathBuf::from("/tmp").join(format!("cxi-{label}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Runs the CLI with an isolated environment; `extra` adds variables.
    fn cmux(dir: &Path, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(args)
            .env("HOME", dir)
            .env("TMPDIR", dir)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_LAUNCH_CREDENTIAL")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .env_remove("CMUX_AGENT_SESSION")
            .stdin(Stdio::null());
        for (name, value) in extra {
            command.env(name, value);
        }
        command.output().unwrap()
    }

    fn json_error(output: &Output) -> Value {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let line = stderr.lines().find(|line| !line.trim().is_empty()).unwrap_or_default();
        serde_json::from_str(line)
            .unwrap_or_else(|error| panic!("stderr is not one JSON error ({error}): {stderr:?}"))
    }

    /// Serves `socket` until `done`, answering each request line with `answer`
    /// (`None` closes the connection); returns every request it read.
    fn serve(
        socket: &Path,
        done: Arc<AtomicBool>,
        answer: impl Fn(&Value) -> Option<Value> + Send + 'static,
    ) -> JoinHandle<Vec<Value>> {
        let listener = UnixListener::bind(socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let received = Arc::new(Mutex::new(Vec::new()));
        std::thread::spawn(move || {
            while !done.load(Ordering::SeqCst) {
                let stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    Err(error) => panic!("accept: {error}"),
                };
                stream.set_nonblocking(false).unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut writer = stream;
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        break;
                    }
                    let Ok(request) = serde_json::from_str::<Value>(&line) else { break };
                    received.lock().unwrap().push(request.clone());
                    let reply = if request["cmd"] == "set-client-info" {
                        Some(json!({"id": request["id"], "ok": true, "data": {}}))
                    } else {
                        answer(&request)
                    };
                    match reply {
                        Some(reply) => {
                            if writeln!(writer, "{reply}").is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
            }
            std::mem::take(&mut *received.lock().unwrap())
        })
    }

    /// A current session: `identify` advertises launch credentials, and any
    /// resource request gets an empty list.
    fn current_session(request: &Value) -> Option<Value> {
        if request["cmd"] == "identify" {
            return Some(json!({"id": request["id"], "ok": true,
                "data": {"app": "cmux-tui", "protocol": 2,
                    "capabilities": ["launch-credential-v1", "session-identity-v1"]}}));
        }
        Some(json!({"protocol": "cmux.protocol/2", "type": "response",
            "id": request["id"], "ok": true, "result": []}))
    }

    #[test]
    fn an_agent_terminal_asks_the_session_for_its_capabilities_once() {
        let dir = temp_dir("caps");
        let socket = dir.join("s.sock");
        let done = Arc::new(AtomicBool::new(false));
        let server = serve(&socket, done.clone(), current_session);
        let path = socket.to_str().unwrap();
        let env = [("CMUX_TUI_SOCKET", path), ("CMUX_LAUNCH_CREDENTIAL", CREDENTIAL)];
        for _ in 0..3 {
            let output = cmux(&dir, &["--json", "--socket", path, "workspace", "list"], &env);
            assert_eq!(
                output.status.code(),
                Some(0),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        done.store(true, Ordering::SeqCst);
        let received = server.join().unwrap();
        let identifies = received.iter().filter(|request| request["cmd"] == "identify").count();
        let operations: Vec<&Value> =
            received.iter().filter(|request| request["type"] == "request").collect();
        assert_eq!(operations.len(), 3, "{received:?}");
        for operation in &operations {
            assert_eq!(
                operation["credential"], CREDENTIAL,
                "each call still carries its credential"
            );
        }
        assert_eq!(identifies, 1, "one identify for three calls to the same session: {received:?}");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn a_session_that_closes_without_an_answer_is_a_json_error_under_json() {
        let dir = temp_dir("closed");
        let socket = dir.join("s.sock");
        let done = Arc::new(AtomicBool::new(false));
        let server = serve(&socket, done.clone(), |_| None);
        let output =
            cmux(&dir, &["--json", "--socket", socket.to_str().unwrap(), "workspace", "list"], &[]);
        done.store(true, Ordering::SeqCst);
        server.join().unwrap();
        assert_eq!(output.status.code(), Some(3));
        let error = json_error(&output);
        assert_eq!(error["code"], "transport.closed", "{error}");
        assert_eq!(error["retryable"], true, "{error}");
        assert!(error["message"].as_str().is_some_and(|message| !message.is_empty()), "{error}");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn a_server_of_another_protocol_is_a_json_error_under_json() {
        let dir = temp_dir("proto");
        let socket = dir.join("s.sock");
        let done = Arc::new(AtomicBool::new(false));
        let server = serve(&socket, done.clone(), |request| {
            Some(json!({"id": request["id"], "ok": false, "error": "unknown command"}))
        });
        let output =
            cmux(&dir, &["--json", "--socket", socket.to_str().unwrap(), "workspace", "list"], &[]);
        done.store(true, Ordering::SeqCst);
        server.join().unwrap();
        assert_eq!(output.status.code(), Some(3));
        let error = json_error(&output);
        assert_eq!(error["code"], "protocol.mismatch", "{error}");
        assert!(
            error["message"].as_str().unwrap_or_default().contains("cmux.protocol/2"),
            "{error}"
        );
        let _ = fs::remove_dir_all(dir);
    }
}
