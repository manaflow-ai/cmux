//! The account's rate limit holds the chat until its reset (`hub/rate_hold.rs`). Leo,
//! 2026-11-17: "the old coord keeps running into these rate limit spirals" / "oh i mean not gh".
//! claude-sr2-coord-old failed 207 of 400 turns on one 429: every message from another agent
//! started a turn of its own, each resending a 323K context into the same limit.
use super::*;

const LIMIT: &str =
    "API Error: Request rejected (429) · This request would exceed your account's rate limit";

fn events(hub: &Hub, id: &str) -> Vec<acpmux::store::EventRecord> {
    hub.events(id, 0, 10_000).unwrap()
}

fn of_kind(hub: &Hub, id: &str, kind: &str) -> Vec<acpmux::store::EventRecord> {
    events(hub, id).into_iter().filter(|e| e.kind == kind).collect()
}

fn from_agent(id: &str, prompt_id: &str, agent: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": agent}}})
}

/// A 429 that names its reset T, then ten messages from other agents while it holds: exactly
/// one turn after T, carrying all ten and the continuation's words; none before T.
async fn ten_messages_make_one_turn_after_the_reset(hub: Arc<Hub>, mut c: TestClient) {
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25, 25, 25, 25]);
    let id = new_session(&mut c, "coord-old").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: {LIMIT}; Retry-After: 2")}],
        "_meta": {"acpmux": {"promptId": "p-cut"}}
    })).await;
    assert!(r.unwrap_err().contains("429"));
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    let held = of_kind(&hub, &id, "rate_limit_held");
    let reset =
        held.last().unwrap_or_else(|| panic!("no hold: {k:?}")).msg["until"].as_u64().unwrap();
    let failed_at = of_kind(&hub, &id, "turn_result")[0].at;
    assert!(reset >= failed_at + 1_900, "the hold waits for the reset: {reset} vs {failed_at}");
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(row["rateLimitedUntil"], reset, "{row}");
    assert_eq!(row["retry"]["reason"], "rate_limit", "{row}");

    let mut sent = Vec::new();
    for n in 0..10 {
        sent.push(
            c.send(
                method::SESSION_PROMPT,
                from_agent(&id, &format!("m-{n}"), &format!("lane-{n}"), &format!("report {n}")),
            )
            .await,
        );
    }
    // Every message waits out the hold: none starts a turn before the reset.
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert!(acpmux::store::now_ms() < reset, "the test reached the reset before it looked");
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "{:?}", kinds(&hub, &id));

    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 2).await;
    // Give a second turn the time to start if one were coming.
    tokio::time::sleep(Duration::from_millis(800)).await;
    let started = of_kind(&hub, &id, "turn_started");
    assert_eq!(started.len(), 2, "exactly one turn after the reset: {k:?}");
    assert!(started[1].at >= reset, "it started at the reset: {} < {reset}", started[1].at);
    let skipped = of_kind(&hub, &id, "auto_resume_skipped");
    assert_eq!(skipped.len(), 1, "{skipped:?}");
    assert_eq!(skipped[0].msg["skipped"], "folded", "{skipped:?}");
    let last = user_messages(&hub, &id).pop().unwrap().to_string();
    for n in 0..10 {
        assert!(last.contains(&format!("report {n}")), "message {n} missing from {last}");
    }
    assert!(last.contains("rate limit"), "the turn carries the continuation's words: {last}");
    assert_eq!(of_kind(&hub, &id, "rate_limit_lifted").len(), 1);
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row.get("rateLimitedUntil").is_none(), "{row}");
    drop(sent);
}

#[tokio::test]
async fn a_rate_limit_hold_turns_ten_queued_messages_into_one_turn_after_the_reset() {
    let (hub, c) = setup_queue(PermissionPolicy::ApproveAll).await;
    ten_messages_make_one_turn_after_the_reset(hub, c).await;
}

#[tokio::test]
async fn a_rate_limit_with_nothing_queued_continues_alone_at_the_reset() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = new_session(&mut c, "alone").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: {LIMIT}; Retry-After: 1")}],
        "_meta": {"acpmux": {"promptId": "p-alone"}}
    })).await;
    assert!(r.is_err());
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 2).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{k:?}");
    assert_eq!(messages[1]["promptId"], "p-alone~resume-1");
    let reset = of_kind(&hub, &id, "rate_limit_held")[0].msg["until"].as_u64().unwrap();
    assert!(of_kind(&hub, &id, "turn_started")[1].at >= reset);
    assert!(of_kind(&hub, &id, "auto_resume_skipped").is_empty());
}

#[tokio::test]
async fn a_529_is_capacity_and_holds_nothing() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = new_session(&mut c, "overloaded").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": "recover-once: API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"}],
        "_meta": {"acpmux": {"promptId": "p-529"}}
    })).await;
    assert!(r.is_err());
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 2).await;
    assert!(!k.iter().any(|k| k == "rate_limit_held"), "{k:?}");
    let scheduled = of_kind(&hub, &id, "auto_resume_scheduled");
    assert_eq!(scheduled[0].msg["reason"], "capacity", "{scheduled:?}");
}

/// A chat cut by a 429 whose reset is ten minutes away, held, with another agent's message
/// queued behind the hold.
async fn held_chat(c: &mut TestClient, hub: &Hub, name: &str) -> String {
    let id = new_session(c, name).await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: {LIMIT}; Retry-After: 600")}],
        "_meta": {"acpmux": {"promptId": format!("p-{name}")}}
    })).await;
    assert!(r.is_err());
    until(hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-late", "lane", "late report")).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(of_kind(hub, &id, "turn_started").len(), 1, "{:?}", kinds(hub, &id));
    id
}

/// Leo's Mac, 2026-11-18: after `acpmux session stop` on the coordinator in its 429 loop,
/// another agent's message started a new turn at once. Stop on a rate-limited chat parks it:
/// no turn starts by itself, what comes in queues, and `_acpmux/retry` sends the waiting
/// continuation on with what queued, as one turn.
#[tokio::test]
async fn stop_parks_a_rate_limited_chat_until_a_retry() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = held_chat(&mut c, &hub, "stopped").await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "rate_limit_parked")).await;
    let parked = of_kind(&hub, &id, "rate_limit_parked");
    assert_eq!(parked.len(), 1, "{k:?}");
    assert_eq!(parked[0].msg["why"], "stopped", "{parked:?}");
    let notice = json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": "[notice from task-watch] background task done"}],
        "_meta": {"acpmux": {"promptId": "n-bg", "fromAgent": "task-watch"}}
    });
    c.send(method::SESSION_PROMPT, notice).await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-later", "lane-2", "later report")).await;
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "{:?}", kinds(&hub, &id));
    assert!(of_kind(&hub, &id, "rate_limit_lifted").is_empty(), "{:?}", kinds(&hub, &id));
    assert!(of_kind(&hub, &id, "auto_resume_stopped").is_empty(), "{:?}", kinds(&hub, &id));
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row["rateLimitParked"].as_u64().is_some(), "{row}");

    // The retry sends the continuation on: one turn, carrying everything that queued.
    c.request("_acpmux/retry", json!({"sessionId": id})).await.unwrap();
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 2).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 2, "{k:?}");
    let last = user_messages(&hub, &id).pop().unwrap().to_string();
    for words in ["late report", "later report", "background task done", "rate limit"] {
        assert!(last.contains(words), "{words} missing from {last}");
    }
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row.get("rateLimitParked").is_none(), "{row}");
    assert!(row.get("rateLimitedUntil").is_none(), "{row}");
}

/// The person's own prompt resumes a chat Stop parked: it runs at once, long before the reset,
/// carrying the continuation's words; the other agent's message goes in after it.
#[tokio::test]
async fn the_persons_own_prompt_resumes_a_chat_stop_parked() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = held_chat(&mut c, &hub, "resumed").await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    until(&hub, &id, |k| k.iter().any(|k| k == "rate_limit_parked")).await;
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "go on"}]}),
    )
    .await
    .unwrap();
    let unparked = of_kind(&hub, &id, "rate_limit_unparked");
    assert_eq!(unparked.len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(unparked[0].msg["why"], "prompt", "{unparked:?}");
    let mine = user_messages(&hub, &id)
        .into_iter()
        .find(|m| m.to_string().contains("go on"))
        .unwrap_or_else(|| panic!("{:?}", kinds(&hub, &id)));
    assert!(mine.to_string().contains("rate limit"), "{mine}");
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 3).await;
    let last = user_messages(&hub, &id).pop().unwrap().to_string();
    assert!(last.contains("late report"), "{last} {k:?}");
}

/// `acpmux session stop` (`_acpmux/kill`) on a rate-limited chat leaves it parked too: the next
/// message from another agent queues instead of starting its agent and a turn.
#[tokio::test]
async fn session_stop_leaves_a_rate_limited_chat_parked() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = held_chat(&mut c, &hub, "killed").await;
    c.request(method::MUX_KILL, json!({"sessionId": id, "purge": false})).await.unwrap();
    let parked = of_kind(&hub, &id, "rate_limit_parked");
    assert_eq!(parked.len(), 1, "{:?}", kinds(&hub, &id));
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-next", "lane-3", "next report")).await;
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "{:?}", kinds(&hub, &id));
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row["rateLimitParked"].as_u64().is_some(), "{row}");
    // The person's own prompt takes it back.
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "go on"}]}),
    )
    .await
    .unwrap();
    assert_eq!(of_kind(&hub, &id, "rate_limit_unparked").len(), 1, "{:?}", kinds(&hub, &id));
}

/// The wakes that fed the spiral on 2026-11-18, besides other agents' messages: a watchdog's
/// `acpmux retry` every minute and a tool's background-done notice. While the chat is held the
/// retry is refused (`retry.rate_limited`, with the hold's deadline) and the notice queues: no
/// turn starts before the reset.
#[tokio::test]
async fn a_retry_and_a_notice_start_no_turn_while_the_rate_limit_holds() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = new_session(&mut c, "woken").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: {LIMIT}; Retry-After: 600")}],
        "_meta": {"acpmux": {"promptId": "p-woken"}}
    })).await;
    assert!(r.is_err());
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    let until_ms = of_kind(&hub, &id, "rate_limit_held")[0].msg["until"].as_u64().unwrap();

    let err = c.request("_acpmux/retry", json!({"sessionId": id})).await.unwrap_err();
    assert!(err.contains("retry.rate_limited"), "{err}");
    let notice = json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": "[notice from task-watch] background task done"}],
        "_meta": {"acpmux": {"promptId": "n-bg", "fromAgent": "task-watch"}}
    });
    c.send(method::SESSION_PROMPT, notice).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(acpmux::store::now_ms() < until_ms);
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "{:?}", kinds(&hub, &id));
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    // The continuation re-sets the same hold when it starts waiting: its deadline, not earlier.
    assert!(row["rateLimitedUntil"].as_u64().is_some_and(|u| u >= until_ms), "{row}");
    assert_eq!(row["queue"][0]["promptId"], "n-bg", "the notice waits in the queue: {row}");
}

/// Leo, 2026-11-18: "claude-sr2-coord fell into a weird "rate limited" loop again 429 and
/// whatever". Six turns in a row that fail on the limit park the chat: its continuation waits,
/// a message from another agent starts nothing, and the row says so. Leo, 2026-11-24: "didn't we
/// build auto retries for this? why do they fail instead of waiting it out?": the park lifts
/// itself once its backoff ran out (20 ms doubled per strike: 640 ms here, half an hour by
/// default), and the waiting continuation goes on with the message as one turn.
#[tokio::test]
async fn six_failed_turns_in_a_row_park_the_chat_until_its_backoff_ran_out() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    // Two configured waits, fewer than the six failures: a rate limit never uses its attempts
    // up, so a continuation still waits when the sixth turn fails.
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20; 2]);
    let id = new_session(&mut c, "parked").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({
                "sessionId": id,
                "prompt": [{"type": "text", "text": format!("rate-fail-n:6:{LIMIT}")}],
                "_meta": {"acpmux": {"promptId": "p-park"}}
            }),
        )
        .await;
    assert!(r.is_err());
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "rate_limit_parked")).await;
    let parked = of_kind(&hub, &id, "rate_limit_parked");
    assert_eq!(parked.len(), 1, "{k:?}");
    assert_eq!(parked[0].msg["strikes"], 6, "{parked:?}");
    assert_eq!(parked[0].msg["noticed"], true, "{parked:?}");
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 6, "{k:?}");
    // Each continuation waited at least the chat's backoff: 20, 40, 80, 160, 320 ms.
    let scheduled = of_kind(&hub, &id, "auto_resume_scheduled");
    for (n, e) in scheduled.iter().take(5).enumerate() {
        let floor = 20u64 << n;
        assert!(e.msg["delayMs"].as_u64().unwrap() >= floor, "attempt {}: {e:?}", n + 1);
    }

    // Parked: another agent's message waits, and nothing starts before the backoff ran out.
    let parked_at = parked[0].at;
    let _late =
        c.send(method::SESSION_PROMPT, from_agent(&id, "m-late", "lane", "late report")).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 6, "{:?}", kinds(&hub, &id));
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row["rateLimitParked"].as_u64().is_some(), "{row}");
    assert!(row.get("rateLimitedUntil").is_none(), "{row}");

    // The park lifts itself: the waiting continuation goes on as one turn, with the message.
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 7).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 7, "{k:?}");
    let unparked = of_kind(&hub, &id, "rate_limit_unparked");
    assert_eq!(unparked.len(), 1, "{k:?}");
    assert_eq!(unparked[0].msg["why"], "backoff", "{unparked:?}");
    assert!(unparked[0].at >= parked_at + 600, "lifted before its backoff: {unparked:?}");
    assert!(of_kind(&hub, &id, "auto_resume_exhausted").is_empty(), "{k:?}");
    let last = user_messages(&hub, &id).pop().unwrap().to_string();
    assert!(last.contains("late report"), "{last}");
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row.get("rateLimitParked").is_none(), "{row}");
    assert!(row.get("rateLimitedUntil").is_none(), "{row}");
}

/// A Claude chat (the fake agent as `family = "claude"`, so it can compact) whose transcript
/// under its CLAUDE_CONFIG_DIR says its last call held `context` tokens, cut by a 429 that names
/// a reset 2 s on, with a message from another agent queued while it holds. Its home is the
/// returned temp dir; the reset is the hold's `until`.
async fn held_claude_chat(context: u64) -> (Arc<Hub>, TestClient, String, u64, tempfile::TempDir) {
    let home = tempfile::tempdir().unwrap();
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    {
        let mut config = hub.config.write().await;
        config.auto_resume_delays_ms = Some(vec![25]);
        let fake = config.harnesses.get_mut("fake").unwrap();
        fake.family = Some("claude".into());
        fake.env.insert("CLAUDE_CONFIG_DIR".into(), home.path().display().to_string());
    }
    let id = new_session(&mut c, "coord").await;
    // The transcript Claude Code would have written: one call, as fake_claude.py's reply with
    // FAKE_CLAUDE_TRANSCRIPT_USAGE=1 (3 input, 1000 cache write, the rest cache read).
    let sid = hub.resolve(&id).unwrap().meta().agent_session_id.unwrap();
    let projects = home.path().join("projects/p");
    std::fs::create_dir_all(&projects).unwrap();
    let at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let usage = json!({"input_tokens": 3, "cache_creation_input_tokens": 1000,
        "cache_read_input_tokens": context - 1003, "output_tokens": 50});
    let call = json!({"type": "assistant", "sessionId": sid, "timestamp": at, "message": {
        "id": "msg_1", "model": "claude-opus-5-5", "role": "assistant", "stop_reason": "end_turn",
        "content": [{"type": "text", "text": "ok"}], "usage": usage}});
    std::fs::write(projects.join(format!("{sid}.jsonl")), format!("{call}\n")).unwrap();

    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: {LIMIT}; Retry-After: 2")}],
        "_meta": {"acpmux": {"promptId": "p-cut"}}
    })).await;
    assert!(r.unwrap_err().contains("429"));
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    let held = of_kind(&hub, &id, "rate_limit_held");
    let reset =
        held.last().unwrap_or_else(|| panic!("no hold: {k:?}")).msg["until"].as_u64().unwrap();
    // The cut turn's end reads the transcript (off its path): the hub knows the context the
    // reset would resend.
    let mut stats = Value::Null;
    for _ in 0..50 {
        let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
        stats = info["usageStats"].clone();
        if stats["contextTokens"] == context {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(stats["contextTokens"], context, "{stats}");
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-held", "lane", "held report")).await;
    // The message waits out the hold: no turn starts before the reset.
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(acpmux::store::now_ms() < reset, "the test reached the reset before it looked");
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "{:?}", kinds(&hub, &id));
    (hub, c, id, reset, home)
}

/// Leo, 2026-11-18: "the gui coordinators keep saying stuff is rate limited and 429 and stuff
/// :(". A coordinator carries 300K+ of context; resending it at the reset spends the new window
/// at once. A held chat past 200K compacts first, then its one turn carries the continuation's
/// words and what the hold queued.
#[tokio::test]
async fn a_held_chat_past_200k_compacts_before_it_resumes() {
    // Give only this test's daemon the fleet policy. The other tests in this binary
    // share process environment when Cargo runs them together.
    if std::env::var(acpmux::compaction_policy::ENV_FLEET).as_deref() != Ok("1") {
        let name = std::thread::current().name().unwrap().to_owned();
        let report = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", &name, "--nocapture"])
            .env(acpmux::compaction_policy::ENV_FLEET, "1")
            .output()
            .unwrap();
        assert!(report.status.success(), "{}", String::from_utf8_lossy(&report.stderr));
        assert!(String::from_utf8_lossy(&report.stdout).contains("1 passed"));
        return;
    }
    let (hub, _c, id, reset, _home) = held_claude_chat(201_003).await;
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 3).await;
    // Give a fourth turn the time to start if one were coming.
    tokio::time::sleep(Duration::from_millis(800)).await;
    let started = of_kind(&hub, &id, "turn_started");
    let skipped = of_kind(&hub, &id, "auto_resume_skipped");
    assert_eq!(started.len(), 3, "the compaction, then one turn: {k:?} {skipped:?}");
    assert!(started[1].at >= reset, "it compacted at the reset: {} < {reset}", started[1].at);
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 3, "{messages:?}");
    assert_eq!(messages[0]["promptId"], "p-cut", "{messages:?}");
    assert_eq!(messages[1]["text"], "/compact", "{messages:?}");
    assert_eq!(messages[1]["promptId"], "p-cut~compact-1", "{messages:?}");
    assert_eq!(messages[1]["_meta"]["provenance"]["step"], "compact", "{messages:?}");
    let last = messages[2].to_string();
    assert!(last.contains("held report"), "the queued message missing from {last}");
    assert!(last.contains("rate limit"), "the turn carries the continuation's words: {last}");
    assert_eq!(of_kind(&hub, &id, "rate_limit_lifted").len(), 1, "{:?}", kinds(&hub, &id));
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row.get("rateLimitedUntil").is_none(), "{row}");
}

/// Under the line the reset sends the context as it is: no `/compact`, one turn.
#[tokio::test]
async fn a_held_chat_under_200k_resumes_without_a_compaction() {
    assert_plain_resume(151_003).await;
}

#[tokio::test]
async fn a_held_chat_past_200k_resumes_without_compaction_off_fleet() {
    assert_plain_resume(201_003).await;
}

async fn assert_plain_resume(context: u64) {
    let (hub, _c, id, reset, _home) = held_claude_chat(context).await;
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 2).await;
    tokio::time::sleep(Duration::from_millis(800)).await;
    let started = of_kind(&hub, &id, "turn_started");
    assert_eq!(started.len(), 2, "exactly one turn after the reset: {k:?}");
    assert!(started[1].at >= reset, "it started at the reset: {} < {reset}", started[1].at);
    let messages = user_messages(&hub, &id);
    assert!(!messages.iter().any(|m| m["text"] == "/compact"), "{messages:?}");
    let last = messages.last().unwrap().to_string();
    assert!(last.contains("held report") && last.contains("rate limit"), "{last}");
}

/// A turn that ends well clears the strikes: the next 429 waits the first backoff again.
#[tokio::test]
async fn a_turn_that_ends_well_clears_the_strikes() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20; 4]);
    let id = new_session(&mut c, "cleared").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({
                "sessionId": id,
                "prompt": [{"type": "text", "text": format!("rate-fail-n:2:{LIMIT}")}],
                "_meta": {"acpmux": {"promptId": "p-clear"}}
            }),
        )
        .await;
    assert!(r.is_err());
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 3).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!k.iter().any(|k| k == "rate_limit_parked"), "{k:?}");
    assert_eq!(hub.resolve(&id).unwrap().rate_hold_strikes(), 0, "{k:?}");
}

/// A daemon over a log on disk under `dir`, so a second one over the same `dir` is the daemon
/// after a restart, and a person's client of it.
async fn daemon_on_disk(dir: &std::path::Path) -> (Arc<Hub>, TestClient) {
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
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg.agent_inbox = Some(false);
    cfg.auto_resume_delays_ms = Some(vec![20; 6]);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, dir).unwrap());
    let c = connect(&hub).await;
    (hub, c)
}

/// The daemon handed off as an update hands it off: its log ends where it stood (`seal`), its
/// agents end, and a new daemon over the same log restores chat `id` and its queue.
async fn restarted(
    hub: Arc<Hub>,
    c: TestClient,
    dir: &std::path::Path,
    id: &str,
) -> (Arc<Hub>, TestClient) {
    hub.flush();
    hub.seal();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let (hub, c) = daemon_on_disk(dir).await;
    let _ = hub.resolve(id).unwrap();
    hub.resume_queues();
    (hub, c)
}

fn temp_dir(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("acpmux-rate-hold-{name}-{}", uuid::Uuid::now_v7()))
}

/// Leo's Mac, 2026-11-18 06:50-07:00Z: claude-sr2-coord was held for a 429 when a NIGHTLY
/// update restarted the daemon. The new daemon knew of no hold, and the chat failed 5 more
/// turns on 429. The hold is in the chat's log: the next daemon holds it to the same deadline,
/// the message that waited for the reset still waits, and the strikes carry over.
#[tokio::test]
async fn a_rate_limit_hold_survives_a_daemon_restart() {
    let dir = temp_dir("held");
    let (hub, mut c) = daemon_on_disk(&dir).await;
    let id = held_chat(&mut c, &hub, "coord").await;
    let held = of_kind(&hub, &id, "rate_limit_held").last().unwrap().msg["until"].as_u64().unwrap();
    assert_eq!(hub.resolve(&id).unwrap().rate_hold_strikes(), 1);

    let (hub, mut c) = restarted(hub, c, &dir, &id).await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-after", "lane-2", "after report")).await;
    tokio::time::sleep(Duration::from_millis(1_000)).await;
    let started = of_kind(&hub, &id, "turn_started").len();
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    let strikes = hub.resolve(&id).unwrap().rate_hold_strikes();
    let k = kinds(&hub, &id);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(started, 1, "a turn started before the reset: {k:?}");
    assert!(row["rateLimitedUntil"].as_u64().is_some_and(|u| u >= held), "{row}");
    assert_eq!(strikes, 1, "{k:?}");
}

/// A chat parked after six 429s in a row stays parked across a restart until its backoff ran
/// out, counted from when it parked: another agent's message waits, its strikes carry over, and
/// the restored park lifts itself and sends the continuation on with that message as one turn.
#[tokio::test]
async fn a_parked_chat_stays_parked_across_a_daemon_restart_until_its_backoff() {
    let dir = temp_dir("parked");
    let (hub, mut c) = daemon_on_disk(&dir).await;
    let id = new_session(&mut c, "parked").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({
                "sessionId": id,
                "prompt": [{"type": "text", "text": format!("rate-fail-n:6:{LIMIT}")}],
                "_meta": {"acpmux": {"promptId": "p-park"}}
            }),
        )
        .await;
    assert!(r.is_err());
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "rate_limit_parked")).await;
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 6, "{k:?}");
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-late", "lane", "late report")).await;
    tokio::time::sleep(Duration::from_millis(300)).await;

    let parked_at = of_kind(&hub, &id, "rate_limit_parked")[0].at;
    let (hub, c) = restarted(hub, c, &dir, &id).await;
    let started = of_kind(&hub, &id, "turn_started").len();
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    let strikes = hub.resolve(&id).unwrap().rate_hold_strikes();
    let k = kinds(&hub, &id);
    if started != 6 || row["rateLimitParked"].as_u64().is_none() || strikes != 6 {
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&dir);
        panic!("not parked after the restart: {started} turns, {strikes} strikes, {row}, {k:?}");
    }

    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 7).await;
    let unparked = of_kind(&hub, &id, "rate_limit_unparked");
    drop(c);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let started = of_kind(&hub, &id, "turn_started").len();
    let last = user_messages(&hub, &id).pop().unwrap().to_string();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(started, 7, "{k:?}");
    assert!(last.contains("late report") && last.contains("rate limit"), "{last}");
    assert_eq!(unparked.len(), 1, "{k:?}");
    assert_eq!(unparked[0].msg["why"], "backoff", "{unparked:?}");
    assert!(unparked[0].at >= parked_at + 600, "lifted before its backoff: {unparked:?}");
}

/// A connection from inside session `sid` (its caller token): an agent's, not the person's.
async fn agent_in(hub: &Arc<Hub>, sid: &str) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let token = acpmux::hub::person::caller_token(sid);
    let init = json!({"protocolVersion": 1,
        "_meta": {"acpmux": {"callerSession": {"sessionId": sid, "token": token}}}});
    c.request(method::INITIALIZE, init).await.unwrap();
    c
}

/// Leo, 2026-11-18: "claude-sr2-coord fell into a weird "rate limited" loop again 429 and
/// whatever". A turn Claude Code starts itself (here for a background shell's notice) that fails
/// on the limit is a strike and holds the chat, as a prompted turn's 429 does. Before, only a
/// turn acpmux prompted counted: the chat stayed unheld and the queue's next turn went at once.
#[cfg(unix)]
#[tokio::test]
async fn a_429_on_a_turn_claude_code_started_itself_holds_the_chat() {
    let root = std::env::temp_dir().join(format!("acpmux-bg429-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let gate = root.join("gate");
    let path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let (hub, mut c) = super::super::fork_through::claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let said = format!("own-turn-fail: {} :: {LIMIT}", gate.display());
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]}),
    )
    .await
    .unwrap();
    assert!(of_kind(&hub, &id, "rate_limit_held").is_empty(), "{:?}", kinds(&hub, &id));

    let g = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(g, b"go")).await.unwrap().unwrap();
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "rate_limit_held")).await;
    let ended = of_kind(&hub, &id, "background_turn");
    assert!(ended.iter().any(|e| e.msg["reason"] == "result"), "the own turn ran: {k:?}");
    let held = of_kind(&hub, &id, "rate_limit_held");
    assert_eq!(held.len(), 1, "its 429 holds the chat: {k:?}");
    assert_eq!(held[0].msg["strikes"], 1, "and is a strike: {held:?}");
    let session = hub.resolve(&id).unwrap();
    let row = hub.session_summary(&session);
    let until_ms = row["rateLimitedUntil"].as_u64().unwrap_or_else(|| panic!("{row}"));
    assert!(until_ms > acpmux::store::now_ms(), "{row}");
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "it started no acpmux turn: {k:?}");
    let _ = std::fs::remove_dir_all(root);
}

/// A chat Stop parked is taken back at once only by the person's own retry. Another agent's
/// `_acpmux/retry` (a watchdog's, a coordinator's) is refused with `retry.rate_limited` and the
/// time it may retry; before, it unparked the chat and resent the continuation into the limit.
#[tokio::test]
async fn an_agents_retry_does_not_unpark_a_parked_chat_and_the_persons_does() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = held_chat(&mut c, &hub, "parked-retry").await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    until(&hub, &id, |k| k.iter().any(|k| k == "rate_limit_parked")).await;
    let watchdog = new_session(&mut c, "watchdog").await;
    let mut agent = agent_in(&hub, &watchdog).await;

    let err = agent.request("_acpmux/retry", json!({"sessionId": id})).await.unwrap_err();
    assert!(err.contains("retry.rate_limited"), "{err}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(of_kind(&hub, &id, "rate_limit_unparked").is_empty(), "{:?}", kinds(&hub, &id));
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "{:?}", kinds(&hub, &id));
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row["rateLimitParked"].as_u64().is_some(), "still parked: {row}");

    // The person's own retry keeps today's behaviour: it sends the continuation on at once.
    c.request("_acpmux/retry", json!({"sessionId": id})).await.unwrap();
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 2).await;
    assert_eq!(of_kind(&hub, &id, "rate_limit_unparked").len(), 1, "{k:?}");
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 2, "{k:?}");
}

/// A sub-session whose continuation after a 429 was stopped is parked. Its parent agent's
/// resume of the stopped turn (`_acpmux/retry`, `subsession_resume.rs`) honours the park: it is
/// refused, and no turn starts. Before, its `auto_resume` provenance went past the hold and the
/// resume never read it, so a stopped sub-session resumed straight into the limit.
#[tokio::test]
async fn a_parent_agents_resume_of_a_stopped_sub_session_honours_the_park() {
    let env = BTreeMap::from([(
        "FAKE_UNTIL_CANCEL_IN".to_owned(),
        "Your previous turn was cut off".to_owned(),
    )]);
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let parent = new_session(&mut c, "parent").await;
    let mut agent = agent_in(&hub, &parent).await;
    let started = agent
        .request(
            "_acpmux/subsession/start",
            json!({"prompt": format!("recover-once: {LIMIT}; Retry-After: 1")}),
        )
        .await
        .unwrap();
    let child = started["sessionId"].as_str().unwrap().to_owned();
    // The 429 holds it; at the reset its continuation runs, and is stopped while it runs.
    until(&hub, &child, |k| k.iter().filter(|k| *k == "turn_started").count() >= 2).await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": child})).await.unwrap();
    let k = until(&hub, &child, |k| {
        k.iter().any(|k| k == "rate_limit_parked")
            && k.iter().filter(|k| *k == "turn_result").count() >= 2
    })
    .await;
    let row = hub.session_summary(&hub.resolve(&child).unwrap());
    assert_eq!(row["lastTurn"]["status"], "cancelled", "{row} {k:?}");
    assert!(row["rateLimitParked"].as_u64().is_some(), "{row} {k:?}");

    let err = agent.request("_acpmux/retry", json!({"sessionId": child})).await.unwrap_err();
    assert!(err.contains("retry.rate_limited"), "{err}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(of_kind(&hub, &child, "turn_started").len(), 2, "{:?}", kinds(&hub, &child));
    assert!(of_kind(&hub, &child, "rate_limit_unparked").is_empty(), "{:?}", kinds(&hub, &child));

    // The person's own Resume still continues it.
    let resumed = c.request("_acpmux/retry", json!({"sessionId": child})).await.unwrap();
    assert!(
        resumed["promptId"].as_str().is_some_and(|p| p.starts_with("stopped-resume-")),
        "{resumed}"
    );
    assert_eq!(of_kind(&hub, &child, "turn_started").len(), 3, "{:?}", kinds(&hub, &child));
}

/// Leo, 2026-11-24: "i wonder what will happen with claudes on vms... do they get stranded!? ...
/// is our logistics for being able to durably wake them up good?" A chat waiting out a capacity
/// outage (the pool's 503, its retry-after 2 s) when the daemon restarts: the next daemon
/// restores the wait from the log and continues it exactly once, at its deadline, under the
/// same `~resume-1` id; the old daemon's timer sends nothing.
#[tokio::test]
async fn a_capacity_wait_cut_by_a_daemon_restart_resumes_once_at_its_deadline() {
    let dir = temp_dir("capacity");
    let (hub, mut c) = daemon_on_disk(&dir).await;
    let id = new_session(&mut c, "paused").await;
    let pool = "API Error: 503 no non-exhausted claude accounts available; next account frees up in 1m (retry after 2s).";
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({
                "sessionId": id,
                "prompt": [{"type": "text", "text": format!("recover-once: {pool}")}],
                "_meta": {"acpmux": {"promptId": "p-pool"}}
            }),
        )
        .await;
    assert!(r.is_err());
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    let scheduled = of_kind(&hub, &id, "auto_resume_scheduled")[0].msg.clone();
    assert_eq!(scheduled["reason"], "capacity", "{scheduled}");
    let next_at = scheduled["nextAt"].as_u64().unwrap();
    // The pool's retry-after is honoured: no attempt before it.
    assert!(next_at >= of_kind(&hub, &id, "turn_result")[0].at + 1_900, "{scheduled}");

    let (hub, _c) = restarted(hub, c, &dir, &id).await;
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(row["retry"]["reason"], "capacity", "the restored wait shows: {row}");
    assert_eq!(row["retry"]["nextAt"], next_at, "{row}");
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 2).await;
    tokio::time::sleep(Duration::from_millis(800)).await;
    let messages = user_messages(&hub, &id);
    let started = of_kind(&hub, &id, "turn_started");
    let after = hub.session_summary(&hub.resolve(&id).unwrap());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    let ids: Vec<&Value> = messages.iter().map(|m| &m["promptId"]).collect();
    assert_eq!(ids, [&json!("p-pool"), &json!("p-pool~resume-1")], "{k:?}");
    assert!(started[1].at >= next_at, "fired before its deadline: {k:?}");
    assert_eq!(after["lastTurn"]["status"], "completed", "{after}");
    assert_eq!(after["retry"], Value::Null, "{after}");
}
