//! One connection keeps its chat across a move. Leo, 2026-11-23: "if you can percievably have
//! literally the same "VIEW" of the session ongoing, the gui or whatever, but instead of the
//! thing running on your computer, it's running on a vm... that's gold."
//!
//! Two real daemons, each the other's ssh peer `target` (`session_move_live.rs`). A client is
//! connected to the first only, attached to a chat whose turn works in steps. The chat is moved
//! to the second daemon and back by the CLI. The client does nothing about either move: it
//! reads its one socket and sends on it, with the chat's bare id.
use super::session_move::prompt;
use super::session_move_live::{Side, events, move_to_the_other};
use super::*;

/// The two machines, each with a live link to the other (its peer `target`), as two machines
/// of one person have.
async fn pair(tag: &str, logs: &Path) -> [Side; 2] {
    let (a, b) = (format!("{tag}a"), format!("{tag}b"));
    let env = json!({
        // The continuation a move leaves is the turn going on: it works in steps again.
        "FAKE_STEPS_IN": "This chat moved",
        "FAKE_STEP_LOG": logs.join("steps"),
        "FAKE_STEPS_END": logs.join("end"),
        "FAKE_WIRE_LOG": logs.join("wire"),
    });
    let first = Daemon::spawn_with(&a, Some(Daemon::place(&b)), env.clone(), true).await;
    let second = Daemon::spawn_with(&b, Some(Daemon::place(&a)), env, true).await;
    let sides = [first, second].map(|daemon| {
        let folder = daemon.home.join("project");
        std::fs::create_dir(&folder).unwrap();
        Side { daemon, folder }
    });
    // Both links are up before the chat moves: a peer that is down is not followed.
    for side in &sides {
        let mut rpc = Rpc::connect(&side.daemon.socket).await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        loop {
            let peers = rpc.call("_acpmux/peers", json!({})).await;
            if peers.to_string().contains("\"connected\":true") {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline, "no link to the peer: {peers}");
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
    sides
}

/// What one connection was sent of one chat: each record's seq, in the order it came.
struct Seen {
    id: String,
    seqs: Vec<u64>,
    /// The agent process of the last tool call seen (`step-PID-N`).
    pid: String,
}

impl Seen {
    fn note(&mut self, message: &Value) {
        let params = &message["params"];
        if params["sessionId"] != self.id.as_str() {
            return;
        }
        let seq = match message["method"].as_str() {
            Some("session/update") => params.pointer("/_meta/acpmux/seq"),
            Some("_acpmux/event") => params.get("seq"),
            _ => return,
        };
        let seq = seq.and_then(Value::as_u64).unwrap_or_else(|| panic!("no seq: {message}"));
        // The chat looks as it did before it moved: no peer, no second id.
        assert!(params.get("peer").is_none(), "{message}");
        assert!(params.get("qualifiedSessionId").is_none(), "{message}");
        self.seqs.push(seq);
        if let Some(call) = params.pointer("/update/toolCallId").and_then(Value::as_str) {
            self.pid = call.split('-').nth(1).unwrap_or("").to_owned();
        }
    }
}

async fn line(rpc: &mut Rpc, wait: Duration) -> Option<Value> {
    let line = tokio::time::timeout(wait, rpc.lines.next_line()).await.ok()?;
    Some(serde_json::from_str(&line.expect("read").expect("daemon connected")).expect("json"))
}

/// A request on the connection, with every notification that comes before its answer kept.
async fn call(rpc: &mut Rpc, seen: &mut Seen, method: &str, params: Value) -> Value {
    rpc.next += 1;
    let id = rpc.next;
    let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
    rpc.wr.write_all(format!("{request}\n").as_bytes()).await.expect("send");
    loop {
        let message = line(rpc, Duration::from_secs(30))
            .await
            .unwrap_or_else(|| panic!("{method} was not answered"));
        if message.get("id") == Some(&json!(id)) {
            assert!(message.get("error").is_none(), "{method} failed: {message}");
            return message["result"].clone();
        }
        seen.note(&message);
    }
}

/// Reads the connection until `done` holds of what was seen.
async fn until(rpc: &mut Rpc, seen: &mut Seen, what: &str, done: impl Fn(&Seen) -> bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while !done(seen) {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        let message = line(rpc, left).await.unwrap_or_else(|| {
            let last = &seen.seqs[seen.seqs.len().saturating_sub(12)..];
            panic!("never: {what}; the last seqs that came: {last:?}")
        });
        seen.note(&message);
    }
}

/// Ends the running turn through the connection and waits until the chat has none.
async fn cancel(rpc: &mut Rpc, seen: &mut Seen) {
    let id = seen.id.clone();
    let note = json!({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": id}});
    rpc.wr.write_all(format!("{note}\n").as_bytes()).await.expect("send");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let info = call(rpc, seen, "_acpmux/info", json!({"sessionId": id})).await;
        if !info["turn"]["turnId"].is_string() {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "the turn was not cancelled: {info}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn count(texts: &[String], text: &str) -> usize {
    texts.iter().filter(|t| *t == text).count()
}

#[tokio::test]
async fn session_move_is_followed_by_a_connection_attached_at_its_source() {
    let logs = tempfile::tempdir().unwrap();
    let sides = pair("fw", logs.path()).await;
    let (home, away) = (&sides[0], &sides[1]);
    let mut rpc = Rpc::connect(&home.daemon.socket).await;
    let made = rpc.call("session/new", json!({"cwd": home.folder, "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let mut seen = Seen { id: id.clone(), seqs: Vec::new(), pid: String::new() };
    call(&mut rpc, &mut seen, "session/prompt", prompt(&id, "p-hi", "hi")).await;
    rpc.send_prompt(&id, "p-turn", "steps").await;
    until(&mut rpc, &mut seen, "the turn's first step", |s| !s.pid.is_empty()).await;

    // There: the chat moves to the other machine while its turn works.
    let draft = json!({"sessionId": id, "text": "draft at home"});
    call(&mut rpc, &mut seen, "_acpmux/draft_set", draft).await;
    let first = seen.pid.clone();
    move_to_the_other(home, away, &id, &[]).await;
    // The turn goes on there, and its steps come on the connection that never left.
    until(&mut rpc, &mut seen, "a step of the agent on the other machine", |s| s.pid != first)
        .await;
    let there = seen.pid.clone();
    let mut direct = Rpc::connect(&away.daemon.socket).await;
    let info = call(&mut rpc, &mut seen, "_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["status"], "closed", "the chat's own row, not its tombstone: {info}");
    assert!(info["turn"]["turnId"].is_string(), "its turn runs there: {info}");
    let kept = call(&mut rpc, &mut seen, "_acpmux/draft_get", json!({"sessionId": id})).await;
    assert_eq!(kept["draft"], "draft at home");
    let draft = json!({"sessionId": id, "text": "draft while away"});
    call(&mut rpc, &mut seen, "_acpmux/draft_set", draft).await;
    let theirs = direct.call("_acpmux/draft_get", json!({"sessionId": id})).await;
    assert_eq!(theirs["draft"], "draft while away", "the draft is the chat's, where it is");
    cancel(&mut rpc, &mut seen).await;
    let answer = call(&mut rpc, &mut seen, "session/prompt", prompt(&id, "p-away", "away")).await;
    assert_eq!(answer["stopReason"], "end_turn", "{answer}");
    assert_eq!(count(&direct.texts(&id, "user_message").await, "away"), 1);
    assert_eq!(count(&direct.texts(&id, "agent_message_chunk").await, "echo: away"), 1);

    // And back, under a running turn again.
    rpc.send_prompt(&id, "p-turn-2", "steps").await;
    let before = seen.seqs.len();
    until(&mut rpc, &mut seen, "a step of the second turn", |s| s.seqs.len() > before + 2).await;
    assert_eq!(seen.pid, there, "the second turn runs where the chat is");
    move_to_the_other(away, home, &id, &[]).await;
    until(&mut rpc, &mut seen, "a step of the agent at home again", |s| s.pid != there).await;
    let info = call(&mut rpc, &mut seen, "_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(info["status"], "closed", "{info}");
    assert!(info["movedTo"].is_null(), "the chat is here again: {info}");
    let kept = call(&mut rpc, &mut seen, "_acpmux/draft_get", json!({"sessionId": id})).await;
    assert_eq!(kept["draft"], "draft while away");
    cancel(&mut rpc, &mut seen).await;
    let answer = call(&mut rpc, &mut seen, "session/prompt", prompt(&id, "p-home", "home")).await;
    assert_eq!(answer["stopReason"], "end_turn", "{answer}");
    // One home at a time: the other machine's connection is answered by the chat here too.
    let here = call(&mut rpc, &mut seen, "_acpmux/info", json!({"sessionId": id})).await;
    let gone = direct.call("_acpmux/info", json!({"sessionId": id})).await;
    assert_ne!(gone["status"], "closed", "{gone}");
    assert_eq!(gone["cwd"], here["cwd"], "{gone}");
    assert_eq!(gone["createdAt"], here["createdAt"], "{gone}");

    // Quiet: whatever was still on its way has come.
    while let Some(message) = line(&mut rpc, Duration::from_secs(1)).await {
        seen.note(&message);
    }
    let log = events(&mut rpc, &id).await;
    let texts = |kind: &str| -> Vec<String> {
        log.iter()
            .filter(|e| e["kind"] == kind)
            .filter_map(|e| {
                let msg = &e["msg"];
                msg["text"]
                    .as_str()
                    .or_else(|| msg.pointer("/params/update/content/text")?.as_str())
            })
            .map(str::to_owned)
            .collect()
    };
    for text in ["away", "home"] {
        assert_eq!(count(&texts("user_message"), text), 1, "{text} is in the chat once");
        let echo = format!("echo: {text}");
        assert_eq!(count(&texts("agent_message_chunk"), &echo), 1, "{echo}");
    }
    // Nothing reached an agent twice: the two machines' agents write one wire log, a line for
    // each prompt an agent read, and the chat holds as many prompts.
    let wire = std::fs::read_to_string(logs.path().join("wire")).unwrap();
    let reached = wire
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|line| line["method"] == "session/prompt")
        .count();
    assert_eq!(reached, texts("user_message").len(), "{:?}", texts("user_message"));

    // Every record of the chat a connection is sent (the agent's updates, the daemon's own)
    // came on this one once, in order, across both moves.
    for pair in seen.seqs.windows(2) {
        assert!(pair[0] < pair[1], "seq {} came after {}: {:?}", pair[1], pair[0], seen.seqs);
    }
    let sent: Vec<u64> = log
        .iter()
        .filter(|e| {
            e["dir"] == "mux"
                || (e["dir"] == "in"
                    && e["msg"]["method"] == "session/update"
                    && !e["kind"].as_str().unwrap_or("").ends_with(".replay"))
        })
        .filter_map(|e| e["seq"].as_u64())
        // From the first this test kept: what came while the chat was made was not kept.
        .filter(|seq| *seq >= seen.seqs[0])
        .collect();
    assert!(sent.len() > 40, "both moves and their turns are in it: {sent:?}");
    let missing: Vec<&u64> = sent.iter().filter(|seq| !seen.seqs.contains(seq)).collect();
    let extra: Vec<&u64> = seen.seqs.iter().filter(|seq| !sent.contains(seq)).collect();
    assert!(
        missing.is_empty() && extra.is_empty(),
        "never came: {missing:?}; not the chat's: {extra:?}"
    );
}
