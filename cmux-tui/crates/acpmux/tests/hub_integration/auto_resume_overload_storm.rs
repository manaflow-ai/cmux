//! A 529/503/502 storm (Leo, 2026-11-23: "I can't even talk to the GUI chats right now because
//! of alleged overload"; "idk why you keep dying"). The model answers every request, `/compact`
//! included, with a capacity error (`FAKE_CAPACITY_FILE`): the provider's 529 overloaded, the
//! SR2 gateway's 503 "no non-exhausted accounts" and the worker gateway's 502 "at its call
//! limit", in turn, for longer than the configured waits last. What must hold:
//! - the session never gives up: its continuation goes on past the configured attempts and no
//!   `auto_resume_exhausted` is written; the row says a capacity retry waits, and when;
//! - a person's message sent meanwhile (as a GUI chat sends it) is taken, never refused by
//!   anything but the capacity error itself, and once capacity is back its chain completes;
//! - a `/compact` the storm cut is sent again as `/compact`, not as "continue", and completes.
use super::*;

/// The configured waits, scaled down: a bounded loop would give up after these two.
const DELAYS_MS: [u64; 2] = [200, 400];
/// How long the storm lasts: past both waits and two more doublings (800, 1600 ms).
const STORM_MS: u64 = 3_600;

fn of_kind(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 100_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

/// The prompt ids of the turns that completed, each with its `user_message` text.
fn completed(hub: &Hub, id: &str) -> Vec<(String, String)> {
    let all = hub.events(id, 0, 100_000).unwrap();
    let done: Vec<&Value> = all
        .iter()
        .filter(|e| e.kind == "turn_result" && e.msg["status"] == "completed")
        .map(|e| &e.msg["turnId"])
        .collect();
    all.iter()
        .filter(|e| e.kind == "user_message" && done.contains(&&e.msg["turnId"]))
        .map(|e| {
            let p = e.msg.pointer("/_meta/provenance/promptId").and_then(Value::as_str);
            (p.unwrap_or_default().to_owned(), e.msg.to_string())
        })
        .collect()
}

async fn prompt(
    c: &mut TestClient,
    id: &str,
    prompt_id: &str,
    text: &str,
) -> Result<Value, String> {
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}}),
    )
    .await
}

/// One of the storm's three errors, as the turn's answer carries it.
fn is_capacity(e: &str) -> bool {
    ["529", "no non-exhausted", "at its call limit"].iter().any(|w| e.contains(w))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_overload_storm_kills_no_session_refuses_no_message_and_drops_no_compact() {
    let root = std::env::temp_dir().join(format!("acpmux-overload-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let storm = root.join("overloaded");
    std::fs::write(&storm, "").unwrap();
    let env =
        BTreeMap::from([("FAKE_CAPACITY_FILE".to_owned(), storm.to_string_lossy().into_owned())]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    hub.config.write().await.auto_resume_delays_ms = Some(DELAYS_MS.to_vec());
    let lane = new_session(&mut c, "lane-overload").await;
    let chat = new_session(&mut c, "gui-overload").await;

    // The lane's turn and its /compact, and the person's GUI message, all hit the storm.
    let e = prompt(&mut c, &lane, "p-build", "build it").await.unwrap_err();
    assert!(is_capacity(&e), "{e}");
    let e = prompt(&mut c, &chat, "p-person", "please also fix the sidebar").await.unwrap_err();
    assert!(is_capacity(&e), "the person's message is refused only by the storm: {e}");

    // Mid-storm the row says a capacity retry waits.
    tokio::time::sleep(Duration::from_millis(DELAYS_MS[0] / 2)).await;
    let row = hub.session_summary(&hub.resolve(&chat).unwrap());
    assert_eq!(row["retry"]["reason"], "capacity", "{row}");
    assert!(row["retry"]["nextAt"].as_u64().is_some(), "{row}");

    // The lane's continuation runs into the storm; then its /compact does too.
    let start = tokio::time::Instant::now();
    while of_kind(&hub, &lane, "auto_resume_scheduled").len() < 2
        && start.elapsed() < Duration::from_secs(10)
    {
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let e = prompt(&mut c, &lane, "p-compact", "/compact").await.unwrap_err();
    assert!(is_capacity(&e), "{e}");

    tokio::time::sleep(Duration::from_millis(STORM_MS)).await;

    // 1. Nobody gave up: past the two configured attempts, no exhaustion.
    for id in [&lane, &chat] {
        assert!(
            of_kind(&hub, id, "auto_resume_exhausted").is_empty(),
            "{:?}",
            of_kind(&hub, id, "auto_resume_exhausted")
        );
    }
    let person_attempts: Vec<Value> = of_kind(&hub, &chat, "auto_resume_scheduled")
        .into_iter()
        .filter(|m| m["promptId"] == "p-person")
        .collect();
    assert!(
        person_attempts.len() > DELAYS_MS.len(),
        "the person's chain stopped at the configured attempts: {person_attempts:?}"
    );
    assert!(
        person_attempts.iter().all(|m| m["reason"] == "capacity" && m["untilCapacity"] == true),
        "{person_attempts:?}"
    );
    // 2. The cut /compact went again as /compact, under its own prompt id.
    let compact_retries: Vec<Value> = of_kind(&hub, &lane, "user_message")
        .into_iter()
        .filter(|m| m.pointer("/_meta/provenance/promptId") == Some(&json!("p-compact")))
        .collect();
    assert!(!compact_retries.is_empty(), "the cut /compact was never retried");
    assert!(
        compact_retries
            .iter()
            .all(|m| m.to_string().contains("/compact") && !m.to_string().contains("cut off")),
        "a /compact retry was sent as a continuation: {compact_retries:?}"
    );
    let seen = std::fs::read_to_string(root.join("overloaded.seen")).unwrap();
    assert!(seen.lines().filter(|l| *l == "\"/compact\"").count() >= 2, "{seen}");

    // 3. Capacity comes back: both chains complete; the person's message and the /compact land.
    std::fs::remove_file(&storm).unwrap();
    let lifted = tokio::time::Instant::now();
    let (mut chat_done, mut lane_done) = (Vec::new(), Vec::new());
    while lifted.elapsed() < Duration::from_secs(20) {
        chat_done = completed(&hub, &chat);
        lane_done = completed(&hub, &lane);
        if chat_done.iter().any(|(p, _)| p == "p-person")
            && lane_done.iter().any(|(p, _)| p == "p-compact")
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        chat_done.iter().any(|(p, _)| p == "p-person"),
        "the person's chain never completed: {chat_done:?}"
    );
    assert!(
        lane_done.iter().any(|(p, t)| p == "p-compact" && t.contains("/compact")),
        "the /compact never completed: {lane_done:?}"
    );
    // The person's words reached the model (the turn the storm cut sent them; the agent's
    // transcript keeps them), and the continuation told it to go on from there.
    assert!(seen.contains("please also fix the sidebar"), "{seen}");
    let row = hub.session_summary(&hub.resolve(&chat).unwrap());
    assert!(row["retry"].is_null(), "{row}");

    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
