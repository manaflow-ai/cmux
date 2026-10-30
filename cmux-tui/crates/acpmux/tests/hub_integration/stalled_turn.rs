//! A running turn whose model went quiet for good (`hub/stalled_turn.rs`): past `stalledTurnEndMs`
//! with no sign of its model and nobody holding it, acpmux ends it as failed, `stalled`.

use super::*;

/// The turn results in `id`'s log.
fn results(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    find(&hub.events(id, 0, 10_000).unwrap(), "turn_result").iter().map(|e| e.msg.clone()).collect()
}

/// Waits (test polling, real time) until `id`'s log has `n` turn results.
async fn until_results(hub: &Arc<Hub>, id: &str, n: usize) -> Vec<Value> {
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        let got = results(hub, id);
        if got.len() >= n {
            return got;
        }
        assert!(std::time::Instant::now() < deadline, "no turn result in {id}: {got:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Waits (test polling, real time) until `id`'s log has a record `pred` accepts.
async fn until_event(hub: &Arc<Hub>, id: &str, pred: impl Fn(&acpmux::store::EventRecord) -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while !hub.events(id, 0, 10_000).unwrap().iter().any(&pred) {
        assert!(std::time::Instant::now() < deadline, "no such record in {id}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Prompts `id` with `text` and waits until its model said `word`.
async fn start(c: &mut TestClient, id: &str, text: &str, word: &str) {
    c.send(method::SESSION_PROMPT, prompt(id, text, None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["sessionId"] == id && p["update"]["content"]["text"] == word
    })
    .await;
}

/// huge-blue, 2026-10-25: 72 Codex chats read `running` for a day, each turn waiting on a model
/// request that never came back. A turn nobody holds ends `stalledTurnEndMs` after its model's last
/// sign; one a client shows waits until it lets go; 0 turns the check off.
#[tokio::test]
async fn a_turn_whose_model_went_quiet_ends_as_stalled_unless_someone_holds_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    hub.config.write().await.stalled_turn_end_ms = Some(60_000);
    let free = new_session(&mut c, "stall-free").await;
    let held = new_session(&mut c, "stall-held").await;
    // "hang": one word, then nothing, and no answer to the cancel.
    start(&mut c, &free, "hang", "working").await;
    start(&mut c, &held, "hang", "working").await;
    c.request(method::MUX_DETACH, json!({"sessionId": free})).await.unwrap();
    let settle = || tokio::time::sleep(Duration::from_millis(200));

    clock.advance(Duration::from_secs(59));
    settle().await;
    assert!(results(&hub, &free).is_empty(), "ended before stalledTurnEndMs");

    clock.advance(Duration::from_secs(2));
    let ended = until_results(&hub, &free, 1).await;
    assert_eq!(ended[0]["status"], "failed", "{ended:?}");
    assert_eq!(ended[0]["detail"], "stalled", "{ended:?}");
    assert_eq!(ended[0]["errorSource"], "acpmux", "{ended:?}");
    assert!(ended[0]["stalledMs"].as_u64().unwrap() >= 60_000, "{ended:?}");
    let summary = hub.session_summary(&hub.resolve("stall-free").unwrap());
    assert_eq!(summary["status"], "ready", "{summary}");
    assert_eq!(summary["lastTurn"]["detail"], "stalled", "{summary}");
    assert!(summary["turn"].is_null(), "{summary}");
    // The client that shows the other chat holds its turn.
    settle().await;
    assert!(results(&hub, &held).is_empty(), "a turn a client shows was ended");

    // Let go: looked at again a period later, then ended.
    c.request(method::MUX_DETACH, json!({"sessionId": held})).await.unwrap();
    clock.advance(Duration::from_secs(61));
    let ended = until_results(&hub, &held, 1).await;
    assert_eq!(ended[0]["detail"], "stalled", "{ended:?}");

    // 0: never.
    hub.config.write().await.stalled_turn_end_ms = Some(0);
    let off = new_session(&mut c, "stall-off").await;
    start(&mut c, &off, "hang", "working").await;
    c.request(method::MUX_DETACH, json!({"sessionId": off})).await.unwrap();
    clock.advance(Duration::from_secs(24 * 3600));
    settle().await;
    assert!(results(&hub, &off).is_empty(), "stalledTurnEndMs 0 still ended a turn");
}

/// A turn whose owner (the session its `spawnedBy` tag names) is running may be what that owner
/// waits on: it is not ended until the owner is done.
#[tokio::test]
async fn a_stalled_turn_waits_while_its_owner_is_busy() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    hub.config.write().await.stalled_turn_end_ms = Some(60_000);
    let owner = new_session(&mut c, "stall-owner").await;
    let child = new_session(&mut c, "stall-child").await;
    c.request(method::MUX_TAG, json!({"sessionId": child, "set": {"spawnedBy": owner}}))
        .await
        .unwrap();
    start(&mut c, &owner, "until-cancel", "running").await;
    start(&mut c, &child, "hang", "working").await;
    c.request(method::MUX_DETACH, json!({"sessionId": child})).await.unwrap();

    clock.advance(Duration::from_secs(61));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(results(&hub, &child).is_empty(), "ended while its owner was busy");

    // The owner's turn ends; the child's is looked at again a period later.
    c.send(method::SESSION_CANCEL, json!({"sessionId": owner})).await;
    until_results(&hub, &owner, 1).await;
    clock.advance(Duration::from_secs(61));
    let ended = until_results(&hub, &child, 1).await;
    assert_eq!(ended[0]["detail"], "stalled", "{ended:?}");
}

/// A model that keeps showing signs of work is never stalled, however long its turn runs: each
/// sign starts the count again.
#[tokio::test]
async fn a_turn_whose_model_keeps_working_is_not_stalled() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.stalled_turn_end_ms = Some(600);
    let id = new_session(&mut c, "stall-ticking").await;
    // Ten words 250 ms apart: 2.5 s of turn, never 600 ms of silence. Nobody holds it.
    start(&mut c, &id, "ticking:10:250", "tick0 ").await;
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    let ended = until_results(&hub, &id, 1).await;
    assert_eq!(ended.len(), 1, "{ended:?}");
    assert_eq!(ended[0]["status"], "completed", "{ended:?}");
}

/// A long command that prints nothing is work: a turn quiet inside a tool call that has not
/// ended gets four periods, and then a tool that never ends no longer holds it.
#[tokio::test]
async fn a_turn_quiet_inside_an_open_tool_call_gets_four_periods() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    hub.config.write().await.stalled_turn_end_ms = Some(60_000);
    let id = new_session(&mut c, "stall-tool").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "tool-hang", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["sessionId"] == id && p["update"]["toolCallId"] == "th-1"
    })
    .await;
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();

    clock.advance(Duration::from_secs(61));
    tokio::time::sleep(Duration::from_millis(200)).await;
    clock.advance(Duration::from_secs(120));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(results(&hub, &id).is_empty(), "a turn inside a running tool was ended at 3 min");

    clock.advance(Duration::from_secs(60));
    let ended = until_results(&hub, &id, 1).await;
    assert_eq!(ended[0]["detail"], "stalled", "{ended:?}");
    assert!(ended[0]["stalledMs"].as_u64().unwrap() >= 240_000, "{ended:?}");
}

/// A turn that failed over to its fallback profile (an authentication failure) and whose fallback then went
/// quiet still ends: the fallback's prompt takes the forced end too.
#[tokio::test]
async fn a_turn_that_went_quiet_on_its_fallback_profile_ends_as_stalled() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |fallback: Option<&str>, env: &[(&str, &str)]| HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
        description: None,
        fallback: fallback.map(str::to_owned),
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut agents = BTreeMap::new();
    agents.insert("fake".to_owned(), profile(Some("fake-pool"), &[("FAKE_AUTH_FAIL", "1")]));
    // The fallback loads the chat, and its replayed history holds a tool call that never
    // ended: not this turn's, so it gives no grace.
    let pool_env = [("FAKE_FALLBACK", "1"), ("FAKE_LOAD_REPLAY_TOOL", "1")];
    agents.insert("fake-pool".to_owned(), profile(None, &pool_env));
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg.stalled_turn_end_ms = Some(60_000);
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, "stall-failover").await;
    start(&mut c, &id, "limit-then-hang", "working").await;
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert_eq!(find(&events, "failover").len(), 1, "no failover");

    assert_eq!(find(&events, "resumed").len(), 1, "the fallback did not load the chat");

    clock.advance(Duration::from_secs(61));
    let ended = until_results(&hub, &id, 1).await;
    assert_eq!(ended[0]["detail"], "stalled", "{ended:?}");
    // It ended on the fallback's live agent: the chat is ready, so its idle agent can exit.
    let summary = hub.session_summary(&hub.resolve("stall-failover").unwrap());
    assert_eq!(summary["status"], "ready", "{summary}");
}

/// The last open tool call ending brings the turn's deadline back to one period after it: the
/// reaper, asleep until the four-period deadline, looks again.
#[tokio::test]
async fn a_tool_call_that_ends_brings_the_stalled_deadline_back() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    hub.config.write().await.stalled_turn_end_ms = Some(60_000);
    let id = new_session(&mut c, "stall-tool-done").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "tool-done-hang", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["sessionId"] == id && p["update"]["toolCallId"] == "tdh-1"
    })
    .await;
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    // Past one period inside the open tool call: the reaper looks, and sleeps until four.
    clock.advance(Duration::from_secs(61));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(results(&hub, &id).is_empty(), "ended inside its open tool call");
    // The tool call ends (1.5 s after it began, real time): one period from now, not four.
    until_event(&hub, &id, |e| e.msg.pointer("/params/update/status") == Some(&json!("completed")))
        .await;
    // Past its old one-period deadline (the model's word before the tool), yet counted from the
    // tool's end: not ended when the reaper wakes for it.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(results(&hub, &id).is_empty(), "counted from before the tool call ended");
    clock.advance(Duration::from_secs(61));
    let ended = until_results(&hub, &id, 1).await;
    assert_eq!(ended[0]["detail"], "stalled", "{ended:?}");
}

/// A turn whose prompt has not reached its agent is never stalled: its count starts when the
/// prompt is written, never from the previous turn's last word. Here the agent exited idle and
/// starts again slowly for the next turn; the reaper, woken by the new agent, must not send it a
/// cancel before its prompt.
#[tokio::test]
async fn a_turn_counts_from_its_prompt_being_written() {
    let env = BTreeMap::from([("FAKE_INIT_DELAY_MS".to_owned(), "1500".to_owned())]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(300)));
    hub.config.write().await.stalled_turn_end_ms = Some(60_000);
    let id = new_session(&mut c, "stall-written").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    // The agent exits idle; the last word was 5 min ago, past one period.
    clock.advance(Duration::from_secs(301));
    // The idle pass lists the processes under the harness first (`hub/idle_census.rs`).
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while hub.session_summary(&hub.resolve("stall-written").unwrap())["status"] != "idle" {
        assert!(std::time::Instant::now() < deadline, "the agent did not exit idle");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    // An unattended prompt: its client lets go while the agent still starts.
    let mut other = connect(&hub).await;
    other.send(method::SESSION_PROMPT, prompt(&id, "hang", None)).await;
    let session = hub.resolve("stall-written").unwrap();
    while hub.session_summary(&session)["turn"].is_null() {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    other.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    // Past a period while the agent still starts (1.5 s): the reaper looks now.
    clock.advance(Duration::from_secs(61));
    tokio::time::sleep(Duration::from_millis(200)).await;
    until_event(&hub, &id, |e| {
        e.msg.pointer("/params/update/content/text") == Some(&json!("working"))
    })
    .await;
    let events = hub.events(&id, 0, 10_000).unwrap();
    let cancels = events.iter().filter(|e| e.dir == "out" && e.kind == method::SESSION_CANCEL);
    assert_eq!(cancels.count(), 0, "a cancel went to an agent whose prompt was not written");
    assert!(
        results(&hub, &id).iter().all(|r| r["status"] == "completed"),
        "ended before its prompt"
    );

    clock.advance(Duration::from_secs(59));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(results(&hub, &id).len(), 1, "counted from before its prompt was written");
    clock.advance(Duration::from_secs(2));
    let ended = until_results(&hub, &id, 2).await;
    assert_eq!(ended[1]["detail"], "stalled", "{ended:?}");
}
