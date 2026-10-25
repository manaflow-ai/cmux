//! A running turn whose model went quiet for good (`hub/stalled_turn.rs`): past `stalledTurnMs`
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

/// Prompts `id` with `text` and waits until its model said `word`.
async fn start(c: &mut TestClient, id: &str, text: &str, word: &str) {
    c.send(method::SESSION_PROMPT, prompt(id, text, None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| {
        p["sessionId"] == id && p["update"]["content"]["text"] == word
    })
    .await;
}

/// huge-blue, 2026-10-25: 77 Codex chats read `running` for a day, each turn waiting on a model
/// request that never came back. A turn nobody holds ends `stalledTurnMs` after its model's last
/// sign; one a client shows waits until it lets go; 0 turns the check off.
#[tokio::test]
async fn a_turn_whose_model_went_quiet_ends_as_stalled_unless_someone_holds_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    hub.config.write().await.stalled_turn_ms = Some(60_000);
    let free = new_session(&mut c, "stall-free").await;
    let held = new_session(&mut c, "stall-held").await;
    // "hang": one word, then nothing, and no answer to the cancel.
    start(&mut c, &free, "hang", "working").await;
    start(&mut c, &held, "hang", "working").await;
    c.request(method::MUX_DETACH, json!({"sessionId": free})).await.unwrap();
    let settle = || tokio::time::sleep(Duration::from_millis(200));

    clock.advance(Duration::from_secs(59));
    settle().await;
    assert!(results(&hub, &free).is_empty(), "ended before stalledTurnMs");

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
    hub.config.write().await.stalled_turn_ms = Some(0);
    let off = new_session(&mut c, "stall-off").await;
    start(&mut c, &off, "hang", "working").await;
    c.request(method::MUX_DETACH, json!({"sessionId": off})).await.unwrap();
    clock.advance(Duration::from_secs(24 * 3600));
    settle().await;
    assert!(results(&hub, &off).is_empty(), "stalledTurnMs 0 still ended a turn");
}

/// A turn whose owner (the session its `spawnedBy` tag names) is running may be what that owner
/// waits on: it is not ended until the owner is done.
#[tokio::test]
async fn a_stalled_turn_waits_while_its_owner_is_busy() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    hub.config.write().await.stalled_turn_ms = Some(60_000);
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
    hub.config.write().await.stalled_turn_ms = Some(600);
    let id = new_session(&mut c, "stall-ticking").await;
    // Ten words 250 ms apart: 2.5 s of turn, never 600 ms of silence. Nobody holds it.
    start(&mut c, &id, "ticking:10:250", "tick0 ").await;
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    let ended = until_results(&hub, &id, 1).await;
    assert_eq!(ended.len(), 1, "{ended:?}");
    assert_eq!(ended[0]["status"], "completed", "{ended:?}");
}
