use super::*;
use crate::config::StoreMode;
use crate::hub::person::{ANSWERED_BY_SLOT, Answerer, REASON};

/// A hub with one stand-in session, and the connection that made it.
async fn hub_with_session() -> (Arc<Hub>, Arc<Session>, mpsc::Sender<String>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut out_rx) = mpsc::channel(256);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    in_tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
    loop {
        let line = out_rx.recv().await.expect("the session/new reply");
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply["id"] == 1 {
            let id = reply["result"]["sessionId"].as_str().expect("a session id").to_owned();
            let session = hub.resolve(&id).unwrap();
            return (hub, session, in_tx);
        }
    }
}

/// A pending prompt shaped like a question, recorded as `may` answer.
fn pending(session: &Session, may: bool) -> (String, oneshot::Receiver<Value>) {
    let mut request = json!({
        "toolCall": {"toolCallId": "t1", "kind": "execute", "status": "pending",
                     "rawInput": {"command": "rm -rf build",
                                  "questions": [{"question": "ok?", "options": [{"label": "yes"}]}]}},
        "options": [
            {"optionId": "go", "name": "Go", "kind": "allow_once"},
            {"optionId": "no", "name": "No", "kind": "reject_once"},
        ],
    });
    super::super::questions::normalize(
        &mut request,
        super::super::questions::PreviewFormat::Monospace,
    );
    let (reply, rx) = oneshot::channel();
    let id = uuid::Uuid::now_v7().to_string();
    let entry = PendingPermission {
        request,
        reply,
        decision_nonce: super::super::person::new_nonce(),
        ancestor_may_answer: may,
        prev_status: SessionStatus::Waiting,
        agent_request: None,
        agent_host_incarnation: None,
    };
    session.permissions.lock().unwrap().pending.insert(id.clone(), entry);
    (id, rx)
}

/// A Claude withdrawal removes only the card raised by that agent request.
#[tokio::test]
async fn an_agent_cancel_request_withdraws_its_pending_card() {
    let (hub, session, _conn) = hub_with_session().await;
    let (mine, rx) = pending(&session, false);
    let (other, _other_rx) = pending(&session, false);
    {
        let mut state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = state.pending.get_mut(&mine) {
            entry.agent_request = Some(json!(1007));
        }
        if let Some(entry) = state.pending.get_mut(&other) {
            entry.agent_request = Some(json!(1008));
        }
    }
    hub.withdraw_permission(&session, None, &json!(1007));
    let outcome = rx.await.unwrap_or(Value::Null);
    assert_eq!(outcome, json!({"outcome": "cancelled"}));
    {
        let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
        assert!(!state.pending.contains_key(&mine));
        assert!(state.pending.contains_key(&other));
    }
    let error = hub
        .respond_permission(
            &session,
            &mine,
            Some("go".into()),
            None,
            None,
            Answerer::default(),
            Control::Local,
        )
        .await
        .expect_err("the withdrawal won before this answer");
    assert_eq!(error.data, Some(json!({"answeredBy": null, "outcome": {"outcome": "cancelled"}})));
}

/// A cancellation can be read before the spawned permission handler gets
/// to its lock; the tombstone cancels the eventual card immediately.
#[tokio::test]
async fn an_agent_cancel_request_before_registration_is_consumed() {
    let (hub, session, _conn) = hub_with_session().await;
    hub.register_agent_request(&session, &json!(1009), None);
    hub.withdraw_permission(&session, None, &json!(1009));
    let request = json!({
        "toolCall": {"toolCallId": "e1", "kind": "other", "status": "pending"},
        "options": [{"optionId": "allow_once", "name": "Allow", "kind": "allow_once"}],
    });
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let outcome = hub
        .handle_permission_for(
            &session,
            request,
            epoch,
            session.turn().map(|t| t.turn_id),
            Some(&json!(1009)),
            None,
            None,
        )
        .await;
    assert_eq!(outcome, json!({"outcome": {"outcome": "cancelled"}}));
    hub.finish_agent_request(&session, &json!(1009), None);
    assert!(session.permissions.lock().unwrap_or_else(|e| e.into_inner()).pending.is_empty());
}

/// Both a registered card and a withdrawal before registration survive recovery.
#[tokio::test]
async fn an_agent_withdrawal_survives_host_recovery() {
    for registered in [false, true] {
        let (hub, session, _conn) = hub_with_session().await;
        saved_request(&hub, &session, "inc", 1009);
        if registered {
            hub.append(
                &session,
                "mux",
                "permission_request",
                json!({"permissionId": "p-1", "agentRequestId": 1009, "request": {}}),
            );
        }
        hub.append(
            &session,
            "mux",
            "permission_withdrawn",
            json!({"agentRequestId": 1009, "incarnation": "inc"}),
        );
        let work = hub.open_work(&session, "inc");
        if registered {
            let decision = work.permissions.get("1009").and_then(|entry| entry.2.clone());
            assert_eq!(decision, Some(json!({"outcome": "cancelled"})));
            assert!(work.cancelled_permissions.contains("1009"));
        } else {
            assert!(work.withdrawn.contains("1009"));
        }
    }
}

fn saved_request(hub: &Hub, session: &Session, incarnation: &str, id: i64) {
    hub.append(session, "mux", "host_started", json!({"incarnation": incarnation}));
    hub.append(
        session,
        "in",
        method::SESSION_REQUEST_PERMISSION,
        json!({"id": id, "method": method::SESSION_REQUEST_PERMISSION, "params": {}}),
    );
}

/// A deferred cancel from an older host must not cancel a reused request id
/// after a replacement host has started.
#[tokio::test]
async fn a_withdrawal_from_an_older_host_does_not_cross_incarnations() {
    let (hub, session, _conn) = hub_with_session().await;
    saved_request(&hub, &session, "new-host", 1011);
    hub.append(
        &session,
        "mux",
        "permission_withdrawn",
        json!({"agentRequestId": 1011, "incarnation": "old-host"}),
    );
    hub.append(
        &session,
        "mux",
        "permission_request",
        json!({"permissionId": "p-1011", "agentRequestId": 1011, "request": {}}),
    );
    let work = hub.open_work(&session, "new-host");
    let decision = work.permissions.get("1011").and_then(|entry| entry.2.clone());
    assert_eq!(decision, None);
    assert!(work.withdrawn.is_empty());
}

/// The rule under the prompt's lock, without the request check before it:
/// an ancestor's answer counts only on a prompt recorded as a question.
#[tokio::test]
async fn subsession_answer_under_the_lock_only_a_recorded_question_counts() {
    let (hub, session, _conn) = hub_with_session().await;
    let ancestor = Answerer { ancestor: Some("parent"), ..Default::default() };
    let by = json!({"session": "parent", "name": "parent"});
    let answers = json!({"ok?": "yes"});

    let (id, _rx) = pending(&session, false);
    let e = hub
        .respond_permission(
            &session,
            &id,
            Some("go".to_owned()),
            Some(answers.clone()),
            Some(by.clone()),
            ancestor,
            Control::Local,
        )
        .await
        .expect_err("a prompt not recorded as a question");
    let reason = e.data.as_ref().map(|d| d["reason"].clone());
    assert_eq!(reason, Some(json!(REASON)), "{e:?}");
    assert!(session.permissions.lock().unwrap().pending.contains_key(&id), "it stays pending");

    let (id, rx) = pending(&session, true);
    hub.respond_permission(
        &session,
        &id,
        Some("go".to_owned()),
        Some(answers),
        Some(by),
        ancestor,
        Control::Local,
    )
    .await
    .expect("a recorded question");
    let outcome = rx.await.unwrap();
    assert_eq!(outcome["optionId"], "go", "{outcome}");
    assert_eq!(outcome[ANSWERED_BY_SLOT]["session"], "parent", "{outcome}");
}

/// The folder-trust card (`trust_wait.rs`) is the person's: an ancestor
/// cannot trust a folder for them, even on an entry recorded otherwise.
#[tokio::test]
async fn subsession_answer_never_answers_a_folder_trust_card() {
    let (hub, session, _conn) = hub_with_session().await;
    let request = super::super::trust_wait::card("/tmp/untrusted", "child");
    assert!(!super::super::questions::ancestor_answerable(&request, false));
    let (reply, _rx) = oneshot::channel();
    let id = uuid::Uuid::now_v7().to_string();
    let entry = PendingPermission {
        request,
        reply,
        decision_nonce: super::super::person::new_nonce(),
        ancestor_may_answer: true,
        prev_status: SessionStatus::Waiting,
        agent_request: None,
        agent_host_incarnation: None,
    };
    session.permissions.lock().unwrap().pending.insert(id.clone(), entry);
    let prompt = "child wants to work in /tmp/untrusted. Do you trust this folder?";
    let e = hub
        .respond_permission(
            &session,
            &id,
            Some("trust".to_owned()),
            Some(json!({(prompt): "Trust folder"})),
            Some(json!({"session": "parent", "name": "parent"})),
            Answerer { ancestor: Some("parent"), ..Default::default() },
            Control::Local,
        )
        .await
        .expect_err("a folder-trust card");
    let reason = e.data.as_ref().map(|d| d["reason"].clone());
    assert_eq!(reason, Some(json!(REASON)), "{e:?}");
    assert!(session.permissions.lock().unwrap().pending.contains_key(&id), "it stays pending");
}
