//! The `cmux-app-host` binary: fd 3 protocol end to end, and the OS sandbox.
#![cfg(unix)]

mod common;

use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    const BIN: &str = env!("CARGO_BIN_EXE_cmux-app-host");

    struct Host {
        child: Child,
        write: UnixStream,
        read: BufReader<UnixStream>,
    }

    impl Host {
        fn spawn() -> Self {
            let (ours, theirs) = UnixStream::pair().expect("socketpair");
            let fd = theirs.as_raw_fd();
            let mut command = Command::new(BIN);
            command.env_clear().stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::inherit());
            // SAFETY: dup2 is async-signal-safe; it runs in the child before exec.
            unsafe {
                command.pre_exec(move || {
                    if libc::dup2(fd, 3) == 3 {
                        Ok(())
                    } else {
                        Err(std::io::Error::last_os_error())
                    }
                });
            }
            let child = command.spawn().expect("spawn cmux-app-host");
            drop(theirs);
            ours.set_read_timeout(Some(Duration::from_secs(10))).expect("timeout");
            let read = BufReader::new(ours.try_clone().expect("clone"));
            Self { child, write: ours, read }
        }

        fn send(&mut self, message: Value) {
            let mut line = message.to_string();
            line.push('\n');
            self.write.write_all(line.as_bytes()).expect("write");
        }

        fn recv(&mut self) -> Value {
            let mut line = String::new();
            self.read.read_line(&mut line).expect("read");
            assert!(!line.is_empty(), "host closed fd 3");
            serde_json::from_str(&line).expect("json line")
        }

        /// Reads until a message with tag `t`, answering calls with `answer`.
        fn until(
            &mut self,
            t: &str,
            answer: &dyn Fn(&Value) -> Value,
            seen: &mut Vec<Value>,
        ) -> Value {
            loop {
                let message = self.recv();
                if message["t"] == "call" {
                    let body = answer(&message);
                    self.send(json!({ "t": "resolve", "cb": message["cb"], "ok": body.get("code").is_none(), "body": body }));
                }
                if message["t"] == t {
                    return message;
                }
                seen.push(message);
            }
        }
    }

    #[test]
    fn the_binary_runs_a_sample_over_fd3_and_exits_on_shutdown() {
        let mut host = Host::spawn();
        host.send(json!({
        "t": "init", "app": { "id": "cmux/agent-status", "version": "1.0.0" }, "api_version": "1.0.0",
        "ops": ["agent.list"], "known_ops": ["agent.list"], "main": common::sample("agent-status")
    }));
        let mut seen = Vec::new();
        let ready = host.until("ready", &|_| json!({}), &mut seen);
        // The embedded runtime reports its own version (`__cmuxAppRuntimeVersion`).
        assert!(ready["runtime"].as_str().is_some_and(|v| v.split('.').count() == 3), "{ready}");
        host.send(json!({ "t": "mount", "mount": "m1", "export": "renderStatus", "ctx": {} }));
        let agents = json!({ "value": [
        { "id": "agent_1", "state": "working", "terminal_id": "term_1", "source_session": "a" },
        { "id": "agent_2", "state": "blocked", "terminal_id": "term_2", "source_session": "b" }
    ] });
        let mounted = host.until("mounted", &|_| agents.clone(), &mut seen);
        assert_eq!(mounted, json!({ "t": "mounted", "mount": "m1" }));
        // The agent list arrives after the first render; the update follows as a scene batch.
        let mut scene_text = String::new();
        for _ in 0..8 {
            let message = host.until("scene", &|_| agents.clone(), &mut seen);
            scene_text.push_str(&message["ops"].to_string());
            if scene_text.contains("1 working") {
                break;
            }
        }
        let all: String = seen.iter().map(Value::to_string).collect::<String>() + &scene_text;
        assert!(all.contains("1 working · 1 waiting"), "{all}");
        host.send(json!({ "t": "shutdown" }));
        assert_eq!(host.child.wait().expect("wait").code(), Some(0));
    }

    #[test]
    fn a_runaway_app_sends_fatal_and_exits_70() {
        let mut host = Host::spawn();
        host.send(json!({ "t": "init", "app": { "id": "local/spin", "version": "1.0.0" }, "api_version": "1.0.0", "main": common::app("return { render: () => { for (;;) {} } }") }));
        let mut seen = Vec::new();
        host.until("ready", &|_| json!({}), &mut seen);
        host.send(json!({ "t": "mount", "mount": "m", "export": "render" }));
        let fatal = host.until("fatal", &|_| json!({}), &mut seen);
        assert_eq!(fatal["reason"], "interrupt");
        assert_eq!(host.child.wait().expect("wait").code(), Some(70));
    }

    #[test]
    fn a_malformed_line_ends_the_host_with_a_protocol_error() {
        let mut host = Host::spawn();
        host.write.write_all(b"{not json}\n").expect("write");
        assert_eq!(host.child.wait().expect("wait").code(), Some(65));
    }

    #[test]
    fn the_sandbox_denies_files_sockets_and_exec() {
        let output = Command::new(BIN)
            .arg("--sandbox-self-test")
            .arg("/etc/hosts")
            .env_clear()
            .output()
            .expect("self test");
        let line = String::from_utf8_lossy(&output.stdout);
        let report: Value = serde_json::from_str(line.trim())
            .unwrap_or_else(|e| panic!("{e}: {line} {}", String::from_utf8_lossy(&output.stderr)));
        assert_eq!(report["applied"], true, "{report}");
        assert_eq!(report["read"], false, "file read must be denied: {report}");
        assert_eq!(report["socket"], false, "sockets must be denied: {report}");
        assert_eq!(report["exec"], false, "exec must be denied: {report}");
        // Unsandboxed, the same probes succeed, so the test proves the sandbox did it.
        assert!(std::fs::read("/etc/hosts").is_ok());
    }
}
