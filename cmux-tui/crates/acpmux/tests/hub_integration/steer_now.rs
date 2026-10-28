//! Send now into a Claude chat's running turn (Leo, 2026-10-20): Claude Code reads a steer when
//! its current step ends, and Send now stops that step so it reads the message at once. The turn
//! runs on and ends as the agent ends it, not as stopped. fake_claude.py's "long-step" is one
//! step that runs until the interrupt, with Claude Code's order of lines. Tests by steer-default
//! (cmux/steer-now, ad34433a).

use super::*;

async fn claude_hub() -> (Arc<Hub>, TestClient, String) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let home = std::env::temp_dir().join(format!("steer-now-{}", uuid::Uuid::now_v7()));
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

fn said(seen: &[(String, Value)], text: &str) -> bool {
    seen.iter().any(|(m, p)| m == method::SESSION_UPDATE && p["update"]["content"]["text"] == text)
}

/// Starts the long step from the session's own connection; returns the turn prompt's request id.
async fn long_step(c: &mut TestClient, id: &str) -> i64 {
    let turn = c.send(method::SESSION_PROMPT, prompt(id, "p-turn", "long-step", false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "stepping").await;
    turn
}

/// `_acpmux/queue_edit` `send_now` from another client (the pane's button).
async fn send_now(hub: &Arc<Hub>, id: &str, prompt_id: &str) -> Value {
    let mut e = connect(hub).await;
    e.request(
        "_acpmux/queue_edit",
        json!({"sessionId": id, "promptId": prompt_id, "op": "send_now"}),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn send_now_for_a_waiting_steer_stops_the_step_and_the_turn_runs_on() {
    let (hub, mut c, id) = claude_hub().await;
    let turn = long_step(&mut c, &id).await;
    let mut a = connect(&hub).await;
    a.send(method::SESSION_PROMPT, prompt(&id, "p-steer", "PINEAPPLE", true)).await;
    let accepted = a.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-steer").await;
    assert_eq!(accepted["steer"], true, "{accepted}");

    let sent = send_now(&hub, &id, "p-steer").await;
    assert_eq!((sent["ok"].clone(), sent["sent"].clone()), (json!(true), json!("now")), "{sent}");
    let (answer, seen) = c.response(turn).await;
    assert!(said(&seen, "read: PINEAPPLE"), "the agent never read the steer: {seen:?}");
    assert_eq!(answer.unwrap()["stopReason"], "end_turn", "the turn read as stopped");
}

#[tokio::test]
async fn send_now_for_a_queued_prompt_steers_it_in_at_once() {
    let (hub, mut c, id) = claude_hub().await;
    let turn = long_step(&mut c, &id).await;
    let mut a = connect(&hub).await;
    a.send(method::SESSION_PROMPT, prompt(&id, "p-queued", "MANGO", false)).await;
    let accepted = a.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-queued").await;
    assert_eq!(accepted["queued"], true, "{accepted}");

    let sent = send_now(&hub, &id, "p-queued").await;
    assert_eq!(sent["sent"], "steer", "{sent}");
    let (answer, seen) = c.response(turn).await;
    assert!(said(&seen, "read: MANGO"), "the agent never read it: {seen:?}");
    assert_eq!(answer.unwrap()["stopReason"], "end_turn", "the turn read as stopped");
}

/// Stop stays a Stop: the steer it finds unread is read, and its turn ends stopped.
#[tokio::test]
async fn stop_with_a_steer_waiting_still_ends_the_turn_stopped() {
    let (hub, mut c, id) = claude_hub().await;
    let turn = long_step(&mut c, &id).await;
    let mut a = connect(&hub).await;
    a.send(method::SESSION_PROMPT, prompt(&id, "p-steer", "PINEAPPLE", true)).await;
    a.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-steer").await;
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "cancelled");
}

/// The X on a steer Claude Code has not read (Leo, 2026-10-21: "THERE'S A CANCEL AND EDIT BY
/// CLICKING THE X BUTTON ON THE SENT MESSAGES TO CLAUDE"): `withdraw` drops it from Claude Code's
/// queue, its prompt answers `withdrawn`, the log says so (`steer_withdrawn`), and the agent never
/// reads it.
#[tokio::test]
async fn withdraw_takes_back_a_steer_the_agent_has_not_read() {
    let (hub, mut c, id) = claude_hub().await;
    let turn = long_step(&mut c, &id).await;
    let mut a = connect(&hub).await;
    let steer = a.send(method::SESSION_PROMPT, prompt(&id, "p-steer", "PINEAPPLE", true)).await;
    a.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-steer").await;

    let mut e = connect(&hub).await;
    let edit = json!({"sessionId": id, "promptId": "p-steer", "op": "withdraw"});
    let took = e.request("_acpmux/queue_edit", edit.clone()).await.unwrap();
    assert_eq!(took["ok"], true, "{took}");
    let (answer, _) = a.response(steer).await;
    assert_eq!(answer.unwrap()["stopReason"], "withdrawn");
    let page = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
        .await
        .unwrap();
    let records = page["events"].as_array().unwrap();
    assert!(
        records.iter().any(|r| r["kind"] == "steer_withdrawn" && r["msg"]["promptId"] == "p-steer"),
        "{page}"
    );
    // Taken back already: a second X takes nothing.
    let again = e.request("_acpmux/queue_edit", edit).await.unwrap();
    assert_eq!(again["ok"], false, "{again}");

    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (_, seen) = c.response(turn).await;
    assert!(!said(&seen, "read: PINEAPPLE"), "the agent read the withdrawn steer: {seen:?}");
}

/// A send-now whose turn ended before the agent took it runs next (`steer_end.rs`), but it stops
/// only the turn it was aimed at. A turn that began meanwhile, such as another agent's queued
/// message, runs on (Leo, 2026-10-21: "me sending that ... might have accidentally swallowed up
/// a queued message").
#[tokio::test]
async fn a_send_now_that_missed_its_turn_does_not_stop_the_turn_after_it() {
    let (hub, mut c, id) = claude_hub().await;
    let turn = long_step(&mut c, &id).await;
    let session = hub.resolve(&id).unwrap();
    let running = session.turn().expect("the long step runs").turn_id;
    // The fallback's options: a send-now aimed at a turn that has ended.
    let opts = acpmux::hub::PromptOptions {
        prompt_id: Some("p-late".into()),
        interrupt: true,
        interrupt_turn: Some("t-ended".into()),
        ..Default::default()
    };
    let late = tokio::spawn({
        let (hub, session) = (hub.clone(), session.clone());
        async move {
            let blocks = vec![json!({"type": "text", "text": "LATE"})];
            hub.prompt_with(&session, blocks, "pane", false, opts).await
        }
    });
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(
        session.turn().map(|t| t.turn_id),
        Some(running),
        "the send-now stopped a turn it was not aimed at"
    );
    // It still goes next: Stop ends the long step, and LATE runs.
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (answer, _) = c.response(turn).await;
    assert_eq!(answer.unwrap()["stopReason"], "cancelled");
    let late = tokio::time::timeout(Duration::from_secs(20), late).await.unwrap().unwrap();
    assert!(late.is_ok(), "the send-now never ran: {late:?}");
}

/// In a chat several people share (`author.rs`), only the person who sent a steer takes it back:
/// another person, or the owner, gets `queue.not_author`, and the steer stays.
#[tokio::test]
async fn only_the_sender_takes_back_a_persons_steer() {
    let (hub, mut c, id) = claude_hub().await;
    let turn = long_step(&mut c, &id).await;
    let ana = json!({"id": "tailnet:ana@example.com", "name": "Ana"});
    let mut a = connect(&hub).await;
    let mut steer = prompt(&id, "p-steer", "PINEAPPLE", true);
    steer["_meta"]["acpmux"]["author"] = ana.clone();
    let steered = a.send(method::SESSION_PROMPT, steer).await;
    a.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-steer").await;

    let mut e = connect(&hub).await;
    let withdraw = |author: Option<&Value>| {
        let mut p = json!({"sessionId": id, "promptId": "p-steer", "op": "withdraw"});
        if let Some(author) = author {
            p["_meta"] = json!({"acpmux": {"author": author}});
        }
        p
    };
    for other in [Some(json!({"id": "user_bo", "name": "Bo"})), None] {
        let refused = e.request("_acpmux/queue_edit", withdraw(other.as_ref())).await;
        assert!(
            refused.as_ref().is_err_and(|m| m.starts_with("queue.not_author")),
            "{other:?}: {refused:?}"
        );
    }
    let took = e.request("_acpmux/queue_edit", withdraw(Some(&ana))).await.unwrap();
    assert_eq!(took["ok"], true, "{took}");
    let (answer, _) = a.response(steered).await;
    assert_eq!(answer.unwrap()["stopReason"], "withdrawn");
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (_, seen) = c.response(turn).await;
    assert!(!said(&seen, "read: PINEAPPLE"), "the agent read the withdrawn steer: {seen:?}");
}

/// A steer that asks to be read now when it is sent (`_meta.acpmux.steerNow`): the Chief's tell
/// (Lawrence, 2026-10-26: a Chief message lands in the agent's chat "with interrupt by default").
/// It stops the agent's current step as the pane's Send now does, without a second request, and
/// the turn runs on. A steer without it still waits for the step (the tests above).
#[tokio::test]
async fn a_steer_sent_with_steer_now_stops_the_step_at_once() {
    let (hub, mut c, id) = claude_hub().await;
    let turn = long_step(&mut c, &id).await;
    let mut a = connect(&hub).await;
    let mut steer = prompt(&id, "p-now", "PINEAPPLE", true);
    steer["_meta"]["acpmux"]["steerNow"] = json!(true);
    a.send(method::SESSION_PROMPT, steer).await;
    let accepted = a.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-now").await;
    assert_eq!(accepted["steer"], true, "{accepted}");
    // The long step runs until it is stopped: without steerNow the turn never ends.
    let ended = tokio::time::timeout(std::time::Duration::from_secs(20), c.response(turn)).await;
    let (answer, seen) = ended.expect("steerNow did not stop the step: the turn still runs");
    assert!(said(&seen, "read: PINEAPPLE"), "the agent never read the steer: {seen:?}");
    assert_eq!(answer.unwrap()["stopReason"], "end_turn", "the turn read as stopped");
}
