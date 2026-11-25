//! An agent process that quits on its account's 429 between turns holds the chat until the reset
//! and is started again there with no prompt (`hub/rate_hold.rs` `hold_at_exit`). Leo,
//! 2026-11-21: "i dont think 429 should just cause a process to just exit on its own, this is
//! pretty weird".
use super::*;

const LIMIT: &str =
    "API Error: Request rejected (429) · This request would exceed your account's rate limit";

fn of_kind(hub: &Hub, id: &str, kind: &str) -> Vec<acpmux::store::EventRecord> {
    hub.events(id, 0, 10_000).unwrap().into_iter().filter(|e| e.kind == kind).collect()
}

fn status(hub: &Hub, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())["status"].clone()
}

fn from_agent(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": "lane"}}})
}

/// The lines the fake agents read (`FAKE_WIRE_LOG`): (pid, method).
fn wire(path: &std::path::Path) -> Vec<(u64, String)> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    text.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .map(|v| (v["pid"].as_u64().unwrap_or(0), v["method"].as_str().unwrap_or("").to_owned()))
        .collect()
}

fn count(path: &std::path::Path, method: &str) -> usize {
    wire(path).iter().filter(|(_, m)| m == method).count()
}

async fn wait_until(what: &str, secs: u64, pred: impl Fn() -> bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
    while !pred() {
        assert!(tokio::time::Instant::now() < deadline, "never happened: {what}");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// A hub whose fake agents log every line they read. While the returned file exists (none at
/// first), the account's limit stays spent: every agent started on the chat's conversation quits
/// on the 429 again, and every prompt fails on it.
async fn hub_with_wire(
    tag: &str,
) -> (Arc<Hub>, TestClient, std::path::PathBuf, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("acpmux-exit-429-{tag}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("wire.jsonl");
    let quit = dir.join("quit-429");
    let env = BTreeMap::from([
        ("FAKE_WIRE_LOG".to_owned(), log.display().to_string()),
        ("FAKE_QUIT_429_FILE".to_owned(), quit.display().to_string()),
        ("FAKE_RATE_LIMIT_FILE".to_owned(), quit.display().to_string()),
    ]);
    // `agentInbox` off: another agent's message queues as a turn of its own.
    let (hub, c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    (hub, c, log, quit)
}

/// (a) The 429 exit is a strike and holds the chat: another agent's message that comes in waits
/// for the reset instead of starting the agent into the limit.
#[tokio::test]
async fn a_429_exit_between_turns_holds_the_chat_and_a_queued_message_waits_for_the_reset() {
    let (hub, mut c, log, _dir) = hub_with_wire("held").await;
    // The backoff's first wait: 1.5 s.
    hub.config.write().await.auto_resume_delays_ms = Some(vec![1_500, 1_500]);
    let id = new_session(&mut c, "quit-held").await;
    c.request(method::SESSION_PROMPT, prompt(&id, &format!("quit-after: {LIMIT}"), Some("p-1")))
        .await
        .unwrap();
    wait_until("the agent quit", 20, || !of_kind(&hub, &id, "exited").is_empty()).await;
    wait_until("the chat is held", 5, || !of_kind(&hub, &id, "rate_limit_held").is_empty()).await;
    let held = of_kind(&hub, &id, "rate_limit_held");
    let exited_at = of_kind(&hub, &id, "exited")[0].at;
    let until = held[0].msg["until"].as_u64().unwrap();
    assert_eq!(held[0].msg["strikes"], 1, "{held:?}");
    assert!(until >= exited_at + 1_400, "held for the backoff: {until} vs {exited_at}");
    assert_eq!(hub.resolve(&id).unwrap().rate_hold_strikes(), 1);
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(row["rateLimitedUntil"], until, "{row}");
    assert_eq!(status(&hub, &id), "disconnected");

    c.send(method::SESSION_PROMPT, from_agent(&id, "m-1", "report while limited")).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(acpmux::store::now_ms() < until, "the test reached the reset before it looked");
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "no turn before the reset");
    assert_eq!(count(&log, "session/prompt"), 1, "no model request before the reset");

    let ran = async {
        while of_kind(&hub, &id, "turn_result").len() < 2 {
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    };
    if tokio::time::timeout(Duration::from_secs(20), ran).await.is_err() {
        panic!("the message never ran after the reset: {:?}", kinds(&hub, &id));
    }
    let started = of_kind(&hub, &id, "turn_started");
    assert!(started[1].at >= until, "it started at the reset: {} < {until}", started[1].at);
}

/// (b) At the reset the agent is back on its conversation, and no prompt reached it.
#[tokio::test]
async fn at_the_reset_the_agent_is_back_with_no_prompt_sent() {
    let (hub, mut c, log, _dir) = hub_with_wire("revive").await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![300, 300]);
    let id = new_session(&mut c, "quit-revive").await;
    let sid = hub.resolve(&id).unwrap().meta().agent_session_id;
    c.request(method::SESSION_PROMPT, prompt(&id, &format!("quit-after: {LIMIT}"), Some("p-1")))
        .await
        .unwrap();
    wait_until("the agent quit", 20, || !of_kind(&hub, &id, "exited").is_empty()).await;
    wait_until("the agent is back", 20, || status(&hub, &id) == "ready").await;
    let revived = of_kind(&hub, &id, "rate_limit_revived");
    assert_eq!(revived.len(), 1, "{:?}", kinds(&hub, &id));
    let until = of_kind(&hub, &id, "rate_limit_held")[0].msg["until"].as_u64().unwrap();
    assert!(revived[0].at >= until, "revived at the reset: {} < {until}", revived[0].at);
    let lifted = of_kind(&hub, &id, "rate_limit_lifted");
    assert_eq!(lifted[0].msg["why"], "reset", "{lifted:?}");
    // A second agent process, loaded on the same conversation, and no model request.
    let pids: std::collections::BTreeSet<u64> = wire(&log).iter().map(|(p, _)| *p).collect();
    assert_eq!(pids.len(), 2, "{:?}", wire(&log));
    assert_eq!(count(&log, "session/load"), 1, "{:?}", wire(&log));
    assert_eq!(count(&log, "session/prompt"), 1, "{:?}", wire(&log));
    assert_eq!(hub.resolve(&id).unwrap().meta().agent_session_id, sid);
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1);
    // It stays up: no second exit, no second start.
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(status(&hub, &id), "ready");
    assert_eq!(of_kind(&hub, &id, "exited").len(), 1);
}

/// (c) An exit on anything but the limit (a 403) is as before: no hold, no strike, no revive,
/// and the next prompt starts the agent at once.
#[tokio::test]
async fn a_403_exit_holds_nothing_and_revives_nothing() {
    let (hub, mut c, log, _dir) = hub_with_wire("403").await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![100, 100]);
    let id = new_session(&mut c, "quit-403").await;
    let line = "API Error: 403 {\"type\":\"error\",\"error\":{\"type\":\"permission_error\",\"message\":\"Request not allowed\"}}";
    c.request(method::SESSION_PROMPT, prompt(&id, &format!("quit-after: {line}"), Some("p-1")))
        .await
        .unwrap();
    wait_until("the agent quit", 20, || !of_kind(&hub, &id, "exited").is_empty()).await;
    let exited = of_kind(&hub, &id, "exited");
    assert_ne!(exited[0].msg["reason"], "rate_limit", "{exited:?}");
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert!(of_kind(&hub, &id, "rate_limit_held").is_empty(), "{:?}", kinds(&hub, &id));
    assert!(of_kind(&hub, &id, "rate_limit_revived").is_empty(), "{:?}", kinds(&hub, &id));
    assert_eq!(hub.resolve(&id).unwrap().rate_hold_strikes(), 0);
    assert_eq!(status(&hub, &id), "disconnected");
    assert_eq!(count(&log, "initialize"), 1, "nothing started it again");
    let at = acpmux::store::now_ms();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello again", Some("p-2"))).await.unwrap();
    assert!(of_kind(&hub, &id, "turn_started")[1].at < at + 5_000);
    assert_eq!(status(&hub, &id), "ready");
}

/// Duress: an account whose limit stays spent, an agent that quits on the 429 at every start,
/// and another agent's message after each quit, for up to 8 quits or 12 s. Prints how many
/// agents started, how many model requests reached them, and the waits between quits.
#[tokio::test]
async fn duress_eight_429_exits_in_a_row() {
    let (hub, mut c, log, spent) = hub_with_wire("duress").await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![100, 100]);
    let id = new_session(&mut c, "quit-duress").await;
    let t0 = std::time::Instant::now();
    c.request(method::SESSION_PROMPT, prompt(&id, &format!("quit-after: {LIMIT}"), Some("p-0")))
        .await
        .unwrap();
    std::fs::write(&spent, LIMIT).unwrap();
    let mut sent = 0;
    let mut seen = 0;
    while t0.elapsed() < Duration::from_secs(12) {
        let exits = of_kind(&hub, &id, "exited").len();
        if exits > seen && sent < 8 {
            seen = exits;
            sent += 1;
            c.send(method::SESSION_PROMPT, from_agent(&id, &format!("m-{sent}"), "report")).await;
        }
        if exits >= 8 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let exits: Vec<u64> = of_kind(&hub, &id, "exited").iter().map(|e| e.at).collect();
    let gaps: Vec<u64> = exits.windows(2).map(|w| w[1] - w[0]).collect();
    let pids: std::collections::BTreeSet<u64> = wire(&log).iter().map(|(p, _)| *p).collect();
    let session = hub.resolve(&id).unwrap();
    eprintln!(
        "DURESS 429-exit: window {} ms; agent exits {}; agent spawns {}; model requests (session/prompt) {}; \
         messages sent {}; strikes {}; parked {}; waits between exits (ms) {:?}; status {}",
        t0.elapsed().as_millis(),
        exits.len(),
        pids.len(),
        count(&log, "session/prompt"),
        sent,
        session.rate_hold_strikes(),
        !of_kind(&hub, &id, "rate_limit_parked").is_empty(),
        gaps,
        status(&hub, &id),
    );
}
