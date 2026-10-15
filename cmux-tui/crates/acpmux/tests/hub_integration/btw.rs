//! `_acpmux/btw`: a side session about a chat (`hub/btw.rs`, the composer's
//! `/btw`). It opens beside a running chat without touching it, titled with
//! the question, tagged `side`, read-only and on a cheap model, and starts
//! from the chat's conversation: a fork through its latest finished turn
//! (Claude, Codex), else the chat's transcript as hidden context.

use super::*;

const BTW: &str = "_acpmux/btw";

fn prompt(id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]})
}

async fn new_chat(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

fn turns_ended(hub: &Arc<Hub>, id: &str) -> usize {
    hub.events(id, 0, 10_000).unwrap().iter().filter(|e| e.kind == "turn_result").count()
}

/// The answer of the session's turn number `turns` (its text after its last
/// prompt), once that turn ended.
async fn answer(hub: &Arc<Hub>, id: &str, turns: usize) -> String {
    for _ in 0..500 {
        if turns_ended(hub, id) >= turns {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(turns_ended(hub, id) >= turns, "the side session's turn ended");
    let events = hub.events(id, 0, 10_000).unwrap();
    let last = events.iter().rev().find(|e| e.kind == "user_message").map_or(0, |e| e.seq);
    events
        .iter()
        .filter(|e| e.seq > last && e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect()
}

fn prompts(hub: &Arc<Hub>, id: &str) -> Vec<String> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "user_message")
        .filter_map(|e| e.msg.get("text").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

fn side_of(hub: &Arc<Hub>, id: &str) -> Option<String> {
    hub.resolve(id).unwrap().meta().tags.get("side").map(|t| t.value.clone())
}

#[tokio::test]
async fn a_side_session_opens_beside_a_running_claude_chat_and_never_disturbs_it() {
    let root = std::env::temp_dir().join(format!("acpmux-btw-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let id = new_chat(&mut c).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "first")).await.unwrap();
    let gate = root.join("gate");
    let held = format!("hold: {}", gate.display());
    c.send(method::SESSION_PROMPT, prompt(&id, &held)).await;
    for _ in 0..250 {
        if user_messages(&hub, &id) == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(user_messages(&hub, &id), 2, "the second turn started");
    let chat_before = hub.session_summary(&hub.resolve(&id).unwrap());

    let side = c
        .request(BTW, json!({"sessionId": id, "question": "  What did I ask first?\nAnd why?  "}))
        .await
        .unwrap();
    let sid = side["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(sid, id);
    assert_eq!(side["model"], "haiku", "Claude's cheap model: {side}");
    assert_eq!(side["readOnly"], "mode", "{side}");
    let meta = hub.resolve(&sid).unwrap().meta();
    assert_eq!(meta.title.as_deref(), Some("What did I ask first?"), "titled with the question");
    assert_eq!(side_of(&hub, &sid).as_deref(), Some(id.as_str()), "tagged side with its chat");
    assert_eq!(meta.cwd, hub.resolve(&id).unwrap().meta().cwd);
    assert_eq!(meta.permission_policy.as_deref(), Some("approve-reads"));
    assert_eq!(meta.modes.as_ref().unwrap()["currentModeId"], "plan", "Claude's read-only mode");

    // The question runs in the side session, on the cheap model, while the chat's turn runs.
    let argv: Vec<String> = serde_json::from_str(&answer(&hub, &sid, 2).await).unwrap();
    assert!(argv.windows(2).any(|w| w == ["--model", "haiku"]), "{argv:?}");
    assert!(hub.resolve(&id).unwrap().turn().is_some(), "the chat's turn still runs");
    assert_eq!(
        prompts(&hub, &sid).last().map(String::as_str),
        Some("What did I ask first?\nAnd why?")
    );
    // Its conversation holds the chat's finished turn and its own question, never the
    // running one.
    let seen = claude_history(&hub, &mut c, &sid).await;
    assert_eq!(seen["prompts"], json!(["first", "What did I ask first?\nAnd why?"]), "{seen}");

    // The chat's turn ends as it would have, and nothing of the side session is in it.
    std::fs::write(&gate, "").unwrap();
    for _ in 0..250 {
        if turns_ended(&hub, &id) == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(turns_ended(&hub, &id), 2, "the running turn ends as it would have");
    assert_eq!(prompts(&hub, &id), vec!["first".to_owned(), held.clone()]);
    let chat_after = hub.session_summary(&hub.resolve(&id).unwrap());
    for key in ["title", "policy", "rules", "tags", "modes", "models", "harness", "cwd"] {
        assert_eq!(chat_after.get(key), chat_before.get(key), "the chat's {key} is unchanged");
    }
    let own = claude_history(&hub, &mut c, &id).await;
    assert_eq!(own["prompts"], json!(["first", held]), "the chat's conversation never saw it");

    // An empty question and an unknown chat open nothing.
    let sessions = hub.sessions().len();
    let blank = c.request(BTW, json!({"sessionId": id, "question": " \n "})).await.unwrap_err();
    assert!(blank.contains("question is required"), "{blank}");
    let missing = c.request(BTW, json!({"sessionId": id})).await.unwrap_err();
    assert!(missing.contains("question is required"), "{missing}");
    let unknown = c.request(BTW, json!({"sessionId": "no-such-chat", "question": "q"})).await;
    assert!(unknown.is_err(), "{unknown:?}");
    assert_eq!(hub.sessions().len(), sessions, "a refused side session opens nothing");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_side_session_of_a_harness_that_cannot_fork_reads_the_chat_and_never_writes() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_chat(&mut c).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello")).await.unwrap();
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;

    let side =
        c.request(BTW, json!({"sessionId": id, "question": "what was that?"})).await.unwrap();
    let sid = side["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(side["readOnly"], "policy", "this harness has no read-only mode: {side}");
    assert!(side["model"].is_null(), "this harness's own model: {side}");
    let meta = hub.resolve(&sid).unwrap().meta();
    assert_eq!(meta.harness, "fake");
    assert_eq!(meta.title.as_deref(), Some("what was that?"));
    assert_eq!(side_of(&hub, &sid).as_deref(), Some(id.as_str()));
    assert_eq!(meta.permission_policy.as_deref(), Some("approve-reads"));

    // Its first prompt carries the chat's transcript as hidden context: the agent reads it,
    // the side session's thread shows only the question.
    let echoed = answer(&hub, &sid, 1).await;
    assert!(echoed.starts_with("echo: what was that?<cmux-btw-context>"), "{echoed}");
    for line in
        ["User: hello", "Assistant: echo: hello", "User: until-cancel", "Assistant: running"]
    {
        assert!(echoed.contains(line), "{line:?} in {echoed}");
    }
    assert_eq!(prompts(&hub, &sid), vec!["what was that?".to_owned()]);

    // Read-only: a tool call that runs something is refused, never asked.
    let write =
        c.request(BTW, json!({"sessionId": id, "question": "ask: rm notes.txt"})).await.unwrap();
    let wid = write["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(answer(&hub, &wid, 1).await, "chose no", "the write was refused");

    // The chat still runs its turn, untouched.
    assert!(hub.resolve(&id).unwrap().turn().is_some(), "the chat's turn still runs");
    assert_eq!(prompts(&hub, &id), vec!["hello".to_owned(), "until-cancel".to_owned()]);
    assert_eq!(hub.sessions().len(), 3, "the chat and its two side sessions");
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_side_session_takes_the_asked_model_then_the_configured_one_then_the_harness_default() {
    let calls = std::env::temp_dir().join(format!("acpmux-btw-calls-{}", uuid::Uuid::now_v7()));
    let env = BTreeMap::from([
        ("FAKE_PICKER".to_owned(), "1".to_owned()),
        ("FAKE_CALLS".to_owned(), calls.to_string_lossy().into_owned()),
    ]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_chat(&mut c).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hi")).await.unwrap();

    let asked = c
        .request(BTW, json!({"sessionId": id, "question": "q1", "model": "asked-model"}))
        .await
        .unwrap();
    assert_eq!(asked["model"], "asked-model", "{asked}");
    hub.config.write().await.btw.model.insert("fake".into(), "configured-model".into());
    let configured = c.request(BTW, json!({"sessionId": id, "question": "q2"})).await.unwrap();
    assert_eq!(configured["model"], "configured-model", "{configured}");
    hub.config.write().await.btw.model.clear();
    let plain = c.request(BTW, json!({"sessionId": id, "question": "q3"})).await.unwrap();
    assert!(plain["model"].is_null(), "the harness's own default: {plain}");

    let set: Vec<String> = std::fs::read_to_string(&calls)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|c| c["method"] == "session/set_model")
        .filter_map(|c| c["params"]["modelId"].as_str().map(str::to_owned))
        // Only the side sessions' models (a start default is the harness's business).
        .filter(|m| m.ends_with("-model"))
        .collect();
    assert_eq!(set, vec!["asked-model".to_owned(), "configured-model".to_owned()]);
    for side in [&asked, &configured, &plain] {
        let sid = side["sessionId"].as_str().unwrap();
        assert_eq!(side_of(&hub, sid).as_deref(), Some(id.as_str()));
    }

    let bad = c.request(BTW, json!({"sessionId": id, "question": "q", "model": 3})).await;
    assert!(bad.unwrap_err().contains("model must be a string"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_file(&calls);
}
