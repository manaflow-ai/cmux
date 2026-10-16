//! Pending prompt identities outlive the bounded cache of completed outcomes.

use super::*;

#[cfg(unix)]
async fn retry_behind_a_full_queue(resend: bool) {
    let gate = std::env::temp_dir().join(format!("acpmux-ledger-gate-{}", uuid::Uuid::now_v7()));
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "ledger-pressure").await;
    c.send(
        method::SESSION_PROMPT,
        prompt_with_id(&id, &format!("gate: {}", gate.display()), "p-gate", false),
    )
    .await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-gate").await;

    // The oldest queued identity must survive even with more than 64 pending prompts.
    let mut first_turn = Value::Null;
    for i in 0..65 {
        let prompt_id = format!("p-queued-{i}");
        c.send(method::SESSION_PROMPT, prompt_with_id(&id, "hi", &prompt_id, false)).await;
        let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == prompt_id).await;
        assert_eq!(accepted["queued"], true);
        if i == 0 {
            first_turn = accepted["turnId"].clone();
        }
    }

    let mut retry = connect(&hub).await;
    let request = retry
        .send(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-queued-0", resend))
        .await;
    let accepted = retry.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-queued-0").await;
    let early = tokio::time::timeout(Duration::from_millis(50), retry.response(request)).await.ok();

    // Open the gate before asserting, so even a failing regression shuts the fake agent down.
    let gate_write = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(gate_write, b"open")).await.unwrap().unwrap();
    let replied_early = early.is_some();
    let reply = match early {
        Some((reply, _)) => reply.unwrap(),
        None => retry.response(request).await.0.unwrap(),
    };
    // A final turn drains the original queue and any accidental retry queued behind it.
    c.request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-drained", false)).await.unwrap();
    let records = hub.events(&id, 0, 10_000).unwrap();
    let runs = records
        .iter()
        .filter(|e| e.kind == "user_message" && e.msg["promptId"] == "p-queued-0")
        .count();
    hub.shutdown_all().await;
    let _ = std::fs::remove_file(gate);

    assert_eq!(accepted["duplicate"], true, "retry acquired another queue entry: {accepted}");
    assert!(!replied_early, "a pending prompt was reported as finished: {reply}");
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["duplicate"], true, "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["turnId"], first_turn, "{reply}");
    assert_eq!(runs, 1, "retry ran the oldest queued prompt more than once");
}

#[cfg(unix)]
#[tokio::test]
async fn prompt_ledger_keeps_live_pending_identity_without_resend() {
    retry_behind_a_full_queue(false).await;
}

#[cfg(unix)]
#[tokio::test]
async fn prompt_ledger_keeps_live_pending_identity_with_resend() {
    retry_behind_a_full_queue(true).await;
}

#[tokio::test]
async fn prompt_ledger_keeps_recovered_pending_identity_until_withdrawn() {
    use acpmux::store::EventRecord;

    let dir = std::env::temp_dir().join(format!("acpmux-ledger-restart-{}", uuid::Uuid::now_v7()));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, "ledger-restart").await;
    let last = hub.session_summary(&hub.resolve(&id).unwrap())["lastSeq"].as_u64().unwrap();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // A stopped daemon's durable log has 65 accepted, not yet dispatched prompts.
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    for i in 0..65 {
        store
            .append(
                &id,
                &EventRecord {
                    seq: last + i + 1,
                    at: 0,
                    dir: "mux".into(),
                    kind: "queued".into(),
                    msg: json!({"promptId": format!("p-restored-{i}"), "turnId": format!("t-restored-{i}"),
                        "client": "test", "text": "hi", "prompt": [{"type": "text", "text": "hi"}]}),
                    host_seq: None,
                },
            )
            .unwrap();
    }
    let hub = Hub::new(cfg, store);
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["queued"], 65);
    let mut retry = connect(&hub).await;
    let request = retry
        .send(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-restored-0", true))
        .await;
    retry.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-restored-0").await;
    assert!(hub.remove_queued(&session, "p-restored-0"));
    let reply = retry.response(request).await.0.unwrap();
    let records = hub.events(&id, 0, 10_000).unwrap();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(dir);

    assert_eq!(reply["stopReason"], "cancelled", "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["withdrawn"], true, "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["duplicate"], true, "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["turnId"], "t-restored-0", "{reply}");
    assert!(records.iter().all(|e| e.kind != "user_message"), "a restored retry ran a turn");
}
