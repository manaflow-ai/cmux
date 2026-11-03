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

/// Ends the busy turn with an agent's Stop: the person's Stop holds the agent messages, a
/// digest of them too, until the person's next turn (`cancel.rs` `hold_agent_messages`).
async fn end_busy(hub: &Arc<Hub>, id: &str) {
    hub.cancel(&hub.resolve(id).unwrap()).await.unwrap();
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
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
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
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
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

/// A turn past its cap (`turn_cap.rs`) takes no digest: the digest waits for the next turn, as
/// the agent messages it took would have.
#[tokio::test]
async fn a_digest_waits_for_the_next_turn_when_the_running_one_is_past_its_cap() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    let mut agents = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    let cap = json!({"sessionId": id, "turnCapMs": 1});
    c.request(method::MUX_SET_TURN_CAP, cap).await.unwrap();
    tokio::time::sleep(Duration::from_millis(20)).await;
    queue(&mut agents, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut agents, from_agent(&id, "p-b", "lane-b", "from b")).await;

    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!((made["digested"].clone(), made["delivery"].clone()), (json!(2), json!("queued")));
    let digest = made["promptId"].as_str().unwrap().to_owned();
    assert_eq!(queue_order(&mut c, &id).await, std::slice::from_ref(&digest));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let events = hub.events(&id, 0, 1000).unwrap();
    let steered = find(&events, "user_message")
        .into_iter()
        .any(|e| e.msg["promptId"] == *digest && e.msg["steer"] == true);
    assert!(!steered, "the digest steered into a turn past its cap");
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
}

#[tokio::test]
async fn a_digest_groups_results_by_sender_folds_repeats_and_a_dry_run_changes_nothing() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
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
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
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
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
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
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
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
        // A restart's continuation of a cut "until-cancel" turn quotes it, and runs as long.
        "harnesses": {"fake": {
            "argv": ["python3", fake],
            "env": {"FAKE_UNTIL_CANCEL_IN": "until-cancel"}
        }},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    // These test the queue's digest: plain sends queue as before the inbox (`hub/inbox.rs`).
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// Drops every line of the logs under `dir` that `cut` picks: a stop that cut them off.
fn cut_lines(dir: &std::path::Path, cut: impl Fn(&str) -> bool) -> usize {
    let mut dropped = 0;
    let mut dirs = vec![dir.to_path_buf()];
    while let Some(d) = dirs.pop() {
        for path in std::fs::read_dir(&d).unwrap().flatten().map(|e| e.path()) {
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|e| e == "ndjson") {
                let log = std::fs::read_to_string(&path).unwrap();
                let kept: Vec<&str> = log.lines().filter(|l| !cut(l)).collect();
                dropped += log.lines().count() - kept.len();
                std::fs::write(&path, kept.iter().map(|l| format!("{l}\n")).collect::<String>())
                    .unwrap();
            }
        }
    }
    dropped
}

/// Drops, in each log under `dir`, the first line `from` picks and every line after it: a stop
/// right before that record.
fn truncate_from(dir: &std::path::Path, from: impl Fn(&str) -> bool) -> usize {
    let mut dropped = 0;
    let mut dirs = vec![dir.to_path_buf()];
    while let Some(d) = dirs.pop() {
        for path in std::fs::read_dir(&d).unwrap().flatten().map(|e| e.path()) {
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|e| e == "ndjson") {
                let log = std::fs::read_to_string(&path).unwrap();
                let kept: Vec<&str> = log.lines().take_while(|l| !from(l)).collect();
                dropped += log.lines().count() - kept.len();
                std::fs::write(&path, kept.iter().map(|l| format!("{l}\n")).collect::<String>())
                    .unwrap();
            }
        }
    }
    dropped
}

/// A restart before a digest's turn started drops it and gives its messages back in its place,
/// ahead of an agent message it left (a slash command), each once: also when the stop cut every
/// record after the digest's own (the queue's order and their `dequeued` records).
#[tokio::test]
async fn a_restart_before_a_digest_ran_gives_its_messages_back_in_its_place() {
    for cut in [false, true] {
        gives_back_after_a_restart(cut).await;
    }
}

async fn gives_back_after_a_restart(cut: bool) {
    let dir = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-slash", "lane-x", "/compact")).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    let digest = made["promptId"].as_str().unwrap().to_owned();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    if cut {
        let stop = |l: &str| {
            l.contains("\"digestPromptId\"")
                || (l.contains("\"kind\":\"queue_order\"") && l.contains(digest.as_str()))
        };
        assert_eq!(cut_lines(&dir, stop), 3);
    }

    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let order = queue_order(&mut c, &id).await;
    let at = |p: &str| order.iter().position(|q| q == p);
    assert!(at(&digest).is_none(), "cut {cut}: the digest that never ran stayed: {order:?}");
    let (a, b, slash) = (at("p-a"), at("p-b"), at("p-slash"));
    assert!(a.is_some() && a < b && b < slash, "cut {cut}: {order:?}");
    assert_eq!(order.iter().filter(|p| *p == "p-a").count(), 1, "{order:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A message a digest took, sent again (`resend`) after a restart, answers from the digest's
/// turn: it went in there, so it is neither run again nor `interrupted`. Also when the stop cut
/// its `dequeued` record: the digest's own record names it.
#[tokio::test]
async fn after_a_restart_a_resent_message_a_digest_took_answers_from_the_digests_turn() {
    resent_after_a_restart(false).await;
    resent_after_a_restart(true).await;
}

async fn resent_after_a_restart(cut_dequeued: bool) {
    let dir = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    let a = queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    end_busy(&hub, &id).await;
    let answered = answers(&mut c, &[a]).await;
    assert_eq!(answered[&a]["_meta"]["acpmux"]["turnId"], made["turnId"], "{answered:?}");
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    if cut_dequeued {
        assert_eq!(cut_lines(&dir, |l| l.contains("\"digestPromptId\"")), 1);
    }

    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let mut again = from_agent(&id, "p-a", "lane-a", "from a");
    again["_meta"]["acpmux"]["resend"] = json!(true);
    let again = c.request(method::SESSION_PROMPT, again).await.unwrap();
    assert_eq!(again["_meta"]["acpmux"]["turnId"], made["turnId"], "cut {cut_dequeued}: {again}");
    assert_ne!(again["_meta"]["acpmux"]["status"], "interrupted", "{again}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let ran = find(&events, "user_message").into_iter().filter(|e| e.msg["promptId"] == "p-a");
    assert_eq!(ran.count(), 0, "the resend ran it on its own");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A steered digest leaves the queue (`dequeued`) before its steer is written (`user_message`).
/// A stop between them loses nothing: its turn never started, so its messages come back.
#[tokio::test]
async fn a_restart_gives_back_the_messages_of_a_steered_digest_cut_before_it_was_written() {
    let dir = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let steers = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    hub.config.write().await.harnesses.get_mut("fake").unwrap().env = steers;
    let mut c = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["delivery"], "steer", "{made}");
    let digest = made["promptId"].as_str().unwrap().to_owned();
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["update"]["content"]["text"].as_str().is_some_and(|t| t.starts_with("steer: "))
    })
    .await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let written = |l: &str| l.contains("\"kind\":\"user_message\"") && l.contains(digest.as_str());
    assert_eq!(cut_lines(&dir, written), 1);

    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let order = queue_order(&mut c, &id).await;
    assert!(order.iter().any(|p| p == "p-a"), "the steered digest's message was lost: {order:?}");
    assert!(!order.contains(&digest), "{order:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// Waits until session `id`'s log holds a `kind` record that `pred` takes, and returns it.
async fn record_until(
    hub: &Arc<Hub>,
    id: &str,
    kind: &str,
    pred: impl Fn(&Value) -> bool,
) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let events = hub.events(id, 0, 10_000).unwrap();
        if let Some(e) = find(&events, kind).into_iter().find(|e| pred(&e.msg)) {
            return e.msg.clone();
        }
        assert!(tokio::time::Instant::now() < deadline, "no {kind} record came");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A digest refused before its turn (its chat's folder is gone, `cold_prompt_check`) loses no
/// message: every one it took goes back to the queue as it was (held, as the failed turn held
/// them), its sender still waiting, and a restart restores them all, never the digest.
#[tokio::test]
async fn a_digest_refused_before_its_turn_puts_every_message_back_and_a_restart_keeps_them() {
    let root = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let (state, folder) = (root.join("state"), root.join("work"));
    std::fs::create_dir_all(&folder).unwrap();
    let hub = durable_hub(&state);
    // The held messages' own retry waits out the test.
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let mut c = connect(&hub).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": folder, "mcpServers": []})).await;
    let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, prompt(&id, "die-later: gone", Some("p-die"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "dying ").await;
    let a = queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    let b = queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    record_until(&hub, &id, "queue_paused", |m| m["held"] == json!(["p-a", "p-b"])).await;
    std::fs::remove_dir_all(&folder).unwrap();

    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["digested"], 2, "{made}");
    let digest = made["promptId"].as_str().unwrap().to_owned();
    let refused = record_until(&hub, &id, "prompt_refused", |m| m["promptId"] == *digest).await;
    assert!(refused["error"].as_str().unwrap().contains("session.folder_missing"), "{refused}");
    for original in ["p-a", "p-b"] {
        let back = |m: &Value| m["promptId"] == original && m["requeued"] == true;
        record_until(&hub, &id, "queued", back).await;
    }
    assert_eq!(queue_order(&mut c, &id).await, ["p-a", "p-b"]);
    // Their senders still wait: no answer came for them.
    let early = tokio::time::timeout(Duration::from_millis(500), answers(&mut c, &[a, b])).await;
    assert!(early.is_err(), "a message the refused digest took was answered: {early:?}");
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable_hub(&state);
    let mut c = connect(&hub).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-a", "p-b"], "a restart lost them");
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // A stop before any of them went back, or after only the first did, loses none and keeps
    // their order: the digest's removal comes after them.
    for (copy, first) in [("before-a", "p-a"), ("before-b", "p-b")] {
        let saved = root.join(copy);
        copy_dir(&state, &saved);
        let at = |l: &str| {
            l.contains("\"requeued\":true") && l.contains(&format!("\"promptId\":\"{first}\""))
        };
        assert!(truncate_from(&saved, at) > 0);
        let hub = durable_hub(&saved);
        let mut c = connect(&hub).await;
        let order = queue_order(&mut c, &id).await;
        assert_eq!(order, ["p-a", "p-b"], "a stop before {first} went back");
        hub.shutdown_all().await;
        drop(c);
        drop(hub);
    }

    // Once they ran on their own, a resend of one answers from its own turn, not the refused
    // digest's (and not from the chat's last turn: another one runs after it).
    std::fs::create_dir_all(&folder).unwrap();
    let hub = durable_hub(&state);
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let mut c = connect(&hub).await;
    queue_order(&mut c, &id).await;
    hub.resume_queues();
    c.request("_acpmux/queue_edit", json!({"sessionId": id, "op": "resume"})).await.unwrap();
    let own = record_until(&hub, &id, "queued", |m| m["promptId"] == "p-a").await["turnId"].clone();
    record_until(&hub, &id, "turn_result", |m| m["turnId"] == own).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "after", Some("p-after"))).await.unwrap();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let hub = durable_hub(&state);
    let mut c = connect(&hub).await;
    let mut again = from_agent(&id, "p-a", "lane-a", "from a");
    again["_meta"]["acpmux"]["resend"] = json!(true);
    let again = c.request(method::SESSION_PROMPT, again).await.unwrap();
    let status = &again["_meta"]["acpmux"]["status"];
    assert!(status != "withdrawn" && status != "interrupted", "{again}");
    assert_eq!(again["stopReason"], "end_turn", "{again}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Copies the directory `from` to `to`.
fn copy_dir(from: &std::path::Path, to: &std::path::Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let path = entry.path();
        let target = to.join(entry.file_name());
        if path.is_dir() {
            copy_dir(&path, &target);
        } else {
            std::fs::copy(&path, &target).unwrap();
        }
    }
}

/// A hub in a new directory, with a busy session that has `messages` agent messages queued and
/// drained into a digest that waits. Returns the directory, the session and the digest's id.
async fn waiting_digest(
    messages: &[&str],
) -> (std::path::PathBuf, Arc<Hub>, TestClient, String, String) {
    let dir = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    for m in messages {
        queue(&mut c, from_agent(&id, m, "lane-a", &format!("text of {m}"))).await;
    }
    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["delivery"], "queued", "{made}");
    let digest = made["promptId"].as_str().unwrap().to_owned();
    (dir, hub, c, id, digest)
}

/// The order of session `id`'s queue in a hub restarted in `dir`.
async fn order_after_a_restart(
    hub: Arc<Hub>,
    c: TestClient,
    dir: &std::path::Path,
    id: &str,
) -> Vec<String> {
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let hub = durable_hub(dir);
    let mut c = connect(&hub).await;
    let order = queue_order(&mut c, id).await;
    hub.shutdown_all().await;
    order
}

/// A digest the person edited is their prompt now: a restart keeps their text and gives back
/// none of the messages it took (`queue_updated`).
#[tokio::test]
async fn a_restart_keeps_a_digest_the_person_edited_and_not_its_messages() {
    let (dir, hub, mut c, id, digest) = waiting_digest(&["p-a"]).await;
    let edit = json!({"sessionId": id, "promptId": digest, "op": "update", "text": "mine now"});
    c.request("_acpmux/queue_edit", edit).await.unwrap();
    let order = order_after_a_restart(hub, c, &dir, &id).await;
    assert!(order.contains(&digest), "the person's edit was lost: {order:?}");
    assert!(!order.iter().any(|p| p == "p-a"), "{order:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A digest withdrawn before its turn answered its messages' senders `cancelled`: a restart does
/// not bring them back.
#[tokio::test]
async fn a_restart_does_not_bring_back_the_messages_of_a_withdrawn_digest() {
    let (dir, hub, mut c, id, digest) = waiting_digest(&["p-a"]).await;
    let remove = json!({"sessionId": id, "promptId": digest});
    assert_eq!(c.request("_acpmux/queue_remove", remove).await.unwrap()["removed"], true);
    let order = order_after_a_restart(hub, c, &dir, &id).await;
    assert!(!order.iter().any(|p| p == "p-a" || *p == digest), "{order:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A digest's turn starts with its `turn_started`, logged after its `user_message` and the agent's
/// start: a stop between them gives its messages back, never the digest alone.
#[tokio::test]
async fn a_restart_between_a_digests_prompt_and_its_turn_gives_its_messages_back() {
    let (dir, hub, c, id, digest) = waiting_digest(&["p-a", "p-b"]).await;
    end_busy(&hub, &id).await;
    record_until(&hub, &id, "turn_result", |m| m["promptId"] == *digest).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let started = |l: &str| l.contains("\"kind\":\"turn_started\"") && l.contains(digest.as_str());
    assert!(truncate_from(&dir, started) > 0);
    let hub = durable_hub(&dir);
    let c = connect(&hub).await;
    let order = order_after_a_restart(hub, c, &dir, &id).await;
    let at = |p: &str| order.iter().position(|q| q == p);
    assert!(at(&digest).is_none(), "{order:?}");
    assert!(at("p-a").is_some() && at("p-a") < at("p-b"), "{order:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Messages a restart gave back, drained again into a second digest, follow that one: a second
/// restart puts them in its place, ahead of an agent message queued between the two drains.
#[tokio::test]
async fn messages_drained_twice_follow_the_newest_digest_at_a_restart() {
    let (dir, hub, c, id, _) = waiting_digest(&["p-a", "p-b"]).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let first = queue_order(&mut c, &id).await;
    // The cut turn goes on first (`restart_resume.rs`), until cancelled; the given-back messages
    // wait behind it, claimed.
    hub.resume_queues();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let started = |hub: &Arc<Hub>| {
        let events = hub.events(&id, 0, 10_000).unwrap();
        find(&events, "turn_started")
            .iter()
            .any(|e| e.msg["promptId"].as_str().is_some_and(|p| p.starts_with("p-turn~resume")))
    };
    while !started(&hub) {
        assert!(tokio::time::Instant::now() < deadline, "p-turn did not run again: {first:?}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    queue(&mut c, from_agent(&id, "p-slash", "lane-x", "/compact")).await;
    // A restored message is drained once its task claimed it (`takes`): a dry run says when.
    loop {
        let dry = c.request(DIGEST, json!({"sessionId": id, "dryRun": true})).await.unwrap();
        if dry["digested"] == 2 {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "never claimed: {dry} {first:?}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["digested"], 2, "{made} {first:?} {:?}", queue_order(&mut c, &id).await);
    let order = order_after_a_restart(hub, c, &dir, &id).await;
    let at = |p: &str| order.iter().position(|q| q == p);
    let (a, b, slash) = (at("p-a"), at("p-b"), at("p-slash"));
    assert!(a.is_some() && a < b && b < slash, "{order:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A digest whose turn never reached its agent (it cannot start) puts the messages it took back
/// unheld, as a failed start puts back any agent message that joined it: each gets its own try
/// at once, not after the held messages' retry wait (10 s at first).
#[tokio::test]
async fn a_digest_whose_agent_cannot_start_puts_its_messages_back_unheld() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
    let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "answer-then-exit", Some("p-exit")))
        .await
        .unwrap();
    let s = hub.resolve(&id).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while s.meta().status != acpmux::store::SessionStatus::Disconnected {
        assert!(tokio::time::Instant::now() < deadline, "the agent never exited");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // From now on the agent cannot start at all, and takes a moment to say so.
    let mut config = hub.config.write().await;
    let fake = config.harnesses.get_mut("fake").unwrap();
    fake.env.insert("FAKE_DIE_AT_START".to_owned(), "cannot start".to_owned());
    fake.env.insert("FAKE_INIT_DELAY_MS".to_owned(), "1000".to_owned());
    drop(config);

    // The person's prompt starts the agent; the messages wait behind it and go into a digest.
    let first = c.send(method::SESSION_PROMPT, prompt(&id, "mine", Some("p-me"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-me").await;
    let a = queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    let b = queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!((made["digested"].clone(), made["delivery"].clone()), (json!(2), json!("queued")));
    let digest = made["promptId"].as_str().unwrap().to_owned();
    let (failed, _) = c.response(first).await;
    assert!(failed.is_err(), "the agent started: {failed:?}");

    // The digest's start fails too; each message then tries on its own, at once.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    let mut left = vec![a, b];
    while !left.is_empty() {
        let line = tokio::time::timeout_at(deadline, c.rx.recv())
            .await
            .expect("a message the digest put back stayed held")
            .expect("connection closed");
        if let Message::Response { id: rid, error, .. } = Message::parse(&line).unwrap()
            && let Some(rid) = rid.as_i64().filter(|rid| left.contains(rid))
        {
            let error = error.expect("an agent that cannot start answered");
            assert!(!error.message.contains(digest.as_str()), "{error:?}");
            left.retain(|l| *l != rid);
        }
    }
    let events = hub.events(&id, 0, 10_000).unwrap();
    let back = find(&events, "queued").into_iter().filter(|e| e.msg["requeued"] == true).count();
    assert_eq!(back, 2, "the digest's failed start did not put them back");
    assert!(find(&events, "queue_paused").is_empty(), "a failed start held the queue");
    hub.shutdown_all().await;
}

/// A digest goes behind the person's prompts, a held one included: draining agent messages moves
/// none of the person's prompts behind them.
#[tokio::test]
async fn a_digest_goes_behind_a_held_prompt_of_the_persons() {
    let root = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&root.join("state"));
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let mut c = connect(&hub).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
    let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, prompt(&id, "die-later: gone", Some("p-die"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "dying ").await;
    queue(&mut c, prompt(&id, "mine", Some("p-me"))).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    record_until(&hub, &id, "queue_paused", |m| m["held"] == json!(["p-me", "p-a"])).await;

    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["digested"], 1, "{made}");
    assert_eq!(made["position"], 2, "the digest went ahead of the person's prompt: {made}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// Messages a failed turn held, drained into a digest whose agent then cannot start, come back
/// held and still get their retry: the one scheduled when they were held found none of them.
#[tokio::test]
async fn held_messages_a_failed_digest_puts_back_still_get_their_retry() {
    let root = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&root.join("state"));
    hub.config.write().await.auto_resume_delays_ms = Some(vec![300]);
    let mut c = connect(&hub).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
    let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, prompt(&id, "die-later: gone", Some("p-die"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "dying ").await;
    let a = queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    let b = queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    record_until(&hub, &id, "queue_paused", |m| m["held"] == json!(["p-a", "p-b"])).await;
    // From now on the agent cannot start, and takes longer to say so than the retry waits.
    let mut config = hub.config.write().await;
    let fake = config.harnesses.get_mut("fake").unwrap();
    fake.env.insert("FAKE_DIE_AT_START".to_owned(), "cannot start".to_owned());
    fake.env.insert("FAKE_INIT_DELAY_MS".to_owned(), "1500".to_owned());
    drop(config);

    let made = c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["digested"], 2, "{made}");
    // The digest fails to start; the messages go back held and are retried, so their senders
    // hear back (each fails on its own: the agent still cannot start).
    let answered = tokio::time::timeout(Duration::from_secs(15), async {
        let mut left = vec![a, b];
        while !left.is_empty() {
            let line = c.rx.recv().await.expect("connection closed");
            if let Message::Response { id: rid, .. } = Message::parse(&line).unwrap()
                && let Some(rid) = rid.as_i64()
            {
                left.retain(|l| *l != rid);
            }
        }
    })
    .await;
    assert!(answered.is_ok(), "the held messages the digest put back were never retried");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A digest the person edited is their prompt, and its turn still owns the messages it took: a
/// failure after its prompt reached the agent puts them back held, as messages that joined a
/// failed turn are.
#[tokio::test]
async fn an_edited_digest_whose_turn_fails_puts_its_messages_back_held() {
    let (dir, hub, mut c, id, digest) = waiting_digest(&["p-a", "p-b"]).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let edit = json!({"sessionId": id, "promptId": digest, "op": "update", "text": "die-later: x"});
    c.request("_acpmux/queue_edit", edit).await.unwrap();
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let held = |m: &Value| m["held"].as_array().is_some_and(|h| h.contains(&json!("p-a")));
    record_until(&hub, &id, "queue_paused", held).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-a", "p-b"]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A message a digest took that a restart gave back (the digest's prompt was logged, its turn
/// never started) and that then ran on its own answers a later resend from its own turn.
#[tokio::test]
async fn a_resend_of_a_message_given_back_before_its_digests_turn_answers_from_its_own() {
    let (dir, hub, c, id, digest) = waiting_digest(&["p-a"]).await;
    let own = record_until(&hub, &id, "queued", |m| m["promptId"] == "p-a").await["turnId"].clone();
    end_busy(&hub, &id).await;
    record_until(&hub, &id, "turn_result", |m| m["promptId"] == *digest).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let started = |l: &str| l.contains("\"kind\":\"turn_started\"") && l.contains(digest.as_str());
    assert!(truncate_from(&dir, started) > 0);

    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-a"]);
    hub.resume_queues();
    record_until(&hub, &id, "turn_result", |m| m["turnId"] == own).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "after", Some("p-after"))).await.unwrap();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let mut again = from_agent(&id, "p-a", "lane-a", "text of p-a");
    again["_meta"]["acpmux"]["resend"] = json!(true);
    let again = c.request(method::SESSION_PROMPT, again).await.unwrap();
    assert_eq!(again["_meta"]["acpmux"]["turnId"], own, "{again}");
    assert_eq!(again["stopReason"], "end_turn", "{again}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// Messages the person reordered before the drain come back in that order at a restart, not in
/// the order they arrived.
#[tokio::test]
async fn a_restart_gives_back_a_digests_messages_in_the_queues_order() {
    let dir = std::env::temp_dir().join(format!("acpmux-inbox-digest-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let (id, _) = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    let moved = json!({"sessionId": id, "promptId": "p-b", "op": "move", "index": 0});
    c.request("_acpmux/queue_edit", moved).await.unwrap();
    assert_eq!(queue_order(&mut c, &id).await, ["p-b", "p-a"]);
    c.request(DIGEST, json!({"sessionId": id})).await.unwrap();
    // The restart's continuation of the cut turn goes first (`restart_resume.rs`).
    let order = order_after_a_restart(hub, c, &dir, &id).await;
    let mine: Vec<&String> =
        order.iter().filter(|p| p.starts_with("p-") && *p != "p-turn~resume-1").collect();
    assert_eq!(mine, ["p-b", "p-a"], "{order:?}");
    let _ = std::fs::remove_dir_all(&dir);
}
