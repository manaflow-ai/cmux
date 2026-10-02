//! Chat client protocol: prompt ids, queues, watchers, paging and resends.

use super::*;

// ------------------------------------------------- chat client protocol

impl TestClient {
    /// Send a request without waiting for its response.
    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, params).to_line()).await.unwrap();
        self.next
    }

    /// Collect notifications up to and including the first that matches.
    async fn collect_until(&mut self, pred: impl Fn(&str, &Value) -> bool) -> Vec<(String, Value)> {
        let mut seen = Vec::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout waiting for notification")
                .expect("connection closed");
            if let Message::Notification { method, params } = Message::parse(&line).unwrap() {
                let p = params.unwrap_or(Value::Null);
                let done = pred(&method, &p);
                seen.push((method, p));
                if done {
                    return seen;
                }
            }
        }
    }

    /// Wait for the response to `id`, returning it and every notification
    /// seen before it.
    async fn response(&mut self, id: i64) -> (Result<Value, String>, Vec<(String, Value)>) {
        let mut seen = Vec::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout waiting for response")
                .expect("connection closed");
            match Message::parse(&line).unwrap() {
                Message::Response { id: rid, result, error } if rid == json!(id) => {
                    let r = match error {
                        Some(e) => Err(e.message),
                        None => Ok(result.unwrap_or(Value::Null)),
                    };
                    return (r, seen);
                }
                Message::Notification { method, params } => {
                    seen.push((method, params.unwrap_or(Value::Null)))
                }
                _ => {}
            }
        }
    }
}

/// A second connection to the same hub.
async fn connect(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    TestClient { tx: in_tx, rx: out_rx, next: 0 }
}

async fn new_session(c: &mut TestClient, name: &str) -> String {
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

fn prompt(id: &str, text: &str, prompt_id: Option<&str>) -> Value {
    let mut p = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    if let Some(pid) = prompt_id {
        p["_meta"] = json!({"acpmux": {"promptId": pid}});
    }
    p
}

fn find<'a>(
    events: &'a [acpmux::store::EventRecord],
    kind: &str,
) -> Vec<&'a acpmux::store::EventRecord> {
    events.iter().filter(|e| e.kind == kind).collect()
}

#[tokio::test]
async fn prompt_ids_and_turn_ids_are_echoed_and_accepted_early() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "ids").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "hi", Some("p-1"))).await;
    let (r, seen) = c.response(rid).await;
    let r = r.unwrap();
    // The acknowledgement arrives before the turn's response.
    let accepted = seen
        .iter()
        .find(|(m, _)| m == method::MUX_PROMPT_ACCEPTED)
        .map(|(_, p)| p.clone())
        .expect("prompt_accepted before the response");
    assert_eq!(accepted["sessionId"], id);
    assert_eq!(accepted["promptId"], "p-1");
    assert_eq!(accepted["queued"], false);
    let turn_id = accepted["turnId"].as_str().unwrap().to_owned();
    // The ACP response keeps its stopReason and gains the ids.
    assert_eq!(r["stopReason"], "end_turn");
    assert_eq!(r["_meta"]["acpmux"]["promptId"], "p-1");
    assert_eq!(r["_meta"]["acpmux"]["turnId"], turn_id);
    let session = hub.resolve("ids").unwrap();
    let events = hub.events(&session.id, 0, 1000).unwrap();
    let user = find(&events, "user_message")[0];
    assert_eq!(user.msg["promptId"], "p-1");
    assert_eq!(user.msg["turnId"], turn_id);
    let started = find(&events, "turn_started")[0];
    assert_eq!(started.msg["promptId"], "p-1");
    assert_eq!(started.msg["turnId"], turn_id);
    assert_eq!(r["_meta"]["acpmux"]["turnSeq"], started.seq);
    for kind in ["turn_end", "turn_result"] {
        let e = find(&events, kind)[0];
        assert_eq!(e.msg["turnId"], turn_id, "{kind}");
        assert_eq!(e.msg["turnSeq"], started.seq, "{kind}");
    }
    assert_eq!(find(&events, "turn_result")[0].msg["promptId"], "p-1");

    // A prompt without a promptId gets a generated one.
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "again", None)).await;
    let (r, seen) = c.response(rid).await;
    let generated = r.unwrap()["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned();
    assert!(!generated.is_empty());
    assert!(
        seen.iter().any(|(m, p)| m == method::MUX_PROMPT_ACCEPTED && p["promptId"] == generated)
    );
}

#[tokio::test]
async fn queued_prompts_are_accepted_queued_and_watchers_see_the_queue() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "q").await;
    let mut w = connect(&hub).await;
    let snap = w.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    // The watch result is the session list.
    assert!(snap["sessions"].as_array().unwrap().iter().any(|s| s["sessionId"] == id));

    let first = c.send(method::SESSION_PROMPT, prompt(&id, "slow", Some("p-slow"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-slow").await;
    let second = c.send(method::SESSION_PROMPT, prompt(&id, "after", Some("p-after"))).await;
    let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-after").await;
    assert_eq!(acc["queued"], true);
    assert_eq!(acc["position"], 1);
    let queue = hub.session_summary(&hub.resolve("q").unwrap())["queue"].clone();
    assert_eq!(queue[0]["promptId"], "p-after");

    // Watchers learn about the queue on enqueue and on dequeue, with the
    // session id at the top level.
    let enq = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["kind"] == "queue" && p["recordKind"] == "queued"
        })
        .await;
    assert_eq!(enq["sessionId"], id);
    assert_eq!(enq["session"]["queued"], 1);
    let deq = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["kind"] == "queue" && p["recordKind"] == "dequeued"
        })
        .await;
    assert_eq!(deq["sessionId"], id);
    assert_eq!(deq["session"]["queued"], 0);

    assert!(c.response(first).await.0.is_ok());
    let r = c.response(second).await.0.unwrap();
    assert_eq!(r["_meta"]["acpmux"]["turnId"], acc["turnId"]);
    let events = hub.events(&id, 0, 1000).unwrap();
    let queued = find(&events, "queued")[0];
    assert_eq!(queued.msg["promptId"], "p-after");
    assert_eq!(queued.msg["turnId"], acc["turnId"]);
    assert_eq!(find(&events, "dequeued")[0].msg["turnId"], acc["turnId"]);
}

#[tokio::test]
async fn watchers_get_permission_pending_and_auto_approvals() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "perm").await;
    let mut w = connect(&hub).await;
    w.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();

    // Asked: a watcher that is not attached still gets permission_pending.
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "ask: rm x", None)).await;
    let pending = w.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    assert_eq!(pending["sessionId"], id);
    assert_eq!(pending["via"], "watch");
    let attached = c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    assert_eq!(attached["via"], "attach");
    w.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pending["permissionId"], "optionId": "yes"}),
    )
    .await
    .unwrap();
    assert!(c.response(rid).await.0.is_ok());

    // Auto-approved by policy: watchers see permission_resolved.
    c.request(method::MUX_SET_POLICY, json!({"sessionId": id, "policy": "approve-all"}))
        .await
        .unwrap();
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "ask: ls", None)).await;
    let resolved =
        w.wait_for(method::MUX_SESSION_CHANGED, |p| p["kind"] == "permission_resolved").await;
    assert_eq!(resolved["sessionId"], id);
    assert_eq!(resolved["recordKind"], "permission_auto");
    assert!(c.response(rid).await.0.is_ok());
}

#[tokio::test]
async fn session_cancel_as_a_request_is_answered() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "cancel-req").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "slow", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let cancel = c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (r, _) = c.response(cancel).await;
    assert_eq!(r.unwrap(), json!({}));
    let r = c.response(rid).await.0.unwrap();
    assert_eq!(r["stopReason"], "cancelled");
    // With no turn running it still answers.
    assert_eq!(
        c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap(),
        json!({})
    );
}

#[tokio::test]
async fn events_and_attach_page_backwards_through_transcript_records() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "pages").await;
    for text in ["one", "two", "three"] {
        c.request(method::SESSION_PROMPT, prompt(&id, text, None)).await.unwrap();
    }
    let session = hub.resolve("pages").unwrap();
    let all = hub.events(&session.id, 0, 10_000).unwrap();
    assert!(all.iter().any(|e| e.dir == "out"), "the log has wire records to filter");
    let transcript: Vec<u64> = c
        .request(
            method::MUX_EVENTS,
            json!({"sessionId": id, "kinds": ["transcript"], "limit": 1000}),
        )
        .await
        .unwrap()["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["seq"].as_u64().unwrap())
        .collect();
    assert!(transcript.len() >= 9, "{transcript:?}");

    // Walk back two at a time from the end: pages are newest-first chunks,
    // each oldest-first inside, and together they are the whole transcript.
    let mut before = session.meta().last_seq + 1;
    let mut walked: Vec<u64> = Vec::new();
    loop {
        let page = c
            .request(
                method::MUX_EVENTS,
                json!({"sessionId": id, "kinds": ["transcript"], "beforeSeq": before, "limit": 2}),
            )
            .await
            .unwrap();
        let events = page["events"].as_array().unwrap();
        for e in events {
            let kind = e["kind"].as_str().unwrap();
            assert!(e["dir"] != "out" && kind != "response" && !kind.ends_with(".replay"), "{e}");
        }
        let seqs: Vec<u64> = events.iter().map(|e| e["seq"].as_u64().unwrap()).collect();
        assert!(seqs.windows(2).all(|w| w[0] < w[1]));
        walked.splice(0..0, seqs.iter().copied());
        if page["hasMore"] != true {
            break;
        }
        assert_eq!(seqs.len(), 2);
        before = seqs[0];
    }
    assert_eq!(walked, transcript);

    // Forward paging reports hasMore too.
    let fwd = c
        .request(
            method::MUX_EVENTS,
            json!({"sessionId": id, "kinds": ["transcript"], "afterSeq": 0, "limit": 3}),
        )
        .await
        .unwrap();
    assert_eq!(fwd["hasMore"], true);
    assert_eq!(fwd["events"].as_array().unwrap().len(), 3);

    // Attach: the newest `limit` transcript records, then older ones with beforeSeq.
    let mut a = connect(&hub).await;
    let att = a
        .request(method::MUX_ATTACH, json!({"sessionId": id, "kinds": ["transcript"], "limit": 4}))
        .await
        .unwrap();
    let seqs: Vec<u64> =
        att["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    assert_eq!(seqs, transcript[transcript.len() - 4..]);
    assert_eq!(att["hasMore"], true);
    let older = a
        .request(
            method::MUX_ATTACH,
            json!({"sessionId": id, "kinds": ["transcript"], "limit": 4, "beforeSeq": seqs[0]}),
        )
        .await
        .unwrap();
    let older: Vec<u64> =
        older["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    assert_eq!(older, transcript[transcript.len() - 8..transcript.len() - 4]);
    // Without kinds, attach still returns the raw log as before.
    let raw = a.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 5})).await.unwrap();
    let raw_last = raw["lastSeq"].as_u64().unwrap();
    let raw: Vec<u64> =
        raw["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    let last = raw_last;
    assert_eq!(raw, (last - 4..=last).collect::<Vec<_>>());
}

#[tokio::test]
async fn live_updates_keep_agent_meta_and_event_stream_nests_them() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "live").await;
    let mut stream = connect(&hub).await;
    stream
        .request(
            method::MUX_ATTACH,
            json!({"sessionId": id, "limit": 0, "eventStream": true, "kinds": ["transcript"]}),
        )
        .await
        .unwrap();
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "meta: hello", None)).await;
    let (r, seen) = c.response(rid).await;
    // The agent's response _meta survives next to acpmux's.
    let r = r.unwrap();
    assert_eq!(r["_meta"]["fake"]["done"], true);
    assert!(r["_meta"]["acpmux"]["turnId"].is_string());
    let upd = seen
        .iter()
        .find(|(m, p)| {
            m == method::SESSION_UPDATE && p["update"]["sessionUpdate"] == "agent_message_chunk"
        })
        .map(|(_, p)| p.clone())
        .expect("live session/update");
    assert_eq!(upd["_meta"]["fake"]["n"], 1, "agent _meta kept: {upd}");
    let seq = upd["_meta"]["acpmux"]["seq"].as_u64().unwrap();
    assert!(seq > 0);
    assert_eq!(upd["_meta"]["acpmux"]["kind"], "agent_message_chunk");

    // The event-stream connection got the same record as _acpmux/event,
    // with the original notification nested, and no wire records.
    let seen =
        stream.collect_until(|m, p| m == method::MUX_EVENT && p["kind"] == "turn_result").await;
    assert!(seen.iter().all(|(m, _)| m != method::SESSION_UPDATE));
    let evs: Vec<&Value> =
        seen.iter().filter(|(m, _)| m == method::MUX_EVENT).map(|(_, p)| p).collect();
    let chunk = evs.iter().find(|e| e["seq"] == seq).expect("chunk as _acpmux/event");
    assert_eq!(chunk["msg"]["method"], "session/update");
    assert_eq!(chunk["msg"]["params"]["_meta"]["fake"]["n"], 1);
    assert!(evs.iter().any(|e| e["kind"] == "user_message"));
    assert!(evs.iter().any(|e| e["kind"] == "turn_result"));
    assert!(
        evs.iter().all(|e| e["dir"] != "out" && e["kind"] != "response" && e["kind"] != "turn_end")
    );
}

#[tokio::test]
async fn codex_retry_records_message_superseded_before_the_redelivery() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "retry").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "codex-retry", None)).await.unwrap();
    let events = hub.events(&id, 0, 1000).unwrap();
    let sup = find(&events, "message_superseded");
    assert_eq!(sup.len(), 1, "{:?}", events.iter().map(|e| &e.kind).collect::<Vec<_>>());
    assert_eq!(sup[0].msg["oldMessageId"], "m1");
    assert_eq!(sup[0].msg["newMessageId"], "m2");
    assert_eq!(sup[0].msg["reason"], "harness_retry");
    let turn = find(&events, "turn_started")[0];
    assert_eq!(sup[0].msg["turnId"], turn.msg["turnId"]);
    let redelivered = events
        .iter()
        .find(|e| e.msg.pointer("/params/update/messageId") == Some(&json!("m2")))
        .unwrap();
    assert!(sup[0].seq < redelivered.seq);
    // A willRetry error that the harness recovers from leaves the turn completed.
    let result = find(&events, "turn_result")[0];
    assert_eq!(result.msg["status"], "completed");
    assert!(result.msg.get("errorText").is_none());

    // A message that a tool call already finished is not abandoned by a retry.
    c.request(method::SESSION_PROMPT, prompt(&id, "codex-retry-after-tool", None)).await.unwrap();
    let events = hub.events(&id, 0, 1000).unwrap();
    assert_eq!(find(&events, "message_superseded").len(), 1);
}

#[tokio::test]
async fn turn_result_carries_error_text_and_streamed_error_chunks() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "errs").await;
    let last_result = |hub: &Arc<Hub>| {
        let events = hub.events(&id, 0, 10_000).unwrap();
        events.into_iter().rev().find(|e| e.kind == "turn_result").unwrap()
    };

    // Error text streamed as the answer: the chunk seqs are named.
    assert!(
        c.request(method::SESSION_PROMPT, prompt(&id, "fail-streamed: API Error: boom", None))
            .await
            .is_err()
    );
    let r = last_result(&hub);
    assert_eq!(r.msg["status"], "failed");
    assert_eq!(r.msg["errorText"], "API Error: boom");
    assert_eq!(r.msg["errorCode"], -32000);
    assert_eq!(r.msg["errorSource"], "agent");
    let chunk = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .rev()
        .find(|e| e.kind == "agent_message_chunk")
        .unwrap();
    assert_eq!(r.msg["errorChunkSeqs"], json!([chunk.seq]));

    // Partial output then a different error: text and code, no chunk marks.
    assert!(
        c.request(method::SESSION_PROMPT, prompt(&id, "fail-after-update: x", None)).await.is_err()
    );
    let r = last_result(&hub);
    assert!(
        r.msg["errorText"].as_str().unwrap().starts_with("simulated internal error after output")
    );
    assert_eq!(r.msg["errorCode"], -32603);
    assert!(r.msg.get("errorChunkSeqs").is_none());

    // Codex reports a terminal error in-band and still ends the turn: the
    // turn failed, and the prompt is answered with that error.
    let err = c.request(method::SESSION_PROMPT, prompt(&id, "codex-fail", None)).await.unwrap_err();
    assert_eq!(err, "Selected model is at capacity.");
    let r = last_result(&hub);
    assert_eq!(r.msg["status"], "failed");
    assert_eq!(r.msg["errorText"], "Selected model is at capacity.");
    assert_eq!(r.msg["errorCode"], json!({"serverOverloaded": {}}));
    assert_eq!(r.msg["errorSource"], "codex");
    let summary = hub.session_summary(&hub.resolve("errs").unwrap());
    assert_eq!(summary["lastTurn"]["status"], "failed");
    assert_eq!(summary["lastTurn"]["turnId"], r.msg["turnId"]);

    // A clean turn has no error fields.
    c.request(method::SESSION_PROMPT, prompt(&id, "fine", None)).await.unwrap();
    assert!(last_result(&hub).msg.get("errorText").is_none());
    let summary = hub.session_summary(&hub.resolve("errs").unwrap());
    assert_eq!(summary["lastTurn"]["status"], "completed");
}

fn prompt_with_id(id: &str, text: &str, prompt_id: &str, resend: bool) -> Value {
    json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id, "resend": resend}},
    })
}

fn user_messages(hub: &Arc<Hub>, id: &str) -> usize {
    hub.events(id, 0, 10_000).unwrap().iter().filter(|e| e.kind == "user_message").count()
}

#[tokio::test]
async fn a_resent_prompt_id_runs_once_and_answers_with_the_first_outcome() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let first = c
        .request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-once", false))
        .await
        .unwrap();
    assert_eq!(first["stopReason"], "end_turn");
    assert!(first["_meta"]["acpmux"]["duplicate"].is_null(), "{first}");
    let again = c
        .request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-once", false))
        .await
        .unwrap();
    assert_eq!(again["stopReason"], "end_turn");
    assert_eq!(again["_meta"]["acpmux"]["duplicate"], true);
    assert_eq!(user_messages(&hub, &id), 1);

    // A resend while the first run is still going waits for it.
    c.next += 1;
    let running = c.next;
    c.tx.send(
        Message::request(
            running,
            method::SESSION_PROMPT,
            prompt_with_id(&id, "slow", "p-slow", false),
        )
        .to_line(),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-slow").await;
    let resent = c
        .request(method::SESSION_PROMPT, prompt_with_id(&id, "slow", "p-slow", false))
        .await
        .unwrap();
    assert_eq!(resent["_meta"]["acpmux"]["duplicate"], true);
    assert_eq!(user_messages(&hub, &id), 2);
}

#[tokio::test]
async fn a_resend_after_a_restart_is_answered_from_the_log() {
    let dir = std::env::temp_dir().join(format!("acpmux-resend-{}", uuid::Uuid::now_v7()));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, "resend").await;
    c.send(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-restart", false)).await;
    c.collect_until(|m, p| m == method::MUX_EVENT && p["kind"] == "turn_end").await;
    hub.shutdown_all().await;
    drop(hub);

    let store2 = acpmux::store::open(&cfg.store, &dir).unwrap();
    let hub2 = Hub::new(cfg, store2);
    let mut c2 = connect(&hub2).await;
    let n = c2.send(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-restart", true)).await;
    let (reply, _) = c2.response(n).await;
    let reply = reply.unwrap();
    assert_eq!(reply["_meta"]["acpmux"]["duplicate"], true, "{reply}");
    assert_eq!(reply["stopReason"], "end_turn");
    assert_eq!(user_messages(&hub2, &id), 1);
    let _ = std::fs::remove_dir_all(&dir);
}
