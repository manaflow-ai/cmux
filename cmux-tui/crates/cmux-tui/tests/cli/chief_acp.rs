//! `cmux chief acp`: the Chief as an ACP agent on stdin and stdout, so the
//! agent chat's harness picker can start a chat backed by the Chief (user,
//! 2026-10-30: "add our chief chat harness to one of the options in the acp
//! chat UI"). Run against a real headless daemon with a stand-in brain, as
//! `cmux chief -p` is: a prompt is a `user_local` message in the Chief
//! conversation Home shows, and the Chief's reply streams back as
//! `agent_message_chunk` updates until its turn ends.

use super::*;
use serde_json::{Value, json};

/// `cmux --socket S chief acp` with pipes on stdin and stdout.
struct Agent {
    child: Child,
    stdin: std::process::ChildStdin,
    lines: mpsc::Receiver<Value>,
    next: u64,
}

impl Agent {
    fn start(server: &HeadlessServer) -> Self {
        let mut command = Command::new(bin());
        command
            .arg("--socket")
            .arg(&server.socket)
            .args(["chief", "acp"])
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET");
        for key in
            ["ACPMUX_ENV", "ACPMUX_SESSION_ID", "ACPMUX_SESSION_NAME", "CMUX_AGENT_PRINCIPAL"]
        {
            command.env_remove(key);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let value: Value = serde_json::from_str(&line)
                    .unwrap_or_else(|e| panic!("stdout is not JSON-RPC ({e}): {line}"));
                if tx.send(value).is_err() {
                    break;
                }
            }
        });
        Self { child, stdin, lines, next: 1 }
    }

    fn send(&mut self, method: &str, params: Value) -> u64 {
        let id = self.next;
        self.next += 1;
        let body = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writeln!(self.stdin, "{body}").unwrap();
        id
    }

    /// The answer to request `id`, and the notifications before it.
    fn answer(&mut self, id: u64) -> (Value, Vec<Value>) {
        let mut notes = Vec::new();
        loop {
            let line = self.lines.recv_timeout(Duration::from_secs(30)).expect("no answer");
            if line["id"] == id && line.get("method").is_none() {
                return (line, notes);
            }
            notes.push(line);
        }
    }

    fn call(&mut self, method: &str, params: Value) -> (Value, Vec<Value>) {
        let id = self.send(method, params);
        self.answer(id)
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The text the `agent_message_chunk` updates of `notes` stream, in order.
fn streamed(notes: &[Value], session: &str) -> String {
    notes
        .iter()
        .filter(|n| n["method"] == "session/update" && n["params"]["sessionId"] == session)
        .filter(|n| n["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        .filter_map(|n| n["params"]["update"]["content"]["text"].as_str())
        .collect()
}

#[test]
fn chief_acp_sends_a_prompt_as_the_person_and_streams_the_reply_until_the_turn_ends() {
    let server = HeadlessServer::start("chief-acp");
    let mut home = Conn::open(&server.socket);
    let conversation = chief_conversation(&mut home);
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    home.request("subscribe", json!({}));
    let mut agent = Agent::start(&server);

    let (init, _) = agent.call(
        "initialize",
        json!({"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": false}}}),
    );
    assert_eq!(init["result"]["protocolVersion"], 1, "{init}");
    assert_eq!(init["result"]["agentCapabilities"]["loadSession"], true, "{init}");
    assert_eq!(init["result"]["agentInfo"]["title"], "Chief", "{init}");

    let (created, _) = agent.call("session/new", json!({"cwd": "/tmp", "mcpServers": []}));
    let session = created["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{created}"));
    let session = session.to_owned();

    let brain = fake_brain(server.socket.clone(), conversation, token, false);
    let (reply, notes) = agent.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "status?"}]}),
    );
    brain.join().unwrap();
    assert_eq!(reply["result"]["stopReason"], "end_turn", "{reply}");
    assert_eq!(streamed(&notes, &session), "echo: status?", "{notes:?}");

    // Home shows the prompt as the person's message, then the Chief's reply.
    let mut seen = Vec::new();
    while seen.len() < 2 {
        let event = home.event();
        if event["event"] == "conversation-changed" && event["change"]["kind"] == "message" {
            seen.push(event["change"]["message"].clone());
        }
    }
    assert_eq!(seen[0]["author"], "user_local");
    assert_eq!(text_of(&seen[0]), "status?");
    assert_eq!(seen[1]["author"], "agent_mux");

    // A session acpmux saved earlier loads again: every session is the one Chief chat.
    let (loaded, _) = agent.call(
        "session/load",
        json!({"sessionId": "chief-earlier", "cwd": "/tmp", "mcpServers": []}),
    );
    assert!(loaded.get("error").is_none(), "{loaded}");
}

#[test]
fn chief_acp_refuses_an_empty_prompt_and_a_cancel_ends_the_wait() {
    let server = HeadlessServer::start("chief-acp-cancel");
    let mut home = Conn::open(&server.socket);
    let _conversation = chief_conversation(&mut home);
    home.request("subscribe", json!({}));
    let mut agent = Agent::start(&server);
    agent.call("initialize", json!({"protocolVersion": 1}));
    let (created, _) = agent.call("session/new", json!({"cwd": "/tmp", "mcpServers": []}));
    let session = created["result"]["sessionId"].as_str().unwrap().to_owned();

    let (empty, _) = agent.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "  "}]}),
    );
    assert!(empty.get("error").is_some(), "an empty prompt is refused: {empty}");

    // No brain answers: the prompt waits until the client cancels it.
    let id = agent.send(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "anyone?"}]}),
    );
    assert_eq!(text_of(&home.person_message()), "anyone?");
    writeln!(
        agent.stdin,
        "{}",
        json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": session}})
    )
    .unwrap();
    let (cancelled, _) = agent.answer(id);
    assert_eq!(cancelled["result"]["stopReason"], "cancelled", "{cancelled}");
}

#[test]
fn chief_acp_answers_a_model_probe_without_opening_the_chief() {
    // acpmux probes every ACP harness at its start (spawn, initialize, session/new, kill):
    // that must never start or wake a Chief, so session/new opens nothing, even where no
    // Chief conversation exists yet. The first prompt says so instead.
    let server = HeadlessServer::start("chief-acp-probe");
    let mut agent = Agent::start(&server);
    agent.call("initialize", json!({"protocolVersion": 1}));
    let (created, _) = agent.call("session/new", json!({"cwd": "/tmp", "mcpServers": []}));
    let session = created["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{created}"));
    let session = session.to_owned();
    let mut home = Conn::open(&server.socket);
    let listed = home.request("conversation-list", json!({}));
    assert_eq!(listed["conversations"], json!([]), "the probe made a conversation: {listed}");
    let (refused, _) = agent.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]}),
    );
    let message = refused["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("no Chief conversation"), "{refused}");
}
