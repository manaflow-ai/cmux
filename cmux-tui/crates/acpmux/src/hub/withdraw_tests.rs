use super::*;

/// A hub (store in memory, the queue path before the inbox) with one chat whose turn `t-1`
/// runs another agent's message `m-1`; its agent does not steer, so a retraction queues.
fn chat_running_a_message() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: crate::config::Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    cfg.agent_inbox = Some(false);
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": "s-1", "name": "s-1",
        "harness": "fake", "family": "codex", "cwd": std::env::temp_dir(), "status": "running",
        "createdAt": 1, "updatedAt": 1});
    let session = hub.insert_test_session(serde_json::from_value(meta).unwrap());
    hub.save_meta(&session);
    let provenance = json!({"kind": "agent_message", "from": "acp:sender-1", "to": "acp:s-1",
                            "msgId": "msg-1", "threadId": "thread-1"});
    let msg = json!({"text": "do x", "client": "acpmux", "promptId": "m-1", "turnId": "t-1"});
    let msg = crate::prompt_provenance::marked(msg, Some(&provenance));
    hub.append(&session, "mux", "user_message", msg);
    let turn = TurnInfo::prompted("acpmux", "do x", "t-1", "m-1", Control::Local);
    *session.turn.lock().unwrap() = Some(turn);
    (hub, session)
}

fn withdraw(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let (hub, session) = (hub.clone(), session.clone());
    tokio::spawn(async move { hub.prompt_withdraw(&session, &json!({"promptId": "m-1"})).await })
}

/// The `queued` records of retraction notices.
fn notices(hub: &Hub) -> usize {
    let records = hub.events("s-1", 0, 100_000).unwrap();
    let notice = |r: &&EventRecord| {
        r.kind == "queued"
            && r.msg["promptId"].as_str().is_some_and(|id| id.starts_with("m-1.withdrawn."))
    };
    records.iter().filter(notice).count()
}

/// The notice's accept waits behind the chat's agent slot, which a spawn, a respawn or a mode
/// change holds (on the owner's Mac, at load 150 to 430, for longer than any fixed wait). The
/// withdraw answered `withdraw.notice_failed` after 5 s, and the notice then went in: the
/// sender was told to withdraw again for a retraction the agent got. Now the notice is queued
/// durably once its answer is due (`prompt_admission.rs`), so the withdraw answers retracted
/// while the slot is still held; a second withdraw answers as the first, with no second notice.
#[tokio::test(start_paused = true)]
async fn a_notice_slower_than_any_fixed_wait_is_retracted_once_not_failed() {
    let (hub, session) = chat_running_a_message();
    let slot = session.child.lock().await;
    let first = withdraw(&hub, &session);
    tokio::time::sleep(Duration::from_secs(1)).await;
    let second = withdraw(&hub, &session);
    let bound = super::prompt_admission::ANSWER_BOUND + Duration::from_secs(4);
    let reply = tokio::time::timeout(bound, first)
        .await
        .expect("the withdraw is answered while the slot is held")
        .unwrap()
        .expect("the withdraw failed");
    assert_eq!(
        (&reply["outcome"], &reply["via"]),
        (&json!("retracted"), &json!("queued")),
        "{reply}"
    );
    let again = tokio::time::timeout(bound, second)
        .await
        .expect("the second withdraw is answered")
        .unwrap()
        .expect("the second withdraw failed");
    assert_eq!(
        (&again["outcome"], &again["already"]),
        (&json!("retracted"), &json!(true)),
        "{again}"
    );
    drop(slot);
    assert_eq!(notices(&hub), 1, "one retraction notice");
    let records = hub.events("s-1", 0, 100_000).unwrap();
    let retracted = records.iter().filter(|r| r.kind == "prompt_retracted").count();
    assert_eq!(retracted, 1, "one prompt_retracted record");
}
