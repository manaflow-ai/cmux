//! A question one session sends another without waiting for the reply (`acpmux send --no-wait
//! --class question`), to a session it did not start (W5-S, bench round 4 A5 defect 2,
//! 2026-11-08). The receiver answered; the reply went to no one: the asker's subagent got no
//! report, the lead got none, and the receiver's notice said the asker was "waiting for it",
//! which was false (a `--no-wait` send waits for nobody).
//!
//! - The reply goes back to the asker as the turn's report: to its lead's chat, or to the
//!   Claude Code subagent that asked (acpmux's Bash hook hands it over), as a lane's report does.
//! - The receiver's notice says so, and says "waiting" only for a sender that waits.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const SUB: &str = "a0a68e7af3df5967e";
const WAIT: Duration = Duration::from_secs(20);

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            // Steers as Claude Code does: a prompt during a turn is read into it at once.
            "steer": {"argv": ["python3", FAKE, "--fake", "FAKE_CLAUDE_STEER", "1"], "family": "fake"},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    // The inbox (the default): another session's message goes in as a notice.
    cfg.agent_inbox = Some(true);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The connection an agent's tools open from inside session `id`.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        c.ok(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await;
        c
    }

    async fn send(&mut self, m: &str, params: Value) {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(WAIT, self.1.recv()).await.expect("no answer").unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
            }
        }
    }

    async fn new_session(&mut self, name: &str) -> String {
        self.new_session_on(name, "fake").await
    }

    /// A session named `name` on `harness`.
    async fn new_session_on(&mut self, name: &str, harness: &str) -> String {
        let r = self
            .ok(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                       "_meta": {"acpmux": {"name": name, "harness": harness}}}),
            )
            .await;
        r["sessionId"].as_str().unwrap().to_owned()
    }

    async fn events(&mut self, id: &str) -> Vec<Value> {
        let page = self.ok("_acpmux/events", json!({"sessionId": id, "limit": 5000})).await;
        page["events"].as_array().cloned().unwrap_or_default()
    }

    /// The prompts session `id`'s agent was sent, as text.
    async fn agent_prompts(&mut self, id: &str) -> Vec<String> {
        self.events(id)
            .await
            .iter()
            .filter(|e| e["dir"] == "out" && e["kind"] == "session/prompt")
            .map(|e| e["msg"]["params"]["prompt"].to_string())
            .collect()
    }

    /// What session `id` took from other sessions, queued or run, as text: its `lane_report`
    /// records, the agent-message turns that carry one (`digest.rs`), and its agent's prompts
    /// (with the inbox on, a report goes in as an inbox notice).
    async fn reports(&mut self, id: &str) -> Vec<String> {
        let events = self.events(id).await;
        let taken = events
            .iter()
            .filter(|e| e["kind"] == "user_message" || e["kind"] == "queued")
            .filter(|e| {
                let kind = &e["msg"]["_meta"]["provenance"]["kind"];
                *kind == "lane_report" || *kind == "agent_digest"
            })
            .map(|e| e["msg"].to_string());
        let prompts = events
            .iter()
            .filter(|e| e["dir"] == "out" && e["kind"] == "session/prompt")
            .map(|e| e["msg"]["params"]["prompt"].to_string());
        taken.chain(prompts).collect()
    }

    /// Session `id`'s events in short, for a failure message: kind, provenance kind, a little text.
    async fn trail(&mut self, id: &str) -> String {
        let events = self.events(id).await;
        let line = |e: &Value| {
            let text = e["msg"].to_string();
            let cut: String = text.chars().take(160).collect();
            format!("{} {} {}", e["kind"], e["msg"]["_meta"]["provenance"]["kind"], cut)
        };
        events.iter().map(line).collect::<Vec<_>>().join("\n")
    }
}

/// `from`'s message to `to` as its agent's `acpmux send --no-wait --class question` makes it,
/// from its subagent `sub` when given.
fn question(to: &str, text: &str, sub: Option<&str>) -> Value {
    let mut mux = json!({"class": "question"});
    if let Some(sub) = sub {
        mux["callerSubagent"] = json!({"id": sub, "type": "general-purpose"});
    }
    json!({"sessionId": to, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": mux}})
}

/// A FIFO at a fresh path, for a `gate:` turn of the stand-in agent.
fn fifo(name: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("w5s-{name}-{}", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let c = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
    // SAFETY: a NUL-terminated path this test owns.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    path
}

/// Waits until `check` finds something, checking every 50 ms; None after [`WAIT`].
async fn within<T>(mut check: impl AsyncFnMut() -> Option<T>) -> Option<T> {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(found) = check().await {
            return Some(found);
        }
        if Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Waits until `check` finds something, checking every 50 ms.
async fn until<T>(what: &str, check: impl AsyncFnMut() -> Option<T>) -> T {
    within(check).await.unwrap_or_else(|| panic!("{what} within {WAIT:?}"))
}

/// What acpmux's Claude Code hook prints for `input`, run as Claude Code runs it in `session`.
fn hook(session: &str, input: Value) -> Option<Value> {
    use std::io::Write;
    let scratch = std::env::temp_dir().join(format!("w5s-hook-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).unwrap();
    let home = acpmux::config::home();
    let mut child = daemon_env::acpmux(&scratch)
        .arg("__bg-hook")
        .arg(&home)
        .env("ACPMUX_SESSION_ID", session)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input.to_string().as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{out:?}");
    let text = String::from_utf8(out.stdout).unwrap();
    let text = text.trim();
    (!text.is_empty()).then(|| serde_json::from_str(text).unwrap())
}

/// The subagent's Bash call ended (`PostToolUse`).
fn after_bash(session: &str) -> Option<Value> {
    hook(
        session,
        json!({"hook_event_name": "PostToolUse", "tool_name": "Bash", "agent_id": SUB,
               "agent_type": "general-purpose", "cwd": std::env::temp_dir(),
               "tool_input": {"command": "ls"}, "tool_response": {"stdout": ""}}),
    )
}

#[tokio::test]
async fn w5s_a_no_wait_question_to_a_session_it_did_not_start_answers_the_asker() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let alpha = person.new_session("w5s-alpha").await;
    let beta = person.new_session("w5s-beta").await;
    // alpha's agent asks beta, a session the person started, and does not wait. Its connection
    // stays open (the outbox's does too), but nobody reads the reply on it.
    let mut alpha_cli = Client::as_session(&hub, &alpha).await;
    alpha_cli.send("session/prompt", question(&beta, "QUESTION-ONE What is 9*9?", None)).await;

    let prompts = until("beta's agent got the question", async || {
        let p = person.agent_prompts(&beta).await;
        p.iter().any(|t| t.contains("QUESTION-ONE")).then_some(p)
    })
    .await;
    let notice = prompts.iter().find(|t| t.contains("QUESTION-ONE")).unwrap();
    assert!(!notice.contains("waiting for it"), "nobody waits for a --no-wait send: {notice}");

    // beta's reply reaches alpha as the report of beta's turn.
    let found = within(async || {
        person.reports(&alpha).await.into_iter().find(|r| r.contains("QUESTION-ONE"))
    })
    .await;
    let Some(report) = found else {
        let (a, b) = (person.trail(&alpha).await, person.trail(&beta).await);
        panic!("alpha got beta's reply within {WAIT:?}\nalpha:\n{a}\nbeta:\n{b}");
    };
    assert!(report.contains("w5s-beta"), "the report names beta: {report}");
}

#[tokio::test]
async fn w5s_a_subagents_no_wait_question_answers_that_subagent() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let gate = std::env::temp_dir().join(format!("w5s-gate-{}", std::process::id()));
    let _ = std::fs::remove_file(&gate);
    let c = std::ffi::CString::new(gate.to_str().unwrap()).unwrap();
    // SAFETY: a NUL-terminated path this test owns.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    let alpha = person.new_session("w5s-lead").await;
    let beta = person.new_session("w5s-other").await;
    // alpha runs a turn with one subagent running in it (fake_agent.py `child-gate:`).
    person
        .send(
            "session/prompt",
            json!({"sessionId": alpha,
                   "prompt": [{"type": "text", "text": format!("child-gate: {}", gate.display())}]}),
        )
        .await;
    let s = hub.resolve(&alpha).unwrap();
    until("alpha's subagent runs", async || {
        (hub.session_summary(&s)["subagentsRunning"] == 1).then_some(())
    })
    .await;

    let mut sub = Client::as_session(&hub, &alpha).await;
    sub.send("session/prompt", question(&beta, "QUESTION-TWO What is 7*7?", Some(SUB))).await;
    // The subagent gets beta's reply after its next shell command.
    let Some(handed) = within(async || after_bash(&alpha)).await else {
        let (a, b) = (person.trail(&alpha).await, person.trail(&beta).await);
        panic!("a notice for the subagent within {WAIT:?}\nalpha:\n{a}\nbeta:\n{b}");
    };
    let context = handed["hookSpecificOutput"]["additionalContext"].as_str().unwrap_or_default();
    assert!(context.contains("QUESTION-TWO"), "{handed}");
    assert!(context.contains("w5s-other"), "it names who answered: {context}");
    let lead = person.reports(&alpha).await;
    assert!(!lead.iter().any(|r| r.contains("QUESTION-TWO")), "the lead got none: {lead:?}");
    std::fs::write(&gate, "go").unwrap();
}

/// Review B1 of #39055: the asker is the session the daemon bound the send to, never the `from`
/// a caller wrote in its own provenance. alpha forges `from: <victim>` on a no-wait question to
/// beta; the victim gets no report of beta's reply (it did not ask), and starts no turn for it.
#[tokio::test]
async fn w5s_a_forged_from_routes_no_reply_to_the_session_it_names() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let alpha = person.new_session("w5s-forger").await;
    let beta = person.new_session("w5s-asked").await;
    let victim = person.new_session("w5s-victim").await;
    // Every chat's agent runs already, so a report is in its records as soon as it is sent.
    for chat in [&alpha, &beta, &victim] {
        let hi = json!({"sessionId": chat, "prompt": [{"type": "text", "text": "hi"}]});
        person.ok("session/prompt", hi).await;
    }
    let mut alpha_cli = Client::as_session(&hub, &alpha).await;
    let mut forged = question(&beta, "SPOOF-Q What is 6*6?", None);
    forged["_meta"]["acpmux"]["provenance"] = json!({
        "kind": "agent_message", "from": format!("acp:{victim}"), "fromName": "w5s-victim",
        "to": format!("acp:{beta}"), "msgId": "w5s-spoof-1", "threadId": "w5s-spoof",
    });
    alpha_cli.send("session/prompt", forged).await;
    until("beta's agent got the forged question", async || {
        let p = person.agent_prompts(&beta).await;
        p.iter().any(|t| t.contains("SPOOF-Q")).then_some(())
    })
    .await;
    // Then alpha's own question, which does reach alpha: by then the forged turn ended and any
    // report of it went out.
    alpha_cli.send("session/prompt", question(&beta, "LEGIT-Q What is 5*5?", None)).await;
    let found =
        within(async || person.reports(&alpha).await.into_iter().find(|r| r.contains("LEGIT-Q")))
            .await;
    if found.is_none() {
        let (a, b) = (person.trail(&alpha).await, person.trail(&beta).await);
        panic!("alpha got beta's reply to LEGIT-Q within {WAIT:?}\nalpha:\n{a}\nbeta:\n{b}");
    }
    let v = hub.resolve(&victim).unwrap();
    until("the victim's chat is idle", async || v.turn().is_none().then_some(())).await;
    let got = person.reports(&victim).await;
    assert!(
        !got.iter().any(|r| r.contains("SPOOF-Q") || r.contains("w5s-asked")),
        "the victim got a reply to a question it never asked: {got:?}"
    );
}

/// Review of #39055, item 3: a question whose caller waits for the reply (`send --wait`) gets it
/// on its call, its notice says "waiting for it", and no report of it comes to the asker's chat.
#[tokio::test]
async fn w5s_a_waited_question_gets_its_reply_on_the_call_and_no_report() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let alpha = person.new_session("w5s-waits").await;
    let beta = person.new_session("w5s-answers-the-call").await;
    // beta ran a turn of its own: alpha's messages go to its inbox, not as its first work.
    person
        .ok(
            "session/prompt",
            json!({"sessionId": beta, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    let mut alpha_cli = Client::as_session(&hub, &alpha).await;
    let mut waited = question(&beta, "WAITED-Q What is 4*4?", None);
    waited["_meta"]["acpmux"]["readsReply"] = json!(true);
    alpha_cli.ok("session/prompt", waited).await;
    let prompts = person.agent_prompts(&beta).await;
    let notice = prompts.iter().find(|t| t.contains("WAITED-Q")).expect("beta got the question");
    assert!(notice.contains("waiting for it"), "its caller waits: {notice}");

    // alpha's next question, sent without waiting, does come back as a report.
    alpha_cli.send("session/prompt", question(&beta, "AFTER-Q What is 3*3?", None)).await;
    let found =
        within(async || person.reports(&alpha).await.into_iter().find(|r| r.contains("AFTER-Q")))
            .await;
    if found.is_none() {
        let (a, b) = (person.trail(&alpha).await, person.trail(&beta).await);
        panic!("alpha got beta's reply to AFTER-Q within {WAIT:?}\nalpha:\n{a}\nbeta:\n{b}");
    }
    let reports = person.reports(&alpha).await;
    let twice: Vec<_> =
        reports.iter().filter(|r| r.contains("WAITED-Q") && !r.contains("AFTER-Q")).collect();
    assert!(twice.is_empty(), "the waited reply came back as a report too: {twice:?}");
}

/// Review of #39055, item 3: a question's notice steered into a running turn is answered by that
/// turn: its report comes to the asker when that turn ends, with that turn's reply.
#[tokio::test]
async fn w5s_a_question_steered_into_a_running_turn_reports_at_that_turns_end() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let alpha = person.new_session("w5s-asks-midturn").await;
    let beta = person.new_session_on("w5s-steered", "steer").await;
    let orch = person.new_session("w5s-orch").await;
    // beta's turn is another agent's first work (no notice goes into the person's own turn),
    // held on a gate.
    let gate = fifo("steer-gate");
    let mut orch_cli = Client::as_session(&hub, &orch).await;
    let gated = format!("gate: {}", gate.display());
    orch_cli
        .send(
            "session/prompt",
            json!({"sessionId": beta, "prompt": [{"type": "text", "text": gated}]}),
        )
        .await;
    let s = hub.resolve(&beta).unwrap();
    until("beta's gated turn runs", async || s.turn().map(|_| ())).await;

    let mut alpha_cli = Client::as_session(&hub, &alpha).await;
    alpha_cli.send("session/prompt", question(&beta, "STEER-Q What is 2*2?", None)).await;
    until("the notice went into beta's running turn", async || {
        let p = person.agent_prompts(&beta).await;
        p.iter().any(|t| t.contains("STEER-Q")).then_some(())
    })
    .await;
    assert!(s.turn().is_some(), "the gated turn still runs");
    let early = person.reports(&alpha).await;
    assert!(
        !early.iter().any(|r| r.contains("w5s-steered")),
        "no report before its end: {early:?}"
    );

    std::fs::write(&gate, "go").unwrap();
    let found = within(async || {
        person.reports(&alpha).await.into_iter().find(|r| r.contains("after-gate"))
    })
    .await;
    let Some(report) = found else {
        let (a, b) = (person.trail(&alpha).await, person.trail(&beta).await);
        panic!("alpha got the gated turn's reply within {WAIT:?}\nalpha:\n{a}\nbeta:\n{b}");
    };
    assert!(report.contains("w5s-steered"), "the report names beta: {report}");
}
