//! Cross-harness handoff: `_acpmux/handoff_prepare|get|draft|start|discard`.

use super::*;

fn fake_profile() -> HarnessProfile {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
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
    }
}

/// A hub with two harnesses of different families (`fake` and `mirror`), in
/// memory or, with `dir`, on disk so a second hub can reopen it.
fn handoff_hub(dir: Option<&std::path::Path>) -> (Arc<Hub>, Config) {
    let mut agents = BTreeMap::new();
    agents.insert("fake".to_owned(), fake_profile());
    agents.insert("mirror".to_owned(), fake_profile());
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg.store.mode = if dir.is_some() { StoreMode::Local } else { StoreMode::Memory };
    let root = dir.map(|d| d.to_path_buf()).unwrap_or_else(|| "/nonexistent".into());
    let store = acpmux::store::open(&cfg.store, &root).unwrap();
    (Hub::new(cfg.clone(), store), cfg)
}

/// A request whose error keeps its whole shape: `{code, message, data}`.
async fn call(c: &mut TestClient, m: &str, params: Value) -> Result<Value, Value> {
    let id = c.send(m, params).await;
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), c.rx.recv())
            .await
            .expect("timeout waiting for response")
            .expect("connection closed");
        if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
            && rid == json!(id)
        {
            return match error {
                Some(e) => Err(serde_json::to_value(e).unwrap()),
                None => Ok(result.unwrap_or(Value::Null)),
            };
        }
    }
}

fn reason(e: &Value) -> &str {
    e["data"]["reason"].as_str().unwrap_or("")
}

fn prepare(session: &str, harness: &str, key: &str) -> Value {
    json!({"sessionId": session, "harness": harness, "handoffKey": key})
}

fn attested(reference: &str) -> Value {
    json!({"ref": reference, "attest": true})
}

fn str_of<'a>(v: &'a Value, pointer: &str) -> &'a str {
    v.pointer(pointer).and_then(Value::as_str).unwrap_or_else(|| panic!("{pointer} in {v}"))
}

#[tokio::test]
async fn prepare_is_idempotent_and_creates_one_unprompted_target_in_the_source_cwd() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "src").await;
    c.request(method::SESSION_PROMPT, prompt(&src, "hello there", None)).await.unwrap();
    let sessions = hub.sessions().len();
    let h = call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k1")).await.unwrap();
    assert_eq!(h["state"], "draft", "{h}");
    assert_eq!(h["revision"], 1);
    assert_eq!(h["handoffKey"], "k1");
    assert!(h["promptId"].is_null() && h["turnId"].is_null(), "{h}");
    let again =
        call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k1")).await.unwrap();
    assert_eq!(again["handoffId"], h["handoffId"]);
    assert_eq!(again["target"]["sessionId"], h["target"]["sessionId"]);
    assert_eq!(hub.sessions().len(), sessions + 1, "one target for one handoffKey");

    let target = str_of(&h, "/target/sessionId");
    assert_eq!(h["source"]["sessionId"], src);
    assert_eq!(h["target"]["harness"], "mirror");
    assert_eq!(h["target"]["cwd"], h["source"]["cwd"]);
    assert_eq!(hub.resolve(target).unwrap().meta().cwd, hub.resolve(&src).unwrap().meta().cwd);
    assert_eq!(
        hub.resolve(target).unwrap().meta().permission_policy.as_deref(),
        Some("approve-all")
    );
    // Prepare only creates the target; nothing reaches its harness yet.
    assert_eq!(user_messages(&hub, target), 0);
    assert_eq!(hub.resolve(target).unwrap().meta().turn_count, 0);

    let text = str_of(&h, "/capsule/text");
    assert!(text.contains("hello there") && text.contains("echo: hello there"), "{text}");
    assert!(text.contains("src"), "the capsule names the source session: {text}");
    assert_eq!(h["capsule"]["maxBytes"], 65536);
    assert!(h["capsule"]["checkpoint"].is_null());
    assert_eq!(h["capsule"]["memoryRefs"], json!([]));
    let seq = h["source"]["seq"].as_u64().unwrap();
    assert!(seq > 0 && seq <= hub.resolve(&src).unwrap().meta().last_seq);
    assert_eq!(h["capsule"]["context"]["toSeq"], seq);
    assert_eq!(h["capsule"]["context"]["truncated"], false);
    for side in ["source", "target"] {
        let e = &h[side]["enforcement"];
        assert_eq!(e["label"], "native_policy", "{side}: {e}");
        assert_eq!(e["isolation"], "unverified", "{side}: {e}");
        let coverage = h[side]["coverage"].as_array().expect("coverage per session");
        let transcript = coverage.iter().find(|c| c["item"] == "transcript").expect("transcript");
        assert_eq!(transcript["status"], "included", "{transcript}");
        assert!(coverage.iter().any(|c| c["item"] == "checkpoint"), "{coverage:?}");
    }
    assert!(h.get("coverage").is_none(), "coverage lives on each session");
}

#[tokio::test]
async fn prepare_cuts_the_oldest_context_to_fit_the_budget() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "long").await;
    for (marker, fill) in [("first-marker", "a"), ("second-marker", "b")] {
        let text = format!("{marker} {}", fill.repeat(30_000));
        c.request(method::SESSION_PROMPT, prompt(&src, &text, None)).await.unwrap();
    }
    let h =
        call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k-long")).await.unwrap();
    let text = str_of(&h, "/capsule/text");
    assert!(text.len() <= 65536, "{} bytes", text.len());
    assert!(text.contains("second-marker"));
    assert!(!text.contains("first-marker"), "the oldest turn goes first");
    let ctx = &h["capsule"]["context"];
    assert_eq!(ctx["truncated"], true, "{ctx}");
    assert!(ctx["totalBytes"].as_u64().unwrap() > ctx["bytes"].as_u64().unwrap(), "{ctx}");
    let coverage = h["source"]["coverage"].as_array().unwrap();
    let transcript = coverage.iter().find(|c| c["item"] == "transcript").unwrap();
    assert_eq!(transcript["status"], "summarized", "{transcript}");
}

#[tokio::test]
async fn prepare_refuses_same_harness_unattested_unmappable_and_busy_sources() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "busy").await;
    let e = call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "fake", "k-same"))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "same_harness", "{e}");
    assert!(e["message"].as_str().unwrap().starts_with("same_harness"), "{e}");

    let mut p = prepare(&src, "mirror", "k-unattested");
    p["checkpoint"] = json!({"ref": "abc123"});
    let e = call(&mut c, method::MUX_HANDOFF_PREPARE, p).await.unwrap_err();
    assert_eq!(reason(&e), "checkpoint_unattested", "{e}");

    c.request(method::MUX_SET_POLICY, json!({"sessionId": src, "policy": "deny-all"}))
        .await
        .unwrap();
    let mut p = prepare(&src, "mirror", "k-narrow");
    p["policy"] = json!("narrower");
    let e = call(&mut c, method::MUX_HANDOFF_PREPARE, p).await.unwrap_err();
    assert_eq!(reason(&e), "policy_unmappable", "{e}");
    c.request(method::MUX_SET_POLICY, json!({"sessionId": src, "policy": "approve-all"}))
        .await
        .unwrap();

    // A running turn, then a prompt queued behind it.
    c.send(method::SESSION_PROMPT, prompt(&src, "slow", Some("p-slow"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-slow").await;
    let e = call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k-busy"))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "source_busy", "{e}");
    c.send(method::SESSION_PROMPT, prompt(&src, "hi", Some("p-queued"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-queued").await;
    let e = call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k-busy"))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "source_busy", "{e}");
    assert_eq!(hub.sessions().len(), 1, "a refused prepare creates no target");
}

#[tokio::test]
async fn get_finds_a_handoff_by_id_or_either_session_and_null_for_others() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "get-src").await;
    let plain = new_session(&mut c, "plain").await;
    let h =
        call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k-get")).await.unwrap();
    let id = str_of(&h, "/handoffId");
    let target = str_of(&h, "/target/sessionId");
    for params in
        [json!({"handoffId": id}), json!({"sessionId": src}), json!({"sessionId": target})]
    {
        let got = call(&mut c, method::MUX_HANDOFF_GET, params.clone()).await.unwrap();
        assert_eq!(got["handoffId"], id, "{params}: {got}");
    }
    let none = call(&mut c, method::MUX_HANDOFF_GET, json!({"sessionId": plain})).await.unwrap();
    assert!(none.is_null(), "an ordinary session has no handoff: {none}");
    let e = call(&mut c, method::MUX_HANDOFF_GET, json!({"handoffId": "no-such-handoff"}))
        .await
        .unwrap_err();
    assert_eq!(reason(&e), "not_found", "{e}");
}

#[tokio::test]
async fn draft_replays_a_draft_key_and_reconciles_stale_revisions() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "draft").await;
    let h = call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k-draft"))
        .await
        .unwrap();
    let id = str_of(&h, "/handoffId").to_owned();
    let draft = |revision: u64, key: &str, text: &str| json!({"handoffId": id, "revision": revision, "draftKey": key, "capsule": {"text": text}});
    let d1 = call(&mut c, method::MUX_HANDOFF_DRAFT, draft(1, "d1", "first edit")).await.unwrap();
    assert_eq!(d1["revision"], 2, "{d1}");
    assert_eq!(d1["capsule"]["text"], "first edit");
    // A lost acknowledgement: the same draftKey answers with the first write.
    for text in ["first edit", "something else"] {
        let replay = call(&mut c, method::MUX_HANDOFF_DRAFT, draft(1, "d1", text)).await.unwrap();
        assert_eq!(replay["revision"], 2, "{replay}");
        assert_eq!(replay["capsule"]["text"], "first edit");
    }
    // A stale revision with the current content succeeds without a new revision.
    let same = call(&mut c, method::MUX_HANDOFF_DRAFT, draft(1, "d2", "first edit")).await.unwrap();
    assert_eq!(same["revision"], 2, "{same}");
    // A stale revision with other content is refused with the current record.
    let e =
        call(&mut c, method::MUX_HANDOFF_DRAFT, draft(1, "d3", "second edit")).await.unwrap_err();
    assert_eq!(reason(&e), "stale_revision", "{e}");
    assert_eq!(e["data"]["handoff"]["revision"], 2, "{e}");
    assert_eq!(e["data"]["handoff"]["capsule"]["text"], "first edit");

    let big = "x".repeat(65_537);
    let e = call(&mut c, method::MUX_HANDOFF_DRAFT, draft(2, "d4", &big)).await.unwrap_err();
    assert_eq!(reason(&e), "capsule_too_large", "{e}");
    assert_eq!(e["data"]["limit"], 65536);
    assert_eq!(e["data"]["bytes"], 65537);

    let mut p = draft(2, "d5", "first edit");
    p["checkpoint"] = json!({"ref": "abc123", "attest": false});
    let e = call(&mut c, method::MUX_HANDOFF_DRAFT, p).await.unwrap_err();
    assert_eq!(reason(&e), "checkpoint_unattested", "{e}");
    let mut p = draft(2, "d6", "first edit");
    p["checkpoint"] = attested("abc123");
    let d = call(&mut c, method::MUX_HANDOFF_DRAFT, p).await.unwrap();
    assert_eq!(d["revision"], 3, "{d}");
    let cp = &d["capsule"]["checkpoint"];
    assert_eq!(cp["ref"], "abc123");
    assert_eq!(cp["attestedBy"], "user");
    assert!(str_of(cp, "/attestedAt").ends_with('Z'), "{cp}");
    let mut p = draft(3, "d7", "first edit");
    p["checkpoint"] = Value::Null;
    let cleared = call(&mut c, method::MUX_HANDOFF_DRAFT, p).await.unwrap();
    assert!(cleared["capsule"]["checkpoint"].is_null(), "{cleared}");
    assert_eq!(cleared["revision"], 4);
}

#[tokio::test]
async fn start_needs_an_attested_checkpoint() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "cp").await;
    let h =
        call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k-cp")).await.unwrap();
    let id = str_of(&h, "/handoffId");
    let target = str_of(&h, "/target/sessionId");
    let start = json!({"handoffId": id, "revision": 1, "capsule": {"text": h["capsule"]["text"]}});
    let e = call(&mut c, method::MUX_HANDOFF_START, start.clone()).await.unwrap_err();
    assert_eq!(reason(&e), "checkpoint_required", "{e}");
    for checkpoint in [json!({"ref": "", "attest": true}), json!({"ref": "abc123"})] {
        let mut p = start.clone();
        p["checkpoint"] = checkpoint;
        let e = call(&mut c, method::MUX_HANDOFF_START, p).await.unwrap_err();
        assert_eq!(reason(&e), "checkpoint_unattested", "{e}");
    }
    assert_eq!(user_messages(&hub, target), 0);
    let got = call(&mut c, method::MUX_HANDOFF_GET, json!({"handoffId": id})).await.unwrap();
    assert_eq!(got["state"], "draft", "{got}");
}

#[tokio::test]
async fn start_delivers_once_and_a_retry_with_the_same_prompt_id_reconciles() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "start").await;
    c.request(method::SESSION_PROMPT, prompt(&src, "context", None)).await.unwrap();
    let mut p = prepare(&src, "mirror", "k-start");
    p["checkpoint"] = attested("abc123");
    let h = call(&mut c, method::MUX_HANDOFF_PREPARE, p).await.unwrap();
    let id = str_of(&h, "/handoffId");
    let target = str_of(&h, "/target/sessionId");
    let start = json!({"handoffId": id, "revision": 1, "capsule": {"text": h["capsule"]["text"]}});
    let r = call(&mut c, method::MUX_HANDOFF_START, start.clone()).await.unwrap();
    assert_eq!(r["outcome"], "started", "{r}");
    assert_eq!(r["handoffId"], id);
    assert_eq!(r["promptId"], id, "promptId defaults to handoffId");
    assert_eq!(r["targetSessionId"], target);
    let turn_id = str_of(&r, "/turnId").to_owned();

    let mut retry = start.clone();
    retry["promptId"] = json!(id);
    let again = call(&mut c, method::MUX_HANDOFF_START, retry).await.unwrap();
    assert_eq!(again["outcome"], "already_started", "{again}");
    assert_eq!(again["turnId"], turn_id);
    assert_eq!(user_messages(&hub, target), 1, "the capsule reaches the target once");
    assert_eq!(hub.resolve(target).unwrap().meta().turn_count, 1);

    let mut other = start.clone();
    other["promptId"] = json!("another-prompt");
    let e = call(&mut c, method::MUX_HANDOFF_START, other).await.unwrap_err();
    assert_eq!(reason(&e), "already_started", "{e}");
    assert_eq!(e["data"]["handoff"]["state"], "started");
    let got = call(&mut c, method::MUX_HANDOFF_GET, json!({"handoffId": id})).await.unwrap();
    assert_eq!(got["state"], "started", "{got}");
    assert_eq!(got["promptId"], id);
    assert_eq!(got["turnId"], turn_id);
    let e = call(&mut c, method::MUX_HANDOFF_DISCARD, json!({"handoffId": id})).await.unwrap_err();
    assert_eq!(reason(&e), "already_started", "{e}");
    assert_eq!(user_messages(&hub, target), 1);
}

#[tokio::test]
async fn discard_closes_the_unprompted_target_and_keeps_the_source() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "keep").await;
    c.request(method::SESSION_PROMPT, prompt(&src, "context", None)).await.unwrap();
    let h = call(&mut c, method::MUX_HANDOFF_PREPARE, prepare(&src, "mirror", "k-discard"))
        .await
        .unwrap();
    let id = str_of(&h, "/handoffId");
    let target = str_of(&h, "/target/sessionId");
    let source_seq = hub.resolve(&src).unwrap().meta().last_seq;
    for _ in 0..2 {
        let d = call(&mut c, method::MUX_HANDOFF_DISCARD, json!({"handoffId": id})).await.unwrap();
        assert_eq!(d, json!({"handoffId": id, "discarded": true}));
    }
    assert_eq!(hub.session_summary(&hub.resolve(target).unwrap())["status"], "closed");
    let source = hub.resolve(&src).unwrap();
    assert_ne!(hub.session_summary(&source)["status"], "closed");
    assert_eq!(source.meta().last_seq, source_seq, "the source is never modified");
    assert_eq!(user_messages(&hub, target), 0);
    let got = call(&mut c, method::MUX_HANDOFF_GET, json!({"handoffId": id})).await.unwrap();
    assert_eq!(got["state"], "discarded", "{got}");
    let none = call(&mut c, method::MUX_HANDOFF_GET, json!({"sessionId": src})).await.unwrap();
    assert!(none.is_null(), "a discarded handoff no longer marks its source: {none}");
    let start = json!({"handoffId": id, "revision": 1, "capsule": {"text": "x"}, "checkpoint": attested("abc")});
    let e = call(&mut c, method::MUX_HANDOFF_START, start).await.unwrap_err();
    assert_eq!(reason(&e), "discarded", "{e}");
}

#[tokio::test]
async fn a_start_retry_after_a_restart_reconciles_from_the_target_log() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let (hub, cfg) = handoff_hub(Some(dir.as_path()));
    let mut c = connect(&hub).await;
    let src = new_session(&mut c, "restart").await;
    c.request(method::SESSION_PROMPT, prompt(&src, "context", None)).await.unwrap();
    let mut p = prepare(&src, "mirror", "k-restart");
    p["checkpoint"] = attested("abc123");
    let h = call(&mut c, method::MUX_HANDOFF_PREPARE, p).await.unwrap();
    let id = str_of(&h, "/handoffId").to_owned();
    let target = str_of(&h, "/target/sessionId").to_owned();
    let start = json!({"handoffId": id, "revision": 1, "promptId": id, "capsule": {"text": h["capsule"]["text"]}});
    let first = call(&mut c, method::MUX_HANDOFF_START, start.clone()).await.unwrap();
    assert_eq!(first["outcome"], "started", "{first}");
    for _ in 0..200 {
        if hub.resolve(&target).unwrap().turn().is_none() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    hub.shutdown_all().await;
    drop(hub);

    // A crash between delivery and the receipt: the record still says starting.
    let path = dir.join("handoffs").join(format!("{id}.json"));
    let mut rec: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(rec["state"], "started", "{rec}");
    rec["state"] = json!("starting");
    rec["turnId"] = Value::Null;
    std::fs::write(&path, serde_json::to_vec(&rec).unwrap()).unwrap();

    let hub2 = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut c2 = connect(&hub2).await;
    let got = call(&mut c2, method::MUX_HANDOFF_GET, json!({"handoffId": id})).await.unwrap();
    assert_eq!(got["state"], "starting", "{got}");
    assert_eq!(got["promptId"], id);
    let again = call(&mut c2, method::MUX_HANDOFF_START, start).await.unwrap();
    assert_eq!(again["outcome"], "already_started", "{again}");
    assert_eq!(again["turnId"], first["turnId"]);
    assert_eq!(user_messages(&hub2, &target), 1, "no second send after the restart");
    let got = call(&mut c2, method::MUX_HANDOFF_GET, json!({"sessionId": target})).await.unwrap();
    assert_eq!(got["state"], "started", "{got}");
    hub2.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn initialize_advertises_handoff_and_summaries_carry_enforcement() {
    let (hub, _) = handoff_hub(None);
    let mut c = connect(&hub).await;
    let init = c
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await
        .unwrap();
    let ops: Vec<&str> = init
        .pointer("/_meta/acpmux/operations")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    for m in [
        method::MUX_HANDOFF_PREPARE,
        method::MUX_HANDOFF_GET,
        method::MUX_HANDOFF_DRAFT,
        method::MUX_HANDOFF_START,
        method::MUX_HANDOFF_DISCARD,
    ] {
        assert!(ops.contains(&m), "initialize is missing {m}: {init}");
    }
    assert_eq!(init["_meta"]["acpmux"]["handoff"]["maxCapsuleBytes"], 65536, "{init}");

    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let e = &s["_meta"]["acpmux"]["enforcement"];
    assert_eq!(e["label"], "native_policy", "{s}");
    assert_eq!(e["isolation"], "unverified");
    assert!(e["policy"].is_string(), "{e}");
    assert!(s["_meta"]["acpmux"].get("coverage").is_none(), "coverage exists only in a handoff");
    let all = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    for summary in all["sessions"].as_array().unwrap() {
        assert_eq!(summary["enforcement"]["label"], "native_policy", "{summary}");
    }
}
