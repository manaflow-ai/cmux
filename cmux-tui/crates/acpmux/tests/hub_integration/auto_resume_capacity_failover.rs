//! A chat whose provider stays overloaded goes on on a smaller model, and back once a turn there
//! ends well (`hub/auto_resume/capacity_failover.rs`; Leo, 2026-11-24: "fix 529s properly with
//! better designs"). The fake agent here acts as Claude Code (a `model` option, set_model) and
//! fails its first three turns with the SR2 gateway's capacity error (`cap-fail-three:`).
use super::*;

const OPUS: &str = "claude-opus-5-5";
const SONNET: &str = "claude-sonnet-5-5";

/// A hub whose fake agent reports and switches its model as Claude Code does, the attempts 50 ms
/// apart, switching after `after` capacity attempts; one chat on `model`.
async fn chat_on(model: &str, after: u64) -> (Arc<Hub>, TestClient, String) {
    let env = BTreeMap::from([
        ("FAKE_PICKER".to_owned(), "1".to_owned()),
        ("FAKE_PICKER_MODES".to_owned(), "claude".to_owned()),
    ]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    {
        let mut cfg = hub.config.write().await;
        cfg.auto_resume_delays_ms = Some(vec![50]);
        cfg.capacity_fallback_after = Some(after);
    }
    let id = new_session(&mut c, "overloaded").await;
    let session = hub.resolve(&id).unwrap();
    hub.set_model(&session, model).await.unwrap();
    assert_eq!(model_now(&hub, &id).as_deref(), Some(model));
    (hub, c, id)
}

/// The model the chat's `model` option says it runs.
fn model_now(hub: &Hub, id: &str) -> Option<String> {
    let meta = hub.resolve(id).unwrap().meta();
    let opts = meta.config_options.as_deref().and_then(Value::as_array).cloned()?;
    opts.iter().find(|o| o["id"] == "model")?["currentValue"].as_str().map(str::to_owned)
}

fn records(hub: &Hub, id: &str, kind: &str) -> Vec<acpmux::store::EventRecord> {
    hub.events(id, 0, 10_000).unwrap().into_iter().filter(|e| e.kind == kind).collect()
}

/// The models the chat was switched to, in order (its `config` records for `model`).
fn switches(hub: &Hub, id: &str) -> Vec<(u64, String)> {
    records(hub, id, "config")
        .into_iter()
        .filter(|e| e.msg["configId"] == "model")
        .map(|e| (e.seq, e.msg["value"].as_str().unwrap_or_default().to_owned()))
        .collect()
}

/// Sends the prompt the fake agent fails three times, and waits for the fourth turn to complete.
async fn overload(hub: &Hub, c: &mut TestClient, id: &str) {
    let err = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "cap-fail-three: build it"}], "_meta": {"acpmux": {"promptId": "p-529"}}}),
        )
        .await
        .unwrap_err();
    assert!(err.contains("no non-exhausted claude accounts"), "{err}");
    until(hub, id, |_| {
        hub.session_summary(&hub.resolve(id).unwrap())["lastTurn"]["status"] == "completed"
    })
    .await;
    let messages = user_messages(hub, id);
    assert_eq!(messages.len(), 4, "{messages:?}");
    assert_eq!(messages[3]["promptId"], "p-529~resume-3");
}

#[tokio::test]
async fn three_capacity_failures_run_the_fourth_attempt_on_sonnet_then_opus_comes_back() {
    let (hub, mut c, id) = chat_on(OPUS, 3).await;
    overload(&hub, &mut c, &id).await;

    // One switch, at attempt 3 (the fourth try), with its notice.
    let failover = records(&hub, &id, "capacity_failover");
    assert_eq!(failover.len(), 1, "{failover:?}");
    let f = &failover[0].msg;
    assert_eq!(f["from"], OPUS, "{f}");
    assert_eq!(f["to"], SONNET, "{f}");
    assert_eq!(f["attempt"], 3, "{f}");
    assert_eq!(f["promptId"], "p-529", "{f}");
    assert_eq!(
        f["text"],
        "acpmux: Anthropic overloaded: continuing on claude-sonnet-5-5 (was claude-opus-5-5); back when it recovers"
    );
    // The model was Sonnet before the fourth prompt went out, and not before the third.
    let prompts = records(&hub, &id, "user_message");
    let to_sonnet = switches(&hub, &id).into_iter().find(|(_, m)| m == SONNET).expect("a switch");
    assert!(to_sonnet.0 > prompts[2].seq && to_sonnet.0 < prompts[3].seq, "{to_sonnet:?}");

    // The fourth turn ended well: Opus comes back, with one notice.
    until(&hub, &id, |k| k.iter().any(|k| k == "capacity_restored")).await;
    let restored = records(&hub, &id, "capacity_restored");
    assert_eq!(restored.len(), 1, "{restored:?}");
    assert_eq!(restored[0].msg["from"], SONNET);
    assert_eq!(restored[0].msg["to"], OPUS);
    assert!(restored[0].seq > prompts[3].seq);
    assert_eq!(model_now(&hub, &id).as_deref(), Some(OPUS));
    assert_eq!(hub.resolve(&id).unwrap().meta().capacity_fallback, None);
    // The notices are transcript rows.
    let notices: Vec<String> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind.starts_with("capacity_"))
        .map(|e| e.msg["text"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(notices.len(), 2, "{notices:?}");
}

#[tokio::test]
async fn capacity_fallback_after_0_never_switches() {
    let (hub, mut c, id) = chat_on(OPUS, 0).await;
    overload(&hub, &mut c, &id).await;
    assert!(records(&hub, &id, "capacity_failover").is_empty());
    assert!(records(&hub, &id, "capacity_restored").is_empty());
    assert!(switches(&hub, &id).iter().all(|(_, m)| m == OPUS), "{:?}", switches(&hub, &id));
    assert_eq!(model_now(&hub, &id).as_deref(), Some(OPUS));
}

#[tokio::test]
async fn a_chat_already_on_sonnet_stays_on_it() {
    let (hub, mut c, id) = chat_on(SONNET, 3).await;
    overload(&hub, &mut c, &id).await;
    assert!(records(&hub, &id, "capacity_failover").is_empty());
    assert!(switches(&hub, &id).iter().all(|(_, m)| m == SONNET), "{:?}", switches(&hub, &id));
    assert_eq!(model_now(&hub, &id).as_deref(), Some(SONNET));
    assert_eq!(hub.resolve(&id).unwrap().meta().capacity_fallback, None);
}

/// cmux#57784: chats started on Opus 5.5 were left on Sonnet 5.5. The gateway's own 503s cut
/// every turn, so no turn ended well on the fallback to put Opus back, and the picker showed
/// Sonnet for good. Off by default now; a chat a past switch left there goes back to its own
/// model before its next prompt goes in, so even the first try runs on Opus.
#[tokio::test]
async fn a_chat_left_on_its_fallback_goes_back_when_switching_is_off() {
    let (hub, mut c, id) = chat_on(SONNET, 0).await;
    let session = hub.resolve(&id).unwrap();
    session.leave_on_capacity_fallback_for_tests(acpmux::store::CapacityFallback {
        from: OPUS.to_owned(),
        to: SONNET.to_owned(),
    });
    overload(&hub, &mut c, &id).await;

    assert!(records(&hub, &id, "capacity_failover").is_empty());
    let restored = records(&hub, &id, "capacity_restored");
    assert_eq!(restored.len(), 1, "{restored:?}");
    assert_eq!(restored[0].msg["from"], SONNET);
    assert_eq!(restored[0].msg["to"], OPUS);
    // Back before the prompt itself went out: it and every retry ran on Opus.
    let prompts = records(&hub, &id, "user_message");
    assert!(restored[0].seq < prompts[0].seq, "{restored:?}");
    let to_opus = switches(&hub, &id).into_iter().rfind(|(_, m)| m == OPUS).expect("a switch");
    assert!(to_opus.0 < prompts[0].seq, "{to_opus:?}");
    assert_eq!(model_now(&hub, &id).as_deref(), Some(OPUS));
    assert_eq!(hub.resolve(&id).unwrap().meta().capacity_fallback, None);
}

/// Leo, 2026-11-26: "austin noticed his models getting switched to sonnet. we shouldnt do that".
/// A chat a past switch left on Sonnet that sits idle runs the person's next prompt on Opus,
/// with no capacity error at all, and says so once.
#[tokio::test]
async fn the_next_prompt_of_a_chat_left_on_its_fallback_runs_on_its_own_model() {
    let (hub, mut c, id) = chat_on(SONNET, 0).await;
    let session = hub.resolve(&id).unwrap();
    session.leave_on_capacity_fallback_for_tests(acpmux::store::CapacityFallback {
        from: OPUS.to_owned(),
        to: SONNET.to_owned(),
    });
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]}),
    )
    .await
    .unwrap();

    let restored = records(&hub, &id, "capacity_restored");
    assert_eq!(restored.len(), 1, "{restored:?}");
    let prompts = records(&hub, &id, "user_message");
    assert!(restored[0].seq < prompts[0].seq, "{restored:?} {prompts:?}");
    assert_eq!(model_now(&hub, &id).as_deref(), Some(OPUS));
    assert_eq!(hub.resolve(&id).unwrap().meta().capacity_fallback, None);
}

/// A person who picked another model after the switch keeps theirs.
#[tokio::test]
async fn a_model_the_person_picked_after_the_switch_stays() {
    const HAIKU: &str = "claude-haiku-5-5";
    let (hub, mut c, id) = chat_on(HAIKU, 0).await;
    let session = hub.resolve(&id).unwrap();
    session.leave_on_capacity_fallback_for_tests(acpmux::store::CapacityFallback {
        from: OPUS.to_owned(),
        to: SONNET.to_owned(),
    });
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]}),
    )
    .await
    .unwrap();
    assert!(records(&hub, &id, "capacity_restored").is_empty());
    assert_eq!(model_now(&hub, &id).as_deref(), Some(HAIKU));
}
