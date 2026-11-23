//! A chat moved back and forth between two machines while its turn runs, by the real CLI on both
//! sides. Leo, 2026-11-23: "if it can "move to cloud" in the BACKEND but i still am able to
//! interact with it with no percievable lag or whatever here ... that's gold." A move that loses
//! a message, a tool call's result or a queued prompt is not one a person can leave to a machine.
//!
//! Both daemons are real and each is the other's ssh peer `target` (the stand-in `ssh` of
//! `session_move.rs`). The agent works in steps until told to end (`FAKE_STEPS_IN`), so every hop
//! finds a running turn; what it finished is counted at the agent itself (`FAKE_STEP_LOG`,
//! `FAKE_WIRE_LOG`), not only in the chat's log.
use super::session_move::prompt;
use super::*;
use std::collections::BTreeMap;

const HOPS: usize = 10;

/// One side of the pair: its daemon and the folder the chat gets there.
struct Side {
    daemon: Daemon,
    folder: PathBuf,
}

async fn pair(tag: &str, logs: &Path) -> [Side; 2] {
    let (a, b) = (format!("{tag}a"), format!("{tag}b"));
    let env = json!({
        // The continuation a move leaves is the turn going on: it works in steps again.
        "FAKE_STEPS_IN": "This chat moved",
        "FAKE_STEP_LOG": logs.join("steps"),
        "FAKE_STEPS_END": logs.join("end"),
        "FAKE_WIRE_LOG": logs.join("wire"),
    });
    let first = Daemon::spawn(&a, Some(Daemon::place(&b)), env.clone()).await;
    let second = Daemon::spawn(&b, Some(Daemon::place(&a)), env).await;
    [first, second].map(|daemon| {
        let folder = daemon.home.join("project");
        std::fs::create_dir(&folder).unwrap();
        Side { daemon, folder }
    })
}

async fn events(rpc: &mut Rpc, id: &str) -> Vec<Value> {
    let page =
        rpc.call("_acpmux/events", json!({"sessionId": id, "afterSeq": 0, "limit": 5000})).await;
    let events = page["events"].as_array().unwrap().clone();
    assert!(events.len() < 5000, "the whole log fits one page");
    events
}

/// The chat's steps in log order: each tool call's id with how many times it was announced and
/// how many times its result came.
fn steps(events: &[Value]) -> Vec<(String, usize, usize)> {
    let mut order = Vec::new();
    let mut seen: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for event in events {
        let update = &event["msg"]["params"]["update"];
        let Some(call) = update["toolCallId"].as_str() else { continue };
        if !seen.contains_key(call) {
            order.push(call.to_owned());
        }
        let count = seen.entry(call.to_owned()).or_default();
        match event["kind"].as_str() {
            Some("tool_call") => count.0 += 1,
            Some("tool_call_update") if update["status"] == "completed" => count.1 += 1,
            _ => {}
        }
    }
    order.into_iter().map(|call| (call.clone(), seen[&call].0, seen[&call].1)).collect()
}

async fn move_to_the_other(from: &Side, to: &Side, id: &str, mode: &[&str]) -> Duration {
    let mut command = daemon_env::tokio_command(&from.daemon.home, daemon_env::Agents::Deny);
    command
        .args(["--json", "session", "move", id, "--machine", "target"])
        .args(mode)
        .arg("--cwd")
        .arg(&to.folder)
        .env(
            "PATH",
            format!("{}:{}", from.daemon.home.join("bin").display(), daemon_env::bare_path(&[])),
        )
        .env("ACPMUX_HOME", &from.daemon.home)
        .env("ACPMUX_SOCKET", &from.daemon.socket)
        .kill_on_drop(true);
    let started = std::time::Instant::now();
    let out = tokio::time::timeout(Duration::from_secs(90), command.output())
        .await
        .expect("session move completed")
        .expect("run session move");
    let took = started.elapsed();
    assert!(
        out.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let receipt: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(receipt["moves"][0]["moved"], true, "{receipt}");
    assert_eq!(receipt["moves"][0]["targetSessionId"], id, "the chat keeps its id: {receipt}");
    took
}

/// `HOPS` moves under a running turn, a prompt queued and the draft rewritten before each one.
async fn there_and_back(tag: &str, mode: &[&str]) {
    let logs = tempfile::tempdir().unwrap();
    let sides = pair(tag, logs.path()).await;
    let mut here = Rpc::connect(&sides[0].daemon.socket).await;
    let made = here.call("session/new", json!({"cwd": sides[0].folder, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    here.call("session/prompt", prompt(&id, "p-hi", "hi")).await;
    here.send_prompt(&id, "p-turn", "steps").await;
    here.notification("session/update", |p| p["update"]["sessionUpdate"] == "tool_call").await;

    let mut took = Vec::new();
    for hop in 1..=HOPS {
        let (from, to) = (&sides[(hop - 1) % 2], &sides[hop % 2]);
        // What a person does while the agent works: sends a prompt, leaves words in the box.
        let queued = format!("q-{hop}");
        here.send_prompt(&id, &queued, &format!("queued {hop}")).await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        loop {
            let info = here.call("_acpmux/info", json!({"sessionId": id})).await;
            let waiting = info["queue"].as_array().into_iter().flatten();
            if waiting.clone().any(|q| q["promptId"] == queued.as_str()) {
                assert_eq!(waiting.count(), hop, "every prompt sent so far still waits: {info}");
                break;
            }
            assert!(tokio::time::Instant::now() < deadline, "hop {hop}: {queued} never queued");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let draft = json!({"sessionId": id, "text": format!("draft {hop}")});
        here.call("_acpmux/draft_set", draft).await;

        took.push(move_to_the_other(from, to, &id, mode).await);

        // What the source held when it let go is all there, in order, and the turn goes on.
        let left = events(&mut here, &id).await;
        let mut there = Rpc::connect(&to.daemon.socket).await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        let arrived = loop {
            let arrived = events(&mut there, &id).await;
            let info = there.call("_acpmux/info", json!({"sessionId": id})).await;
            let prompts = arrived.iter().filter(|e| e["kind"] == "user_message").count();
            if prompts == 2 + hop
                && info["turn"]["turnId"].is_string()
                && steps(&arrived).len() > steps(&left).len()
            {
                break arrived;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "hop {hop}: the turn never went on there: {prompts} prompts, {info}"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        };
        let (had, has) = (steps(&left), steps(&arrived));
        assert_eq!(has[..had.len()], had[..], "hop {hop}: the steps the source held");
        let closed = here.call("_acpmux/info", json!({"sessionId": id})).await;
        assert_eq!(closed["status"], "closed", "hop {hop}: one home at a time: {closed}");
        assert_eq!(closed["movedTo"]["host"], "target", "hop {hop}: {closed}");
        let kept = there.call("_acpmux/draft_get", json!({"sessionId": id})).await;
        assert_eq!(kept["draft"], format!("draft {hop}"), "hop {hop}");
        here = there;
    }

    // The agent ends its turn; the ten prompts sent on the way run, each once, in order.
    std::fs::write(logs.path().join("end"), "").unwrap();
    let ready = here
        .call(
            "_acpmux/wait",
            json!({"sessions": [id], "until": ["ready"], "all": true, "timeoutMs": 60000}),
        )
        .await;
    assert_eq!(ready["timedOut"], false, "the moved queue finished: {ready}");
    let prompts = here.texts(&id, "user_message").await;
    assert_eq!(
        prompts.len(),
        2 + 2 * HOPS,
        "history, a continuation a hop, the queue: {prompts:?}"
    );
    assert_eq!(prompts[..2], ["hi", "steps"]);
    for moved in &prompts[2..2 + HOPS] {
        assert!(moved.starts_with("This chat moved to another machine"), "{prompts:?}");
    }
    let sent: Vec<String> = (1..=HOPS).map(|hop| format!("queued {hop}")).collect();
    assert_eq!(prompts[2 + HOPS..], sent[..], "each queued prompt runs once, in order");
    let replies = here.texts(&id, "agent_message_chunk").await;
    for text in &sent {
        let echo = format!("echo: {text}");
        assert_eq!(replies.iter().filter(|r| **r == echo).count(), 1, "{echo}: {replies:?}");
    }

    // Counted at the agents: every step either agent finished is in the chat once with its
    // result, and each prompt reached an agent once (two, a continuation a hop, the queue).
    let log = events(&mut here, &id).await;
    let in_chat: BTreeMap<String, (usize, usize)> =
        steps(&log).into_iter().map(|(call, announced, done)| (call, (announced, done))).collect();
    let finished = std::fs::read_to_string(logs.path().join("steps")).unwrap();
    assert!(finished.lines().count() >= HOPS, "the turn worked on every machine: {finished}");
    for call in finished.lines() {
        assert_eq!(in_chat.get(call), Some(&(1, 1)), "step {call}, finished at the agent");
    }
    let wire = std::fs::read_to_string(logs.path().join("wire")).unwrap();
    let reached = wire
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|line| line["method"] == "session/prompt")
        .count();
    assert_eq!(reached, 2 + 2 * HOPS, "each prompt reached an agent once");

    took.sort();
    eprintln!(
        "session move {mode:?} x{HOPS} under a live turn: median {:?}, slowest {:?}, {} steps",
        took[HOPS / 2],
        took[HOPS - 1],
        finished.lines().count()
    );
}

/// The default move: it waits for the running tool call's result, then takes the turn along.
#[tokio::test]
async fn ten_moves_between_tool_calls_lose_no_message_step_or_queued_prompt() {
    there_and_back("lv", &[]).await;
}

/// `--interrupt` stops the turn where it is; what the agent finished before it stopped moves.
#[tokio::test]
async fn ten_interrupting_moves_lose_no_message_step_or_queued_prompt() {
    there_and_back("li", &["--interrupt"]).await;
}
