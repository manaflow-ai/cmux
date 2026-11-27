//! Restarts under load: many chats mid-turn, half waiting on a permission answer and half inside a
//! running tool call, while the daemon is stopped again and again, by an update's SIGTERM and by a
//! crash's SIGKILL. Every agent must outlive every restart (the same process, adopted each time),
//! every prompt must reach its agent once (a tool never runs twice), and every permission answer
//! must reach its agent once, also one given right before a crash and clicked again after it.
//! Counted at the agent itself (`FAKE_WIRE_LOG`), not only in the session log.

use super::*;

const CHATS: usize = 6;
const RESTARTS: usize = 4;

/// The fake agent's wire log: every line each agent read.
fn wire(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

/// How many `host_adopted` records the chat's log holds.
fn adoptions(daemon: &Daemon, session: &str) -> usize {
    daemon.events(session).iter().filter(|e| e["kind"] == "host_adopted").count()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn many_chats_mid_tool_call_survive_repeated_restarts_and_every_call_and_answer_lands_once() {
    let mut daemon = Daemon::new("xonce", "ask");
    daemon.sigterm();
    let log = daemon.home.join("wire.jsonl");
    let wire_env = format!("FAKE_WIRE_LOG={}", log.display());
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["/usr/bin/env", wire_env, "python3", FAKE]}},
               "defaultHarness": "fake", "permissionPolicy": "ask"})
        .to_string(),
    )
    .unwrap();
    daemon.start();

    // Even chats ask for a permission; odd chats run a tool call that waits on a FIFO.
    let mut chats: Vec<(String, Option<PathBuf>)> = Vec::new();
    let mut clients = Vec::new();
    for i in 0..CHATS {
        let session = new_session(&daemon).await;
        let mut client = daemon.rpc().await;
        let (text, gate) = if i % 2 == 0 {
            (format!("ask: deploy-{i}"), None)
        } else {
            let gate = daemon.home.join(format!("g{i}"));
            make_fifo(&gate);
            (format!("work-gate: {}", gate.display()), Some(gate))
        };
        client
            .send(
                "session/prompt",
                json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
                       "_meta": {"acpmux": {"promptId": format!("p-{i}")}}}),
            )
            .await;
        clients.push(client);
        chats.push((session, gate));
    }
    for (session, gate) in &chats {
        if gate.is_some() {
            daemon.wait_event(session, "the running tool call", |e| e["kind"] == "tool_call");
        } else {
            daemon.wait_event(session, "permission_request", |e| e["kind"] == "permission_request");
        }
    }
    drop(clients);
    let harness: Vec<i64> =
        chats.iter().map(|(s, _)| daemon.host_record(s)["harness_pid"].as_i64().unwrap()).collect();
    let permission = |daemon: &Daemon, session: &str| -> String {
        daemon.events(session).iter().find(|e| e["kind"] == "permission_request").unwrap()["msg"]
            ["permissionId"]
            .as_str()
            .unwrap()
            .to_owned()
    };

    for round in 0..RESTARTS {
        let last = round + 1 == RESTARTS;
        if last {
            // The person answers every ask, and the daemon crashes right behind the answers: an
            // answer may or may not have reached its agent before the kill.
            let mut rpc = daemon.rpc().await;
            for (session, gate) in &chats {
                if gate.is_none() {
                    let id = permission(&daemon, session);
                    let _ = rpc
                        .reply(
                            "_acpmux/permission_respond",
                            json!({"sessionId": session, "permissionId": id, "optionId": "no"}),
                        )
                        .await;
                }
            }
            daemon.sigkill();
        } else if round % 2 == 0 {
            daemon.sigterm();
        } else {
            daemon.sigkill();
        }
        for (i, pid) in harness.iter().enumerate() {
            assert!(alive(*pid), "restart {round}: chat {i}'s agent died with the daemon");
        }
        daemon.start();
        for (session, _) in &chats {
            let deadline = Instant::now() + Duration::from_secs(30);
            while adoptions(&daemon, session) < round + 1 {
                assert!(Instant::now() < deadline, "restart {round}: {session} never adopted");
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }

    // After the crash the person clicks every ask again, repeatedly, until each agent read an
    // answer: a click on an answered prompt, or a second copy of the cut one, must not reach the
    // agent again.
    let mut rpc = daemon.rpc().await;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let mut waiting = 0;
        for (session, gate) in &chats {
            if gate.is_some() || daemon.events(session).iter().any(|e| chunk(e, "chose no")) {
                continue;
            }
            waiting += 1;
            let id = permission(&daemon, session);
            let _ = rpc
                .reply(
                    "_acpmux/permission_respond",
                    json!({"sessionId": session, "permissionId": id, "optionId": "no"}),
                )
                .await;
        }
        if waiting == 0 {
            break;
        }
        assert!(Instant::now() < deadline, "{waiting} asks never reached their agents");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    // One more click on every answered prompt: stale, it must change nothing.
    for (session, gate) in &chats {
        if gate.is_none() {
            let id = permission(&daemon, session);
            let _ = rpc
                .reply(
                    "_acpmux/permission_respond",
                    json!({"sessionId": session, "permissionId": id, "optionId": "no"}),
                )
                .await;
        }
    }
    for (_, gate) in &chats {
        if let Some(gate) = gate {
            std::fs::write(gate, b"go").unwrap();
        }
    }
    for (session, _) in &chats {
        let result = daemon.wait_event(session, "turn_result", |e| e["kind"] == "turn_result");
        assert_eq!(result["msg"]["status"], "completed", "{session}: {result}");
    }
    // Test-only fixed wait: a late second copy would come right behind the first.
    tokio::time::sleep(Duration::from_secs(2)).await;

    let read = wire(&log);
    for (i, ((session, gate), pid)) in chats.iter().zip(&harness).enumerate() {
        let events = daemon.events(session);
        let count = |pred: &dyn Fn(&Value) -> bool| events.iter().filter(|e| pred(e)).count();
        assert!(alive(*pid), "chat {i}: its agent is gone");
        assert_eq!(
            daemon.host_record(session)["harness_pid"].as_i64(),
            Some(*pid),
            "chat {i}: a new agent replaced the one that ran the turn"
        );
        assert_eq!(adoptions(&daemon, session), RESTARTS, "chat {i}: not adopted at each restart");
        assert_eq!(count(&|e: &Value| e["kind"] == "turn_result"), 1, "chat {i}: {events:#?}");
        assert!(
            !events.iter().any(|e| e["kind"] == "auto_resume_scheduled"),
            "chat {i}: the adopted turn was resumed as a new prompt: {events:#?}"
        );
        let mine: Vec<&Value> = read.iter().filter(|l| l["pid"] == json!(pid)).collect();
        let prompts = mine.iter().filter(|l| l["method"] == "session/prompt").count();
        assert_eq!(prompts, 1, "chat {i}: its agent read the prompt {prompts} times: {mine:#?}");
        let mut answers = std::collections::HashMap::<String, usize>::new();
        for l in mine.iter().filter(|l| l["method"].is_null()) {
            *answers.entry(l["id"].to_string()).or_default() += 1;
        }
        assert!(
            answers.values().all(|n| *n == 1),
            "chat {i}: its agent read an answer more than once: {answers:?}"
        );
        if gate.is_some() {
            let tool = |status: &str| {
                count(&|e: &Value| {
                    e["kind"] == "tool_call_update"
                        && e["msg"].pointer("/params/update/toolCallId") == Some(&json!("wg-1"))
                        && e["msg"].pointer("/params/update/status") == Some(&json!(status))
                })
            };
            assert_eq!(
                count(&|e: &Value| e["kind"] == "tool_call"
                    && e["msg"].pointer("/params/update/toolCallId") == Some(&json!("wg-1"))),
                1,
                "chat {i}: its tool call started again: {events:#?}"
            );
            assert_eq!(tool("completed"), 1, "chat {i}: {events:#?}");
            assert_eq!(count(&|e: &Value| chunk(e, "worked")), 1, "chat {i}: {events:#?}");
        } else {
            assert_eq!(answers.len(), 1, "chat {i}: not one answered ask: {answers:?}");
            assert_eq!(count(&|e: &Value| chunk(e, "chose no")), 1, "chat {i}: {events:#?}");
        }
    }
}

/// The coordinator path uses the real CLI as its waiting client.  Keep this larger than the
/// unit-sized restart test above: twenty sends are admitted concurrently, then the daemon is
/// handed off five times while every harness is blocked in a turn.  The child CLI processes are
/// intentionally left attached to the original socket path; a durable send must reconnect after
/// each replacement and finish the original prompt id exactly once.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn twenty_cli_sends_survive_five_daemon_restarts_without_loss_or_duplication() {
    const SENDS: usize = 20;
    const RESTARTS: usize = 5;
    let mut daemon = Daemon::new("cli-duress", "approve-all");

    let mut sessions = Vec::with_capacity(SENDS);
    let mut children = Vec::with_capacity(SENDS);
    for i in 0..SENDS {
        let name = format!("cli-duress-{i}");
        let made = std::process::Command::new(daemon_env::bin())
            .args(["--json", "new", "-d", "-n", &name, "-m", "fake"])
            .env_clear()
            .envs(daemon_env::vars(&daemon.home, daemon_env::Agents::StandIn, &[]))
            .env("ACPMUX_HOME", &daemon.home)
            .env("ACPMUX_SOCKET", &daemon.socket)
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .output()
            .expect("new CLI");
        assert!(made.status.success(), "new {name}: {}", String::from_utf8_lossy(&made.stderr));
        let value: Value = serde_json::from_slice(&made.stdout).expect("new JSON");
        let session = value["sessionId"].as_str().expect("new session id").to_owned();
        let gate = daemon.home.join(format!("cli-gate-{i}"));
        make_fifo(&gate);
        let mut send = std::process::Command::new(daemon_env::bin());
        send.args([
            "--json",
            "send",
            &name,
            "--timeout",
            "180",
            "--prompt-id",
            &format!("cli-duress-prompt-{i}"),
            &format!("gate: {}", gate.display()),
        ])
        .env_clear()
        .envs(daemon_env::vars(&daemon.home, daemon_env::Agents::StandIn, &[]))
        .env("ACPMUX_HOME", &daemon.home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
        children.push(send.spawn().expect("send CLI"));
        sessions.push((session, gate));
    }

    for (session, _) in &sessions {
        daemon.wait_event(session, "CLI send before-gate", |e| chunk(e, "before-gate"));
    }
    for _ in 0..RESTARTS {
        daemon.sigterm();
        daemon.start();
        for (session, _) in &sessions {
            daemon.wait_event(session, "host adopted after CLI restart", |e| {
                e["kind"] == "host_adopted"
            });
        }
    }
    for (_, gate) in &sessions {
        std::fs::write(gate, b"go").expect("release FIFO");
    }

    let mut ok = 0;
    let mut lost = Vec::new();
    let mut duplicated = Vec::new();
    for (i, mut child) in children.into_iter().enumerate() {
        let output = child.wait_with_output().expect("wait CLI send");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        if output.status.success() {
            ok += 1;
        } else {
            lost.push(format!("{i}: status={} stdout={stdout} stderr={stderr}", output.status));
        }
        let events = daemon.events(&sessions[i].0);
        let starts = events.iter().filter(|e| e["kind"] == "turn_started").count();
        let results = events.iter().filter(|e| e["kind"] == "turn_result").count();
        if starts != 1 || results != 1 {
            duplicated.push(format!("{i}: starts={starts} results={results}"));
        }
    }
    eprintln!(
        "DURESS cli_sends={SENDS} restarts={RESTARTS} completed={ok} lost={} duplicated={}",
        lost.len(),
        duplicated.len()
    );
    assert!(lost.is_empty(), "lost CLI sends: {lost:?}");
    assert!(duplicated.is_empty(), "duplicated CLI sends: {duplicated:?}");
    assert_eq!(ok, SENDS, "not every CLI send completed");
}
