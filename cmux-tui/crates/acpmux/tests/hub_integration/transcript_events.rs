use super::*;

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
async fn a_subagent_ending_mid_message_keeps_the_codex_retry() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "retry-subagent").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "codex-retry-after-subagent", None))
        .await
        .unwrap();
    let events = hub.events(&id, 0, 1000).unwrap();
    // A subagent's spawn and end neither end nor continue the parent's message.
    let sup = find(&events, "message_superseded");
    assert_eq!(sup.len(), 1, "{:?}", events.iter().map(|e| &e.kind).collect::<Vec<_>>());
    assert_eq!(sup[0].msg["oldMessageId"], "m1");
    assert_eq!(sup[0].msg["newMessageId"], "m2");
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
