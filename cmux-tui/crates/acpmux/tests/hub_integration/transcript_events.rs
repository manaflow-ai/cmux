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
async fn a_page_says_it_holds_to_the_log_end_only_when_it_reads_there() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "through").await;
    for text in ["one", "two", "three"] {
        c.request(method::SESSION_PROMPT, prompt(&id, text, None)).await.unwrap();
    }
    let last = hub.resolve("through").unwrap().meta().last_seq;
    let seqs = |page: &Value| -> Vec<u64> {
        page["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
    };
    let ask = |m: &'static str, extra: Value| {
        let mut params = json!({"sessionId": id, "kinds": ["transcript"], "limit": 2});
        params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        (m, params)
    };
    let mut a = connect(&hub).await;
    let pages = [
        // A page of older records holds only to its own last one (records after it were never read).
        ask(method::MUX_EVENTS, json!({"beforeSeq": last})),
        ask(method::MUX_ATTACH, json!({"beforeSeq": last})),
        // So does a forward page with more to read.
        ask(method::MUX_EVENTS, json!({"afterSeq": 0})),
        ask(method::MUX_ATTACH, json!({"afterSeq": 0})),
    ];
    for (m, params) in pages {
        let page = a.request(m, params.clone()).await.unwrap();
        let held = seqs(&page);
        assert!(!held.is_empty() && *held.last().unwrap() < last, "{m} {params}: {page}");
        assert_eq!(page["pageThrough"], json!(held.last()), "{m} {params}");
    }
    // The newest page (more before it or not), and a forward page that reads to the end, hold to
    // the log's last seq.
    let newest = a.request(method::MUX_ATTACH, ask(method::MUX_ATTACH, json!({})).1).await.unwrap();
    assert_eq!(newest["hasMore"], true);
    assert_eq!(newest["pageThrough"], json!(last));
    for (m, params) in [
        ask(method::MUX_EVENTS, json!({"afterSeq": 0, "limit": 10_000})),
        ask(method::MUX_ATTACH, json!({"afterSeq": 0, "limit": 10_000})),
    ] {
        let page = a.request(m, params.clone()).await.unwrap();
        assert_ne!(page["hasMore"], true, "{m} {params}");
        assert_eq!(page["pageThrough"], json!(last), "{m} {params}");
    }
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

/// Codex subagents arrive as their own sessions with their own turns
/// (Lawrence 2026-10-12, native subagents for Claude Code and Codex): acpmux
/// asks codex-acp for native subagent sessions in the form it reads, so each
/// child's updates reach the transcript under that child, not only "Start
/// subagent" tool calls.
#[tokio::test]
async fn codex_subagents_arrive_as_sessions_with_their_own_updates() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "codex-subagents").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "codex-subagents", None)).await.unwrap();
    let events = hub.events(&id, 0, 1000).unwrap();
    let mux = |msg: &Value| msg.pointer("/params/_meta/acpmux").cloned();
    let spawned: Vec<String> = events
        .iter()
        .filter_map(|e| mux(&e.msg))
        .filter_map(|m| m.get("subagents").and_then(|s| s.as_array()).cloned())
        .flatten()
        .filter(|s| s["state"] == "running")
        .map(|s| s["id"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(
        spawned,
        ["child-a", "child-b"],
        "{:?}",
        events.iter().map(|e| &e.kind).collect::<Vec<_>>()
    );
    for child in ["child-a", "child-b"] {
        let own: Vec<_> = events
            .iter()
            .filter(|e| mux(&e.msg).and_then(|m| m.get("subagent").cloned()) == Some(json!(child)))
            .map(|e| e.kind.as_str())
            .collect();
        assert!(
            own.contains(&"tool_call") && own.contains(&"agent_message_chunk"),
            "{child}: {own:?}"
        );
    }
}

/// A subagent that outlives its parent's turn and asks for permission after
/// that turn ended reaches the person, and its answer reaches the subagent
/// (cx-jo8yo): Codex children run on their own and may ask between turns.
#[tokio::test]
async fn a_codex_subagent_asking_after_the_turn_ended_reaches_the_person() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "late-ask").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "codex-late-subagent-ask", None)).await;
    // The ask may reach acpmux before acpmux ends the turn: its notification
    // then comes before the prompt's response, so keep what came before it.
    let (done, before) = c.response(rid).await;
    assert_eq!(done.unwrap()["stopReason"], "end_turn");
    let pending = match before.into_iter().find(|(m, _)| m == method::MUX_PERMISSION_PENDING) {
        Some((_, pending)) => pending,
        None => c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await,
    };
    assert_eq!(pending["request"]["toolCall"]["title"], "touch late.txt");
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "yes"}),
    )
    .await
    .unwrap();
    // The subagent's reply after the answer, from the session's log (a client gets no event
    // notifications between turns).
    let said = late_chunk(&hub, &id, |m| {
        m.pointer("/params/_meta/acpmux/subagent") == Some(&json!("late-child"))
    })
    .await;
    assert_eq!(said["params"]["update"]["content"]["text"], "late yes", "{said}");
}

/// The first agent_message_chunk in `id`'s log that `pick` accepts, waiting up to 5 s for it.
pub(super) async fn late_chunk(hub: &Arc<Hub>, id: &str, pick: impl Fn(&Value) -> bool) -> Value {
    for _ in 0..100 {
        let found = hub
            .events(id, 0, 10_000)
            .unwrap()
            .into_iter()
            .find(|e| e.kind == "agent_message_chunk" && pick(&e.msg));
        if let Some(e) = found {
            return e.msg;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("no matching agent_message_chunk in {id}");
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

/// The fake agent over an on-disk store whose event segments roll every `segment_bytes`.
fn segmented_config(segment_bytes: u64) -> Config {
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
    cfg.store.segment_bytes = segment_bytes;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

/// A daemon over [`segmented_config`] in a fresh directory.
pub(super) async fn setup_segmented(
    segment_bytes: u64,
) -> (Arc<Hub>, TestClient, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("acpmux-tail-{}", uuid::Uuid::now_v7()));
    let cfg = segmented_config(segment_bytes);
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client.become_person().await;
    (hub, client, dir)
}

fn seqs(page: &Value) -> Vec<u64> {
    page["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

/// Opening a long chat reads only the end of its log: a tail page, and an older
/// page, come from the newest segments, so their cost does not grow with the
/// whole history (a remote session's log can be very long). Shown by an oldest
/// segment that cannot be read at all: pages that never reach it still load.
#[tokio::test]
async fn tail_pages_read_only_the_newest_segments() {
    // Segments roll at 64 KiB at the least (LocalStore), so each prompt carries 70 KB: one segment a turn.
    let (hub, mut c, dir) = setup_segmented(64 * 1024).await;
    let id = new_session(&mut c, "long").await;
    let filler = "x".repeat(70_000);
    for n in 0..12 {
        let text = format!("turn {n} {filler}");
        c.request(method::SESSION_PROMPT, prompt(&id, &text, None)).await.unwrap();
    }
    let session = hub.resolve("long").unwrap();
    // The whole transcript (~1.7 MB of JSON) in one page: a page ends at
    // maxBytes, 1 MiB by default and 4 MiB at most (1b665b2d58a).
    let all = c
        .request(
            method::MUX_EVENTS,
            json!({"sessionId": id, "kinds": ["transcript"], "limit": 10_000, "maxBytes": 4 << 20}),
        )
        .await
        .unwrap();
    assert_ne!(all["hasMore"], true, "the whole transcript fits one page");
    let transcript = seqs(&all);
    let events = dir.join("sessions").join(&session.id).join("events");
    let mut segments: Vec<_> = std::fs::read_dir(&events)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "ndjson"))
        .collect();
    segments.sort();
    assert!(segments.len() > 8, "the log spans many segments: {}", segments.len());

    // The oldest segment can no longer be read (a directory where the file was).
    std::fs::remove_file(&segments[0]).unwrap();
    std::fs::create_dir(&segments[0]).unwrap();

    let mut a = connect(&hub).await;
    let att = a
        .request(method::MUX_ATTACH, json!({"sessionId": id, "kinds": ["transcript"], "limit": 4}))
        .await
        .expect("the tail page loads without reading the oldest segment");
    assert_eq!(seqs(&att), transcript[transcript.len() - 4..]);
    assert_eq!(att["hasMore"], true);
    let older = a
        .request(
            method::MUX_EVENTS,
            json!({"sessionId": id, "kinds": ["transcript"], "limit": 4, "beforeSeq": seqs(&att)[0]}),
        )
        .await
        .expect("an older page loads without reading the oldest segment");
    assert_eq!(seqs(&older), transcript[transcript.len() - 8..transcript.len() - 4]);
    assert_eq!(older["hasMore"], true);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The JSON the daemon sends to open a chat stays within a budget however long the chat is: a remote
/// session (cmux server, a peer over ssh) carries exactly this reply over the network. The pane asks
/// for the newest records up to `maxBytes`; a 5000-turn chat whose tool outputs are large still opens
/// on its last turn within 160 KiB, and the page says there is more.
#[tokio::test]
async fn opening_a_long_chat_stays_within_its_payload_budget() {
    use acpmux::store::EventRecord;
    let (hub, mut c, dir) = setup_segmented(8 * 1024 * 1024).await;
    let id = new_session(&mut c, "long").await;
    let mut seq = hub.resolve("long").unwrap().meta().last_seq;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let cfg = segmented_config(8 * 1024 * 1024);
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let output = "x".repeat(4000);
    let mut append = |dir: &str, kind: &str, msg: Value| {
        seq += 1;
        store
            .append(
                &id,
                &EventRecord {
                    seq,
                    at: seq,
                    dir: dir.into(),
                    kind: kind.into(),
                    msg,
                    host_seq: None,
                },
            )
            .unwrap();
    };
    let update = |body: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "agent-1", "update": body}});
    for turn in 0..5000 {
        append("mux", "user_message", json!({"text": format!("Question {turn}")}));
        append("mux", "turn_started", json!({}));
        let call = format!("call-{turn}");
        append(
            "in",
            "tool_call",
            update(json!({"sessionUpdate": "tool_call", "toolCallId": call,
            "title": "cat build.log", "kind": "read", "status": "in_progress"})),
        );
        append(
            "in",
            "tool_call_update",
            update(json!({"sessionUpdate": "tool_call_update",
            "toolCallId": call, "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": output}}]})),
        );
        append(
            "in",
            "agent_message_chunk",
            update(json!({"sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": format!("Answer {turn}")}})),
        );
        append("mux", "turn_result", json!({"status": "completed"}));
    }
    let last = seq;
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    let mut a = connect(&hub).await;
    let att = a
        .request(
            method::MUX_ATTACH,
            json!({"sessionId": id, "limit": 400, "maxBytes": 128 * 1024, "eventStream": true,
                "kinds": ["transcript", "available_commands_update", "usage_update",
                    "config_option_update", "secret_request", "secret_decision"]}),
        )
        .await
        .unwrap();
    let wire = serde_json::to_string(&att).unwrap().len();
    assert!(wire <= 160 * 1024, "opening sent {} KiB", wire / 1024);
    let events = att["events"].as_array().unwrap();
    assert_eq!(events.last().unwrap()["seq"], last, "the page ends on the latest record");
    assert!(events.len() >= 6, "the page holds at least the last turn: {}", events.len());
    assert_eq!(att["hasMore"], true);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Measurement, not a check (cx-2lv1k): what opening and scrolling a long chat costs the daemon.
/// 3000 turns of about 60 records each in the default 8 MiB segments; prints milliseconds.
/// `scripts/ci/cargo-test-selected.sh -p acpmux --test hub_integration history_page_cost -- --ignored --nocapture`
#[tokio::test]
#[ignore]
async fn history_page_cost() {
    use acpmux::store::EventRecord;
    use std::time::Instant;
    let (hub, mut c, dir) = setup_segmented(8 * 1024 * 1024).await;
    let id = new_session(&mut c, "long").await;
    let session = hub.resolve("long").unwrap();
    let cfg = segmented_config(8 * 1024 * 1024);
    let mut seq = session.meta().last_seq;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let update = |seq: u64, kind: &str, body: Value| EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: kind.into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "agent-1", "update": body}}),
        host_seq: None,
    };
    let mux = |seq: u64, kind: &str, msg: Value| EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    };
    let output = "x".repeat(900);
    let started = Instant::now();
    for turn in 0..3000 {
        let push = |rec: EventRecord| store.append(&id, &rec).unwrap();
        seq += 1;
        push(mux(seq, "user_message", json!({"text": format!("Question {turn}")})));
        seq += 1;
        push(mux(seq, "turn_started", json!({})));
        for step in 0..5 {
            let call = format!("call-{turn}-{step}");
            seq += 1;
            push(update(
                seq,
                "tool_call",
                json!({"sessionUpdate": "tool_call", "toolCallId": call,
                "title": "git status", "kind": "execute", "status": "in_progress",
                "rawInput": {"command": "cd ~/wt/lanes/long && git status && git diff --stat"}}),
            ));
            seq += 1;
            push(update(
                seq,
                "tool_call_update",
                json!({"sessionUpdate": "tool_call_update",
                "toolCallId": call, "status": "completed",
                "content": [{"type": "content", "content": {"type": "text", "text": output}}]}),
            ));
        }
        for _ in 0..48 {
            seq += 1;
            push(update(
                seq,
                "agent_message_chunk",
                json!({"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "the checks on the merged head are green, "}}),
            ));
        }
        seq += 1;
        push(mux(seq, "turn_result", json!({"status": "completed"})));
    }
    store.flush().unwrap();
    let bytes: u64 = std::fs::read_dir(dir.join("sessions").join(&id).join("events"))
        .unwrap()
        .flatten()
        .map(|e| e.metadata().unwrap().len())
        .sum();
    eprintln!(
        "history_page_cost: {seq} records, {:.1} MiB, written in {} ms",
        bytes as f64 / 1048576.0,
        started.elapsed().as_millis()
    );

    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    let mut a = connect(&hub).await;
    let kinds = json!([
        "transcript",
        "available_commands_update",
        "usage_update",
        "config_option_update",
        "secret_request",
        "secret_decision"
    ]);
    let time = |label: &'static str, ms: u128| eprintln!("history_page_cost: {label}: {ms} ms");
    for round in 0..3 {
        let t = Instant::now();
        let att = a
            .request(method::MUX_ATTACH, json!({"sessionId": id, "kinds": kinds, "limit": 400}))
            .await
            .unwrap();
        time(
            if round == 0 { "open (attach, newest 400)" } else { "open again" },
            t.elapsed().as_millis(),
        );
        assert_eq!(att["events"].as_array().unwrap().len(), 400);
        a.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    }
    let t = Instant::now();
    let older = a
        .request(
            method::MUX_EVENTS,
            json!({"sessionId": id, "kinds": ["transcript"], "limit": 400, "beforeSeq": seq / 2}),
        )
        .await
        .unwrap();
    time("older page from mid-history", t.elapsed().as_millis());
    assert_eq!(older["events"].as_array().unwrap().len(), 400);
    let t = Instant::now();
    let early = a
        .request(
            method::MUX_EVENTS,
            json!({"sessionId": id, "kinds": ["transcript"], "limit": 400, "beforeSeq": seq / 20}),
        )
        .await
        .unwrap();
    time("older page near the start", t.elapsed().as_millis());
    assert_eq!(early["events"].as_array().unwrap().len(), 400);
    let t = Instant::now();
    let all = hub.events(&id, 0, usize::MAX).unwrap();
    time("whole log, for reference", t.elapsed().as_millis());
    assert_eq!(all.last().unwrap().seq, seq);
    let _ = std::fs::remove_dir_all(&dir);
}
