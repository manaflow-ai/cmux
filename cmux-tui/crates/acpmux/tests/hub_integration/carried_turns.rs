//! A turn ends when its agent ends it (Leo, 2026-10-29: "why the fuck are you still depicted as
//! thinking for 11 hours? This feels like we're not reading the data correctly. Because you're,
//! like, you clearly just ended some fucking turns, and it still fucking shows this."). A steer
//! Claude Code reads after its turn ended starts a new turn, with its own turnId and startedAt;
//! one it reads during its turn joins that turn. codex-acp folds steers into its turn, as before.
//! fake_claude.py's "gated: PATH" ends each of its turns on a gate file (`hub/carried_turn.rs`).

use super::*;

async fn claude_hub() -> (Arc<Hub>, TestClient, String) {
    claude_hub_with_inbox(true).await
}

/// [`claude_hub`], with the agent inbox (`hub/inbox.rs`) on or off: off, another agent's plain
/// message takes the queue path as before the inbox.
async fn claude_hub_with_inbox(agent_inbox: bool) -> (Arc<Hub>, TestClient, String) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let home = std::env::temp_dir().join(format!("carried-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&home).unwrap();
    let env =
        BTreeMap::from([("CLAUDE_CONFIG_DIR".to_owned(), home.to_string_lossy().into_owned())]);
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("claude".to_owned(), profile)]),
        default_harness: Some("claude".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.agent_inbox = Some(agent_inbox);
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut c = connect(&hub).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    (hub, c, id)
}

fn prompt(id: &str, prompt_id: &str, text: &str, steer: bool) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "steer": steer}}})
}

/// The gate files of one "gated" turn run.
struct Gates(std::path::PathBuf);

impl Gates {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!("carried-gate-{}", uuid::Uuid::now_v7())))
    }
    fn text(&self) -> String {
        format!("gated: {}", self.0.display())
    }
    /// Ends Claude Code's turn `n`: "end" first, or "read" (the waiting lines in the turn).
    fn open(&self, n: u32, how: &str) {
        let tmp = self.0.with_extension(format!("{n}.tmp"));
        std::fs::write(&tmp, how).unwrap();
        std::fs::rename(&tmp, format!("{}.{n}", self.0.display())).unwrap();
    }
}

/// Steers `text` from its own connection, once Claude Code's stdin has it; returns that
/// connection and the request id.
async fn steer_in(hub: &Arc<Hub>, id: &str, prompt_id: &str, text: &str) -> (TestClient, i64) {
    let mut a = connect(hub).await;
    let request = a.send(method::SESSION_PROMPT, prompt(id, prompt_id, text, true)).await;
    let accepted = a.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == prompt_id).await;
    assert_eq!(accepted["steer"], true, "{accepted}");
    let written = |e: &acpmux::store::EventRecord| {
        e.kind == "claude.stdin" && e.msg.to_string().contains(text)
    };
    for _ in 0..400 {
        if hub.events(id, 0, 10_000).unwrap().iter().any(written) {
            return (a, request);
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("{text} never reached Claude Code");
}

fn records(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    let events = hub.events(id, 0, 10_000).unwrap();
    events.iter().filter(|e| e.dir == "mux" && e.kind == kind).map(|e| e.msg.clone()).collect()
}

/// Waits until the session logged `n` `turn_started` records; returns them.
async fn started(hub: &Hub, id: &str, n: usize) -> Vec<Value> {
    for _ in 0..400 {
        let got = records(hub, id, "turn_started");
        if got.len() >= n {
            return got;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("never {n} turns: {:#?}", records(hub, id, "turn_started"));
}

async fn info(c: &mut TestClient, id: &str) -> Value {
    c.request(method::MUX_INFO, json!({"sessionId": id, "waitLogs": false})).await.unwrap()
}

#[tokio::test]
async fn a_steer_claude_reads_after_end_turn_starts_a_new_turn() {
    let (hub, mut c, id) = claude_hub().await;
    let gates = Gates::new();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", &gates.text(), false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "gated turn 1").await;
    let first = info(&mut c, &id).await["turn"].clone();
    let (mut a, steer) = steer_in(&hub, &id, "p-late", "LATE-1").await;
    gates.open(1, "end");
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn", "the prompt's turn ended with Claude's");
    let turns = started(&hub, &id, 2).await;
    let (one, two) = (&turns[0], &turns[1]);
    assert_ne!(one["turnId"], two["turnId"], "{turns:#?}");
    assert_eq!(two["promptId"], "p-late", "{two}");
    assert_eq!(two["carried"]["fromTurnId"], one["turnId"], "{two}");
    let ended = records(&hub, &id, "turn_result");
    assert_eq!(ended.len(), 1, "{ended:#?}");
    assert_eq!(ended[0]["turnId"], one["turnId"]);
    // The running turn is the new one: its own id and start.
    let now = info(&mut c, &id).await["turn"].clone();
    assert_eq!(now["turnId"], two["turnId"], "{now}");
    assert!(now["startedAt"].as_u64() > first["startedAt"].as_u64(), "{first} then {now}");
    // The steer went into the new turn, and says so.
    let (read, _) = a.response(steer).await;
    let read = read.unwrap();
    assert_eq!(read["stopReason"], "steered", "{read}");
    assert_eq!(read["_meta"]["acpmux"]["turnId"], two["turnId"], "{read}");
    gates.open(2, "read");
    for _ in 0..400 {
        if records(&hub, &id, "turn_result").len() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let ended = records(&hub, &id, "turn_result");
    assert_eq!(ended.len(), 2, "{ended:#?}");
    assert_eq!(ended[1]["turnId"], two["turnId"]);
    assert_eq!(ended[1]["status"], "completed", "{}", ended[1]);
    assert!(info(&mut c, &id).await.get("turn").is_none_or(Value::is_null));
    assert_eq!(records(&hub, &id, "turn_started").len(), 2);
    // What Claude said in the new turn is logged in it: after the first turn's end and the new
    // turn's start, before its end (`reply_of_turn` reads a turn's reply between those).
    let events = hub.events(&id, 0, 10_000).unwrap();
    let mux = |kind: &str, n: usize| {
        let mut of = events.iter().filter(|e| e.dir == "mux" && e.kind == kind);
        of.nth(n).unwrap_or_else(|| panic!("no {kind} {n}")).seq
    };
    let said = events
        .iter()
        .find(|e| e.dir == "in" && e.msg.to_string().contains("read: LATE-1"))
        .expect("Claude's words in the new turn are logged")
        .seq;
    assert!(said > mux("turn_result", 0), "logged in the turn that ended");
    assert!(said > mux("turn_started", 1) && said < mux("turn_result", 1), "not in its turn");
}

/// Claude ends turn after turn while steers keep coming: each is a turn of the daemon's.
#[tokio::test]
async fn turns_claude_ends_while_steers_keep_coming_are_separate_turns() {
    let (hub, mut c, id) = claude_hub().await;
    let gates = Gates::new();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", &gates.text(), false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "gated turn 1").await;
    let mut steers = Vec::new();
    for n in 1..=3u32 {
        let text = format!("STEER-{n}");
        steers.push((n, steer_in(&hub, &id, &format!("p-{n}"), &text).await));
        gates.open(n, "end");
        started(&hub, &id, n as usize + 1).await;
    }
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    gates.open(4, "end");
    for _ in 0..400 {
        if records(&hub, &id, "turn_result").len() == 4 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let turns = records(&hub, &id, "turn_started");
    let ended = records(&hub, &id, "turn_result");
    assert_eq!(turns.len(), 4, "{turns:#?}");
    assert_eq!(ended.len(), 4, "{ended:#?}");
    let mut ids: Vec<&Value> = turns.iter().map(|t| &t["turnId"]).collect();
    ids.dedup();
    assert_eq!(ids.len(), 4, "each turn its own id: {turns:#?}");
    for (t, e) in turns.iter().zip(&ended) {
        assert_eq!(t["turnId"], e["turnId"], "each turn ends before the next starts");
        assert_eq!(e["status"], "completed", "{e}");
    }
    // Each steer went into the turn it started, and each was answered once.
    for (n, (mut a, request)) in steers {
        let (read, _) = a.response(request).await;
        let read = read.unwrap();
        assert_eq!(read["stopReason"], "steered", "{read}");
        assert_eq!(read["_meta"]["acpmux"]["turnId"], turns[n as usize]["turnId"], "{read}");
    }
    assert!(info(&mut c, &id).await.get("turn").is_none_or(Value::is_null));
    assert_eq!(
        hub.events(&id, 0, 10_000).unwrap().iter().filter(|e| e.kind == "user_message").count(),
        4
    );
}

/// A steer Claude reads during its turn joins it: one turn.
#[tokio::test]
async fn a_steer_read_during_the_turn_joins_it() {
    let (hub, mut c, id) = claude_hub().await;
    let gates = Gates::new();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", &gates.text(), false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "gated turn 1").await;
    let (mut a, steer) = steer_in(&hub, &id, "p-joins", "JOINS").await;
    gates.open(1, "read");
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let turns = records(&hub, &id, "turn_started");
    assert_eq!(turns.len(), 1, "{turns:#?}");
    let (read, _) = a.response(steer).await;
    let read = read.unwrap();
    assert_eq!(read["stopReason"], "steered", "{read}");
    assert_eq!(read["_meta"]["acpmux"]["turnId"], turns[0]["turnId"], "{read}");
}

/// codex-acp folds steers into the running turn and answers them all at its end: one turn.
#[tokio::test]
async fn a_codex_turn_that_took_steers_stays_one_turn() {
    let env = BTreeMap::from([("FAKE_CODEX_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", "work", false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["update"]["content"]["text"].as_str().is_some_and(|t| t.starts_with("turn: "))
    })
    .await;
    let first = c.send(method::SESSION_PROMPT, prompt(&id, "p-1", "more", true)).await;
    let second = c.send(method::SESSION_PROMPT, prompt(&id, "p-2", "and more", true)).await;
    let mut answered = BTreeMap::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while answered.len() < 3 {
        let line = tokio::time::timeout_at(deadline, c.rx.recv()).await.expect("unanswered");
        if let Message::Response { id: rid, result, .. } =
            Message::parse(&line.expect("closed")).unwrap()
            && let Some(rid) = rid.as_i64()
        {
            answered.insert(rid, result);
        }
    }
    for rid in [turn, first, second] {
        let reason = answered[&rid].as_ref().map(|r| r["stopReason"].clone());
        assert_eq!(reason, Some(json!("end_turn")), "prompt {rid}");
    }
    assert_eq!(records(&hub, &id, "turn_started").len(), 1);
    assert_eq!(records(&hub, &id, "turn_result").len(), 1);
}

/// Stop while Claude Code runs a carried turn and never answers the interrupt: acpmux ends that
/// turn itself, and a steer still unread in it, sent into the turn before, is answered too
/// (`steer_end.rs` follows the carried turns).
#[tokio::test]
async fn a_forced_stop_of_a_carried_turn_answers_its_unread_steers() {
    let (hub, mut c, id) = claude_hub().await;
    let gates = Gates::new();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", &gates.text(), false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "gated turn 1").await;
    let (mut a, first) = steer_in(&hub, &id, "p-1", "ONE").await;
    let (mut b, second) = steer_in(&hub, &id, "p-2", "TWO").await;
    gates.open(1, "end-first");
    let (answer, _) = c.response(turn).await;
    let answer = answer.unwrap();
    assert_eq!(answer["_meta"]["claude"]["carried"]["promptIds"], json!(["p-1", "p-2"]));
    let turns = started(&hub, &id, 2).await;
    let (read, _) = a.response(first).await;
    assert_eq!(read.unwrap()["_meta"]["acpmux"]["turnId"], turns[1]["turnId"]);
    // Claude Code answers the interrupt and runs on: acpmux ends the turn after its grace.
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (unread, _) = tokio::time::timeout(Duration::from_secs(30), b.response(second))
        .await
        .expect("the steer unread in the stopped turn was never answered");
    assert_eq!(unread.unwrap()["stopReason"], "cancelled");
    // The carried turn's task logs its end once the forced answer reaches it.
    for _ in 0..400 {
        if records(&hub, &id, "turn_result").len() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let ended = records(&hub, &id, "turn_result");
    assert_eq!(ended.last().unwrap()["turnId"], turns[1]["turnId"], "{ended:#?}");
    assert_eq!(ended.last().unwrap()["cancelForced"], true, "{ended:#?}");
}

/// A carried turn a connection error cuts off goes on by itself, as a prompt's own turn does
/// (`auto_resume.rs`), continuing the steer that started it.
#[tokio::test]
async fn a_carried_turn_a_connection_error_cut_off_goes_on_by_itself() {
    let (hub, mut c, id) = claude_hub().await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50]);
    let gates = Gates::new();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", &gates.text(), false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "gated turn 1").await;
    let (_a, _steer) = steer_in(&hub, &id, "p-late", "LATE-1").await;
    gates.open(1, "end");
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let turns = started(&hub, &id, 2).await;
    gates.open(2, "fail");
    let turns_now = started(&hub, &id, 3).await;
    let scheduled = records(&hub, &id, "auto_resume_scheduled");
    assert_eq!(scheduled.len(), 1, "{scheduled:#?}");
    assert_eq!(scheduled[0]["turnId"], turns[1]["turnId"], "{scheduled:#?}");
    let resumed = turns_now[2]["promptId"].as_str().unwrap_or_default();
    assert!(resumed.starts_with("p-late~resume"), "{:#?}", turns_now[2]);
}

/// A prompt that found the chat idle and waited for the turn lock, while the turn before it
/// carried on: it queues behind the carried turn, never replaces it (`queue.rs`).
#[tokio::test]
async fn a_prompt_waiting_for_the_lock_queues_behind_a_carried_turn() {
    let (hub, mut c, id) = claude_hub().await;
    let gates = Gates::new();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", &gates.text(), false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "gated turn 1").await;
    let (_a, _steer) = steer_in(&hub, &id, "p-late", "LATE-1").await;
    gates.open(1, "end");
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let turns = started(&hub, &id, 2).await;
    let mut b = connect(&hub).await;
    let next = b.send(method::SESSION_PROMPT, prompt(&id, "p-next", "after", false)).await;
    let accepted = b.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-next").await;
    assert_eq!(accepted["queued"], true, "{accepted}");
    let now = info(&mut c, &id).await["turn"].clone();
    assert_eq!(now["turnId"], turns[1]["turnId"], "the carried turn was replaced: {now}");
    gates.open(2, "read");
    let (ran, _) = b.response(next).await;
    assert!(ran.is_ok(), "{ran:?}");
    let ended = records(&hub, &id, "turn_result");
    assert_eq!(ended[1]["turnId"], turns[1]["turnId"], "{ended:#?}");
}

/// A connection from inside a session (its cmux-subsessions MCP server): `initialize` carries
/// that session's caller token, as the first thing on the connection.
async fn in_session(hub: &Arc<Hub>, init: Value) -> TestClient {
    let (in_tx, in_rx) = tokio::sync::mpsc::channel(64);
    let (out_tx, out_rx) = tokio::sync::mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, init).await.unwrap();
    c
}

/// Waits until Claude Code's stdin has a line holding `text`.
async fn on_stdin(hub: &Hub, id: &str, text: &str) {
    let written = |e: &acpmux::store::EventRecord| {
        e.kind == "claude.stdin" && e.msg.to_string().contains(text)
    };
    for _ in 0..400 {
        if hub.events(id, 0, 10_000).unwrap().iter().any(written) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("{text} never reached Claude Code");
}

/// Two steers Claude Code reads during its turn join it, and its one end_turn ends the daemon
/// turn: the turn never waits for an end_turn per steer. Six prompts queued behind it run, each
/// as its own turn, and the chat ends idle, not running or stuck (a coordinator's chat, 2026-10-29:
/// "even if im just queueing, your turn should still be ending").
async fn two_joined_steers_then_one_end_turn(sub_session: bool) {
    let (hub, mut c, id) = claude_hub().await;
    let gates = Gates::new();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", &gates.text(), false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "gated turn 1").await;
    let (mut a, first) = steer_in(&hub, &id, "p-1", "FIRST").await;
    // The second: the person's, or a sub-session's result delivered next_step.
    let mut second = None;
    if sub_session {
        hold_person_key(&hub);
        let caller = |sid: &str| {
            let token = acpmux::hub::person::caller_token(sid);
            json!({"protocolVersion": 1, "_meta": {"acpmux": {"callerSession": {"sessionId": sid, "token": token}}}})
        };
        let mut parent = in_session(&hub, caller(&id)).await;
        let child_gates = Gates::new();
        let started = parent
            .request("_acpmux/subsession/start", json!({"prompt": child_gates.text()}))
            .await
            .unwrap();
        let child = started["sessionId"].as_str().unwrap().to_owned();
        let mut k = in_session(&hub, caller(&child)).await;
        let params = json!({"sessionId": id, "text": "SUB-RESULT", "promptId": "p-sub", "deliver": "next_step"});
        let sent = k.request("_acpmux/subsession/send", params).await.unwrap();
        assert_eq!(sent["delivery"], "next_step", "{sent}");
        on_stdin(&hub, &id, "SUB-RESULT").await;
    } else {
        second = Some(steer_in(&hub, &id, "p-2", "SECOND").await);
    }
    let mut q = connect(&hub).await;
    let mut queued = Vec::new();
    for n in 1..=6 {
        let pid = format!("p-q{n}");
        queued.push(
            q.send(method::SESSION_PROMPT, prompt(&id, &pid, &format!("queued {n}"), false)).await,
        );
        let accepted = q.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == pid).await;
        assert_eq!(accepted["queued"], true, "{accepted}");
    }
    // Claude Code reads both at a tool boundary, then ends its turn once.
    gates.open(1, "read");
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let turns = records(&hub, &id, "turn_started");
    let (read, _) = a.response(first).await;
    assert_eq!(read.unwrap()["_meta"]["acpmux"]["turnId"], turns[0]["turnId"]);
    if let Some((mut b, second)) = second {
        let (read, _) = b.response(second).await;
        assert_eq!(read.unwrap()["_meta"]["acpmux"]["turnId"], turns[0]["turnId"]);
    }
    let ended = records(&hub, &id, "turn_result");
    assert_eq!(ended[0]["turnId"], turns[0]["turnId"], "{ended:#?}");
    assert_eq!(ended[0]["status"], "completed", "{ended:#?}");
    // The queue drains: each queued prompt is a turn of its own.
    for request in queued {
        let (ran, _) = q.response(request).await;
        assert_eq!(ran.unwrap()["stopReason"], "end_turn");
    }
    let turns = records(&hub, &id, "turn_started");
    assert_eq!(turns.len(), 7, "{turns:#?}");
    for _ in 0..400 {
        if records(&hub, &id, "turn_result").len() == 7 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(records(&hub, &id, "turn_result").len(), 7);
    let now = info(&mut c, &id).await;
    assert!(now.get("turn").is_none_or(Value::is_null), "{now}");
    // Idle with its agent still up reads "ready": neither running nor stuck.
    assert!(matches!(now["state"].as_str(), Some("ready" | "idle")), "{now}");
    assert_eq!(now["queued"], 0, "{now}");
}

#[tokio::test]
async fn two_steers_read_in_the_turn_then_one_end_turn_end_it_and_the_queue_drains() {
    two_joined_steers_then_one_end_turn(false).await;
}

#[tokio::test]
async fn a_sub_sessions_next_step_result_read_in_the_turn_does_not_hold_it_open() {
    two_joined_steers_then_one_end_turn(true).await;
}

/// Each carried turn is a turn of its own with its own turn cap (`hub/turn_cap.rs`): the cap's
/// timer is armed for a carried turn that follows a carried turn too, so an agent's message queued
/// behind it gets the notice at the cap. The queue path: with the inbox on (#27686), another
/// agent's plain message goes to the inbox and is never queued behind the turn.
#[tokio::test]
async fn a_carried_turn_after_a_carried_turn_has_its_own_cap() {
    let (hub, mut c, id) = claude_hub_with_inbox(false).await;
    let cap = 3_000;
    c.request(method::MUX_SET_TURN_CAP, json!({"sessionId": id, "turnCapMs": cap})).await.unwrap();
    let gates = Gates::new();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", &gates.text(), false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "gated turn 1").await;
    let (_a, _one) = steer_in(&hub, &id, "p-1", "ONE").await;
    gates.open(1, "end");
    c.response(turn).await.0.unwrap();
    started(&hub, &id, 2).await;
    // The second carry: its turn follows the carried turn before it (`run_carried`).
    let (_b, _two) = steer_in(&hub, &id, "p-2", "TWO").await;
    gates.open(2, "end");
    let turns = started(&hub, &id, 3).await;
    let third = turns[2]["turnId"].clone();
    // An agent's message, queued under the cap: the timer sends the notice at the cap. A plain
    // send would go into the inbox (`hub/inbox.rs`); a supersede-keyed one still queues.
    let mut q = connect(&hub).await;
    let mut queued = prompt(&id, "p-lane", "report from lane a", false);
    queued["_meta"]["acpmux"]["fromAgent"] = json!("lane-a");
    queued["_meta"]["acpmux"]["supersede"] = json!("lane-a-report");
    let _held = q.send(method::SESSION_PROMPT, queued).await;
    let accepted = q.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-lane").await;
    assert_eq!(accepted["queued"], true, "{accepted}");
    let notices = || {
        let events = hub.events(&id, 0, 10_000).unwrap();
        events
            .iter()
            .filter(|e| e.kind == "user_message")
            .filter(|e| e.msg["_meta"]["provenance"]["kind"] == "turn_cap")
            .map(|e| e.msg["_meta"]["provenance"]["turnId"].clone())
            .collect::<Vec<_>>()
    };
    for _ in 0..400 {
        if !notices().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(notices(), [third], "the third turn's cap sent its notice");
    gates.open(3, "read");
}
