//! `acpmux cli-agent`: a plain CLI as an ACP agent, end to end over stdio.

#[path = "support/daemon_env.rs"]
mod daemon_env;

const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::Stdio;
use std::time::{Duration, Instant};

struct Agent {
    child: std::process::Child,
    lines: std::sync::mpsc::Receiver<Value>,
}

impl Agent {
    fn start(args: &[&str]) -> Agent {
        let scratch = std::env::temp_dir().join(format!("acpmux-cli-agent-{}", std::process::id()));
        std::fs::create_dir_all(&scratch).unwrap();
        let mut child = daemon_env::acpmux(&scratch)
            .arg("cli-agent")
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("start acpmux cli-agent");
        let out = child.stdout.take().unwrap();
        let (tx, lines) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    let _ = tx.send(v);
                }
            }
        });
        Agent { child, lines }
    }

    fn send(&mut self, v: Value) {
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{v}").unwrap();
        stdin.flush().unwrap();
    }

    /// Messages until the response to `id`; the response and the reply text.
    fn until(&self, id: i64) -> (Value, String) {
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut text = String::new();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let v = self.lines.recv_timeout(left).expect("agent answered in time");
            if v.get("id").and_then(Value::as_i64) == Some(id) {
                return (v, text);
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

fn session(agent: &mut Agent) -> String {
    agent
        .send(json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}));
    let (init, _) = agent.until(1);
    assert_eq!(init.pointer("/result/protocolVersion"), Some(&json!(1)));
    let cwd = std::env::temp_dir();
    agent.send(json!({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd": cwd, "mcpServers": []}}));
    let (new, _) = agent.until(2);
    new.pointer("/result/sessionId").and_then(Value::as_str).expect("session id").to_owned()
}

#[test]
fn cli_agent_a_prompt_runs_the_program_and_streams_its_output() {
    let mut agent = Agent::start(&["--", "cat"]);
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid,
        "prompt": [{"type":"text","text":"view\n"},{"type":"text","text":"hello cli"}]
    }}));
    let (done, text) = agent.until(3);
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("end_turn")));
    // The prompt gets a final newline: a line-reading program needs it.
    assert_eq!(text, "view\nhello cli\n");
}

#[test]
fn cli_agent_last_block_sends_only_the_new_messages() {
    let mut agent = Agent::start(&["--last-block", "--", "cat"]);
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid,
        "prompt": [{"type":"text","text":"the view\n"},{"type":"text","text":"only this"}]
    }}));
    let (_, text) = agent.until(3);
    assert_eq!(text, "only this\n");
}

#[test]
fn cli_agent_a_failing_program_fails_the_prompt_with_its_stderr() {
    let mut agent = Agent::start(&["--", "sh", "-c", "echo broken >&2; exit 3"]);
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid, "prompt": [{"type":"text","text":"x"}]
    }}));
    let (done, _) = agent.until(3);
    let message = done.pointer("/error/message").and_then(Value::as_str).unwrap_or("");
    assert!(message.contains("broken"), "{done}");
}

#[test]
fn cli_agent_cancel_stops_a_running_prompt() {
    let mut agent = Agent::start(&["--", "sleep", "30"]);
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid, "prompt": [{"type":"text","text":"x"}]
    }}));
    // The agent reads in order: the prompt is running when the cancel arrives.
    agent.send(json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId": sid}}));
    let (done, _) = agent.until(3);
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("cancelled")));
}

#[cfg(unix)]
#[test]
fn cli_agent_tty_reads_a_program_that_writes_to_its_terminal() {
    // Like unii: the prompt comes on stdin, the reply goes to /dev/tty only.
    let script = "read -r line; echo \"tty says: $line\" > /dev/tty; echo not-on-the-pipe";
    let mut agent = Agent::start(&["--tty", "--", "sh", "-c", script]);
    let sid = session(&mut agent);
    agent.send(json!({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{
        "sessionId": sid, "prompt": [{"type":"text","text":"hello\n"}]
    }}));
    let (done, text) = agent.until(3);
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("end_turn")), "{done}");
    assert!(text.contains("tty says: hello\n"), "{text:?}");
}
