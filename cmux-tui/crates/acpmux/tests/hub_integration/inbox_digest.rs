//! `acpmux session inbox NAME --digest` (`_acpmux/inbox_digest`, `hub/inbox_digest.rs`): the
//! agent messages waiting in a busy chat's queue go in as ONE digest prompt. A coordinator that
//! 30 lanes report to had 285 queued, each one a turn (2026-10-29).

use super::*;
use acpmux::server::{Origin, serve_connection_with};

const DIGEST: &str = "_acpmux/inbox_digest";

/// A prompt `fromAgent` names as `agent`'s message (`acpmux send --from`).
fn from_agent(id: &str, prompt_id: &str, agent: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": agent}}})
}

/// Starts an "until-cancel" turn in a new session; returns the session and that prompt's
/// request id.
async fn busy(c: &mut TestClient) -> (String, i64) {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let turn = c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-turn"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    (id, turn)
}

/// Sends `params` on `c` and waits until it is queued; returns its request id.
async fn queue(c: &mut TestClient, params: Value) -> i64 {
    let prompt_id = params["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned();
    let rid = c.send(method::SESSION_PROMPT, params).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == *prompt_id && p["queued"] == true)
        .await;
    rid
}

async fn queue_order(c: &mut TestClient, id: &str) -> Vec<String> {
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    attached["session"]["queue"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| q["promptId"].as_str().unwrap().to_owned())
        .collect()
}

/// The answers to the requests `ids` on `c`, in whatever order they come.
async fn answers(c: &mut TestClient, ids: &[i64]) -> BTreeMap<i64, Value> {
    let mut answered = BTreeMap::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while answered.len() < ids.len() {
        let line = tokio::time::timeout_at(deadline, c.rx.recv())
            .await
            .unwrap_or_else(|_| panic!("unanswered: answered only {:?}", answered.keys()))
            .expect("connection closed");
        if let Message::Response { id, result, error } = Message::parse(&line).unwrap()
            && let Some(id) = id.as_i64().filter(|id| ids.contains(id))
        {
            assert!(error.is_none(), "request {id}: {error:?}");
            answered.insert(id, result.unwrap_or(Value::Null));
        }
    }
    answered
}

/// The agent's replies ("echo: <prompt>") up to the one that contains `last`.
async fn echoes_until(c: &mut TestClient, last: &str) -> Vec<String> {
    let seen = c
        .collect_until(|m, p| {
            m == method::SESSION_UPDATE
                && p["update"]["content"]["text"]
                    .as_str()
                    .is_some_and(|t| t.starts_with("echo: ") && t.contains(last))
        })
        .await;
    seen.iter()
        .filter(|(m, _)| m == method::SESSION_UPDATE)
        .filter_map(|(_, p)| p["update"]["content"]["text"].as_str())
        .filter(|t| t.starts_with("echo: "))
        .map(str::to_owned)
        .collect()
}

/// A unix socket connection that proved it runs in session `caller` (its caller token).
async fn agent_of(hub: &Arc<Hub>, caller: &str) -> TestClient {
    agent_with_token(hub, caller, &acpmux::hub::person::caller_token(caller)).await
}

/// A unix socket connection that says it runs in session `caller` with `token`.
async fn agent_with_token(hub: &Arc<Hub>, caller: &str, token: &str) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "agent"},
                       "_meta": {"acpmux": {"callerSession": {"sessionId": caller, "token": token}}}});
    c.request(method::INITIALIZE, hello).await.unwrap();
    c
}

#[tokio::test]
async fn a_digest_takes_the_agent_messages_and_leaves_the_persons_prompts_ahead_of_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let mut agents = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    queue(&mut c, prompt(&id, "mine", Some("p-me"))).await;
    let a = queue(&mut agents, from_agent(&id, "p-a", "lane-a", "first from a")).await;
    let b = queue(&mut agents, from_agent(&id, "p-b", "lane-b", "second from b")).await;
    let a2 = queue(&mut agents, from_agent(&id, "p-a2", "lane-a", "third from a")).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-me", "p-a", "p-b", "p-a2"]);

    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["digested"], 3, "{made}");
    assert_eq!(made["delivery"], "queued", "an agent that does not steer: {made}");
    let digest = made["promptId"].as_str().unwrap().to_owned();
    // The person's prompt stays first; the digest takes the agents' place.
    assert_eq!(queue_order(&mut c, &id).await, ["p-me", digest.as_str()]);
    // It is the agents' part of the queue: the person's next prompt goes ahead of it, another
    // agent's message behind it.
    queue(&mut c, prompt(&id, "mine too", Some("p-me2"))).await;
    queue(&mut agents, from_agent(&id, "p-c", "lane-c", "from c")).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-me", "p-me2", digest.as_str(), "p-c"]);

    // Each original left the queue for the digest, its whole text kept in the log under its id.
    let events = hub.events(&id, 0, 1000).unwrap();
    let folded: Vec<&str> = find(&events, "dequeued")
        .into_iter()
        .filter(|e| e.msg["digestPromptId"] == *digest)
        .map(|e| e.msg["promptId"].as_str().unwrap())
        .collect();
    assert_eq!(folded, ["p-a", "p-b", "p-a2"]);
    for (prompt_id, text) in
        [("p-a", "first from a"), ("p-b", "second from b"), ("p-a2", "third from a")]
    {
        let queued = find(&events, "queued").into_iter().find(|e| e.msg["promptId"] == prompt_id);
        assert_eq!(queued.map(|e| e.msg["text"].clone()), Some(json!(text)), "{prompt_id}");
    }
    let record = find(&events, "queued").into_iter().find(|e| e.msg["promptId"] == *digest);
    let provenance = record.expect("the digest's queued record").msg["_meta"]["provenance"].clone();
    assert_eq!(provenance["kind"], "inbox_digest", "{provenance}");
    assert_eq!(provenance["digestId"], *digest, "{provenance}");
    let parts: Vec<&str> = provenance["parts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["promptId"].as_str().unwrap())
        .collect();
    assert_eq!(parts, ["p-a", "p-b", "p-a2"]);
    assert_eq!(provenance["counts"], json!({"block": 0, "question": 0, "result": 3, "fyi": 0}));

    // The person's prompts run as they were sent, then the digest as ONE turn, then the rest.
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let echoes = echoes_until(&mut c, "from c").await;
    assert_eq!(echoes.len(), 4, "{echoes:?}");
    assert_eq!(echoes[..2], ["echo: mine", "echo: mine too"]);
    assert!(echoes[2].starts_with("echo: [inbox digest] 3 messages"), "{}", echoes[2]);
    for text in ["first from a", "second from b", "third from a"] {
        assert!(echoes[2].contains(text), "{text:?} missing from {}", echoes[2]);
    }
    assert_eq!(echoes[3], "echo: from c", "no message joins a digest's turn");

    // Every original's prompt answers with the digest's turn.
    let answered = answers(&mut agents, &[a, b, a2]).await;
    for answer in answered.values() {
        assert_eq!(answer["_meta"]["acpmux"]["joinedPromptId"], *digest, "{answer}");
        assert_eq!(answer["stopReason"], "end_turn", "{answer}");
    }
    let events = hub.events(&id, 0, 1000).unwrap();
    let ran = find(&events, "user_message").into_iter().find(|e| e.msg["promptId"] == *digest);
    let ran = ran.expect("the digest's user_message");
    assert_eq!(ran.msg["_meta"]["provenance"]["kind"], "inbox_digest");
}

#[tokio::test]
async fn a_digest_steers_once_into_the_running_turn_of_an_agent_that_steers() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let mut agents = connect(&hub).await;
    let (id, turn) = busy(&mut c).await;
    queue(&mut c, prompt(&id, "mine", Some("p-me"))).await;
    let a = queue(&mut agents, from_agent(&id, "p-a", "lane-a", "first from a")).await;
    let b = queue(&mut agents, from_agent(&id, "p-b", "lane-b", "second from b")).await;

    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!((made["digested"].clone(), made["delivery"].clone()), (json!(2), json!("steer")));
    let digest = made["promptId"].as_str().unwrap().to_owned();
    let steered = c
        .wait_for(method::SESSION_UPDATE, |p| {
            p["update"]["content"]["text"].as_str().is_some_and(|t| t.starts_with("steer: "))
        })
        .await;
    let text = steered["update"]["content"]["text"].as_str().unwrap();
    assert!(text.starts_with("steer: [inbox digest] 2 messages"), "{text}");
    assert!(text.contains("first from a") && text.contains("second from b"), "{text}");
    assert_eq!(queue_order(&mut c, &id).await, ["p-me"], "the person's prompt still waits");

    // Answered as the steer was; nothing else steers into the turn.
    let answered = answers(&mut agents, &[a, b]).await;
    for answer in answered.values() {
        assert_eq!(answer["stopReason"], "steered", "{answer}");
        assert_eq!(answer["_meta"]["acpmux"]["joinedPromptId"], *digest, "{answer}");
    }
    // Each names the turn the steer went into, the one that ran: not the digest's queue entry.
    let events = hub.events(&id, 0, 1000).unwrap();
    let ran_in = find(&events, "turn_started")
        .into_iter()
        .find(|e| e.msg["promptId"] == "p-turn")
        .map(|e| e.msg["turnId"].clone())
        .unwrap();
    for answer in answered.values() {
        assert_eq!(answer["_meta"]["acpmux"]["turnId"], ran_in, "{answer}");
    }
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (_, seen) = c.response(turn).await;
    let steers = seen
        .iter()
        .filter_map(|(_, p)| p["update"]["content"]["text"].as_str())
        .filter(|t| t.starts_with("steer: "))
        .count();
    assert_eq!(steers, 0, "a second steer: {seen:?}");
    let events = hub.events(&id, 0, 1000).unwrap();
    let steer = find(&events, "user_message")
        .into_iter()
        .filter(|e| e.msg["promptId"] == *digest && e.msg["steer"] == true)
        .count();
    assert_eq!(steer, 1);
}

#[tokio::test]
async fn a_digest_groups_results_by_sender_folds_repeats_and_a_dry_run_changes_nothing() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let mut agents = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    for (prompt_id, agent, text) in [
        ("p1", "lane-a", "built X"),
        ("p2", "lane-b", "done Z"),
        ("p3", "lane-a", "built X"),
        ("p4", "lane-a", "tests green"),
    ] {
        queue(&mut agents, from_agent(&id, prompt_id, agent, text)).await;
    }
    let before = queue_order(&mut c, &id).await;

    let made = c.request(DIGEST, json!({"sessionId": id, "dryRun": true})).await.unwrap();
    assert_eq!((made["dryRun"].clone(), made["digested"].clone()), (json!(true), json!(4)));
    let text = made["text"].as_str().unwrap();
    let at = |s: &str| text.find(s).unwrap_or_else(|| panic!("{s:?} missing from {text}"));
    assert!(text.starts_with("[inbox digest] 4 messages"), "{text}");
    assert!(text.contains("(4 results)"), "a message with no class is a result: {text}");
    // lane-a's results first (its oldest came first), its two identical ones folded into the
    // newest; then lane-b's.
    assert!(at("### from lane-a") < at("[result] promptId p3 (×2)"));
    assert!(at("[result] promptId p3 (×2)") < at("[result] promptId p4"));
    assert!(at("[result] promptId p4") < at("### from lane-b"));
    assert!(at("### from lane-b") < at("[result] promptId p2"));
    assert_eq!(text.matches("built X").count(), 1, "{text}");
    let provenance = &made["provenance"];
    assert_eq!(provenance["counts"], json!({"block": 0, "question": 0, "result": 4, "fyi": 0}));
    let parts = provenance["parts"].as_array().unwrap();
    let p1 = parts.iter().find(|p| p["promptId"] == "p1").unwrap();
    assert_eq!((p1["duplicateOf"].clone(), p1["fromName"].clone()), (json!("p3"), json!("lane-a")));
    assert_eq!(p1["class"], "result");

    // A dry run changes nothing.
    assert_eq!(queue_order(&mut c, &id).await, before);
    let events = hub.events(&id, 0, 1000).unwrap();
    assert!(find(&events, "dequeued").is_empty(), "a dry run took a message");
    let digests = find(&events, "queued")
        .into_iter()
        .filter(|e| e.msg["_meta"]["provenance"]["kind"] == "inbox_digest")
        .count();
    assert_eq!(digests, 0, "a dry run queued a digest");
}

/// A message's class (`acpmux send --class`, `prompt_class.rs`) orders it: blocks and questions
/// first, then results, then FYIs; a message that named none is a result.
#[tokio::test]
async fn a_digest_puts_blocks_and_questions_first_and_fyis_last_by_the_class_sent() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let mut agents = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    for (prompt_id, agent, class, text) in [
        ("p-fyi", "lane-a", Some("fyi"), "heads up"),
        ("p-plain", "lane-b", None, "done Z"),
        ("p-block", "lane-c", Some("block"), "stuck on CI"),
        ("p-q", "lane-a", Some("question"), "which base?"),
    ] {
        let mut params = from_agent(&id, prompt_id, agent, text);
        if let Some(class) = class {
            params["_meta"]["acpmux"]["class"] = json!(class);
        }
        queue(&mut agents, params).await;
    }
    let made = c.request(DIGEST, json!({"sessionId": id, "dryRun": true})).await.unwrap();
    let text = made["text"].as_str().unwrap();
    let at = |s: &str| text.find(s).unwrap_or_else(|| panic!("{s:?} missing from {text}"));
    assert!(text.contains("(1 block, 1 question, 1 result, 1 FYI)"), "{text}");
    assert!(at("[block] from lane-c, promptId p-block") < at("[question] from lane-a"));
    assert!(at("which base?") < at("## Results"));
    assert!(at("[result] promptId p-plain") < at("## FYIs"));
    assert!(text.ends_with("- lane-a (promptId p-fyi): heads up"), "{text}");
    let counts = &made["provenance"]["counts"];
    assert_eq!(*counts, json!({"block": 1, "question": 1, "result": 1, "fyi": 1}));
}

#[tokio::test]
async fn past_its_budget_a_digest_points_at_the_full_text() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let mut agents = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    for (prompt_id, letter) in [("p-x", "x"), ("p-y", "y"), ("p-z", "z")] {
        let text = letter.repeat(60_000);
        queue(&mut agents, from_agent(&id, prompt_id, "lane-a", &text)).await;
    }
    let made = c.request(DIGEST, json!({"sessionId": id, "dryRun": true})).await.unwrap();
    let text = made["text"].as_str().unwrap();
    assert!(text.contains(&"x".repeat(60_000)) && text.contains(&"y".repeat(60_000)));
    assert!(text.contains(&format!("{}…\n[full text: promptId p-z]", "z".repeat(400))), "cut");
    assert!(!text.contains(&"z".repeat(401)), "past the budget it keeps 400 characters");
}

#[tokio::test]
async fn only_the_unix_socket_and_the_chats_own_agent_drain_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let (id, _) = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    for origin in [Origin::Web, Origin::LocalApp, Origin::Peer] {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        let mut remote = TestClient { tx: in_tx, rx: out_rx, next: 0 };
        let refused = remote.request(DIGEST, json!({"sessionId": id})).await;
        assert!(
            refused.as_ref().is_err_and(|e| e.contains("inbox_digest.origin_refused")),
            "{origin:?}: {refused:?}"
        );
    }
    // Another session's agent may not drain it.
    let other = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
    let other = other.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let mut stranger = agent_of(&hub, &other).await;
    let refused = stranger.request(DIGEST, json!({"sessionId": id})).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("inbox_digest.other_agent")), "{refused:?}");
    // A token this daemon did not issue proves nothing, not even for the chat it names.
    let mut forged = agent_with_token(&hub, &id, &"0".repeat(64)).await;
    let refused = forged.request(DIGEST, json!({"sessionId": id})).await;
    let not_proven = refused.as_ref().is_err_and(|e| e.contains("inbox_digest.caller_not_proven"));
    assert!(not_proven, "{refused:?}");
    assert_eq!(queue_order(&mut c, &id).await, ["p-a"], "a refused drain took a message");
    // Its own agent may.
    let mut own = agent_of(&hub, &id).await;
    let made = own.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["digested"], 1, "{made}");
}

/// A hub whose log lives in `dir`, so a second one there is the same daemon restarted.
fn durable_hub(dir: &std::path::Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// Drops every line of the logs under `dir` that contains `needle`: a stop that cut them off.
fn cut_lines(dir: &std::path::Path, needle: &str) -> usize {
    let mut cut = 0;
    let mut dirs = vec![dir.to_path_buf()];
    while let Some(d) = dirs.pop() {
        for path in std::fs::read_dir(&d).unwrap().flatten().map(|e| e.path()) {
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|e| e == "ndjson") {
                let log = std::fs::read_to_string(&path).unwrap();
                let kept: Vec<&str> = log.lines().filter(|l| !l.contains(needle)).collect();
                cut += log.lines().count() - kept.len();
                std::fs::write(&path, kept.iter().map(|l| format!("{l}\n")).collect::<String>())
                    .unwrap();
            }
        }
    }
    cut
}

/// The digest's `queued` record is logged before the originals' `dequeued` ones. A stop between
/// them leaves the originals' `queued` records with nothing after them: the digest's record names
/// them, so the restart runs the digest and never them again.
#[tokio::test]
async fn a_restart_never_runs_a_message_a_digest_took_even_when_the_stop_cut_its_dequeued() {
    let dir = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    let digest = made["promptId"].as_str().unwrap().to_owned();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    assert_eq!(cut_lines(&dir, "\"digestPromptId\""), 2);

    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let order = queue_order(&mut c, &id).await;
    assert!(order.contains(&digest), "the digest still waits: {order:?}");
    assert!(!order.iter().any(|p| p == "p-a" || p == "p-b"), "{order:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A message a digest took, sent again (`resend`) after a restart, answers from the digest's
/// turn: it went in there, so it is neither run again nor `interrupted`.
#[tokio::test]
async fn after_a_restart_a_resent_message_a_digest_took_answers_from_the_digests_turn() {
    let dir = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    let a = queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let answered = answers(&mut c, &[a]).await;
    assert_eq!(answered[&a]["_meta"]["acpmux"]["turnId"], made["turnId"], "{answered:?}");
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let mut again = from_agent(&id, "p-a", "lane-a", "from a");
    again["_meta"]["acpmux"]["resend"] = json!(true);
    let again = c.request(method::SESSION_PROMPT, again).await.unwrap();
    assert_eq!(again["_meta"]["acpmux"]["turnId"], made["turnId"], "{again}");
    assert_ne!(again["_meta"]["acpmux"]["status"], "interrupted", "{again}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let ran = find(&events, "user_message").into_iter().filter(|e| e.msg["promptId"] == "p-a");
    assert_eq!(ran.count(), 0, "the resend ran it on its own");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}
