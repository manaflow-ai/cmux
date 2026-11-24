//! A 429 storm on a long-context chat (cmuxterm-hq `docs/handbook/rate-limit-spiral-resends-the-context.md`,
//! the class's missing acpmux test). Leo, 2026-11-18: "claude-sr2-coord fell into a weird "rate
//! limited" loop again 429 and whatever". A coordinator whose account answers every request with
//! 429 keeps getting messages from other agents; every turn it starts re-sends its whole context
//! into a limit that is already refusing.
//!
//! The model here answers every prompt 429 (`FAKE_RATE_LIMIT_FILE`), naming no reset, while another
//! agent sends the chat a message every [`TICK_MS`] for [`STORM_MS`]. The backoff is the configured
//! [`DELAYS_MS`], scaled down from the minutes a real chat waits. What must hold:
//! - the chat does not send a turn (its whole context) per message or per retry: the requests the
//!   model gets stay at the hold's rate;
//! - the waits between those requests grow, and stay under the longest configured wait;
//! - no message is lost: once the limit lifts, every one goes in with a turn that completes;
//! - the row says why the chat is not answering: rate-limited, until when.
use super::*;

/// The backoff, scaled: what `autoResumeDelaysMs` is for this chat.
const DELAYS_MS: [u64; 4] = [200, 400, 800, 1600];
/// How long the other agents keep messaging the rate-limited chat.
const STORM_MS: u64 = 3_000;
/// One message from another agent this often.
const TICK_MS: u64 = 50;
/// A chat held per session sends at most this many turns in the storm: the turn that hit the
/// limit, then one per hold (200, 400, 800, 1600 ms: the fourth may fall past the storm's end).
const MAX_REQUESTS: usize = 1 + DELAYS_MS.len();

fn events(hub: &Hub, id: &str) -> Vec<acpmux::store::EventRecord> {
    hub.events(id, 0, 100_000).unwrap()
}

fn of_kind(hub: &Hub, id: &str, kind: &str) -> Vec<acpmux::store::EventRecord> {
    events(hub, id).into_iter().filter(|e| e.kind == kind).collect()
}

fn from_agent(id: &str, prompt_id: &str, agent: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": agent}}})
}

/// The `session/prompt` requests that reached the agent: each one is a model request that
/// carries the chat's whole context.
fn model_requests(wire: &std::path::Path) -> usize {
    std::fs::read_to_string(wire)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|l| l["method"] == method::SESSION_PROMPT)
        .count()
}

/// The answers the client has read so far, errors only: `(request id, message)`.
fn drain_errors(c: &mut TestClient, errors: &mut Vec<(Value, String)>) {
    while let Ok(line) = c.rx.try_recv() {
        if let Ok(Message::Response { id, error: Some(e), .. }) = Message::parse(&line) {
            errors.push((id, e.message));
        }
    }
}

/// The texts of the turns that completed: every `user_message` of a turn whose result is
/// `completed`.
fn completed_texts(hub: &Hub, id: &str) -> String {
    let all = events(hub, id);
    let completed: Vec<&Value> = all
        .iter()
        .filter(|e| e.kind == "turn_result" && e.msg["status"] == "completed")
        .map(|e| &e.msg["turnId"])
        .collect();
    all.iter()
        .filter(|e| e.kind == "user_message" && completed.contains(&&e.msg["turnId"]))
        .map(|e| e.msg.to_string())
        .collect::<Vec<_>>()
        .join("\n")
}

#[tokio::test]
async fn a_429_storm_holds_the_chat_backs_off_and_loses_no_message() {
    let root = std::env::temp_dir().join(format!("acpmux-429-storm-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let (limit, wire) = (root.join("rate-limited"), root.join("wire.ndjson"));
    std::fs::write(&limit, "").unwrap();
    let env = BTreeMap::from([
        ("FAKE_RATE_LIMIT_FILE".to_owned(), limit.to_string_lossy().into_owned()),
        ("FAKE_WIRE_LOG".to_owned(), wire.to_string_lossy().into_owned()),
    ]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    hub.config.write().await.auto_resume_delays_ms = Some(DELAYS_MS.to_vec());
    let id = new_session(&mut c, "coord-429").await;

    // The coordinator's own turn hits the account's limit.
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({
                "sessionId": id, "prompt": [{"type": "text", "text": "plan the day"}],
                "_meta": {"acpmux": {"promptId": "p-coord"}}
            }),
        )
        .await;
    assert!(r.unwrap_err().contains("429"));
    let before = model_requests(&wire);
    assert_eq!(before, 1, "the first turn reached the model once");

    // Other agents keep reporting to it.
    let mut errors = Vec::new();
    let mut sent = Vec::new();
    let mut reason_seen = false;
    let start = tokio::time::Instant::now();
    let mut n = 0;
    while start.elapsed() < Duration::from_millis(STORM_MS) {
        let text = format!("report {n} from lane-{}", n % 7);
        let rid = c
            .send(
                method::SESSION_PROMPT,
                from_agent(&id, &format!("m-{n}"), &format!("lane-{}", n % 7), &text),
            )
            .await;
        sent.push((rid, text));
        n += 1;
        drain_errors(&mut c, &mut errors);
        // The person sees a stated reason: the row says the chat is rate-limited, and until when.
        let row = hub.session_summary(&hub.resolve(&id).unwrap());
        if row["rateLimitedUntil"].as_u64().is_some_and(|u| u > acpmux::store::now_ms())
            && row["lastTurn"].to_string().contains("429")
        {
            reason_seen = true;
        }
        tokio::time::sleep(Duration::from_millis(TICK_MS)).await;
    }
    drain_errors(&mut c, &mut errors);
    let in_storm = model_requests(&wire);
    let starts: Vec<u64> = of_kind(&hub, &id, "turn_started").iter().map(|e| e.at).collect();
    let gaps: Vec<u64> = starts.windows(2).map(|w| w[1].saturating_sub(w[0])).collect();
    let row = hub.session_summary(&hub.resolve(&id).unwrap());

    // 1. No turn per message, no turn per retry: the requests stay at the hold's rate.
    assert!(
        in_storm <= MAX_REQUESTS,
        "{n} messages in {STORM_MS} ms sent {in_storm} model requests (each a full-context \
         resend), more than the {MAX_REQUESTS} a session-wide hold allows; turn starts {starts:?}, \
         gaps {gaps:?} ms"
    );

    // 2. The waits between requests grow (each about twice the one before, until the longest
    // configured wait), and none is longer than that wait.
    let cap = DELAYS_MS[DELAYS_MS.len() - 1];
    for w in gaps.windows(2) {
        assert!(
            w[0] >= cap || w[1] * 2 >= w[0] * 3,
            "the backoff did not grow across the session: gaps {gaps:?} ms (configured {DELAYS_MS:?})"
        );
    }
    let bound = cap + cap / 5 + 500;
    assert!(gaps.iter().all(|g| *g <= bound), "a wait past the bound {bound} ms: {gaps:?}");

    // 3. The person sees why.
    assert!(reason_seen, "the row never said the chat was rate-limited: {row}");

    // 4. The limit lifts: the chat goes on within the bound, and no message is lost.
    std::fs::remove_file(&limit).unwrap();
    let lifted = tokio::time::Instant::now();
    let mut missing: Vec<String> = Vec::new();
    while lifted.elapsed() < Duration::from_millis(bound + 10_000) {
        drain_errors(&mut c, &mut errors);
        let done = completed_texts(&hub, &id);
        missing = sent
            .iter()
            .filter(|(_, t)| !done.contains(t.as_str()))
            .map(|(_, t)| t.clone())
            .collect();
        if missing.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let first_ok = of_kind(&hub, &id, "turn_result")
        .into_iter()
        .find(|e| e.msg["status"] == "completed")
        .map(|e| e.at);
    assert!(first_ok.is_some(), "no turn completed after the limit lifted: {:?}", kinds(&hub, &id));
    assert!(
        missing.is_empty(),
        "{} of {n} messages never went in with a completed turn, first {:?}; errors answered: {:?}",
        missing.len(),
        missing.first(),
        errors.iter().take(5).collect::<Vec<_>>()
    );
    // A refusal at admission (a full queue, a withdrawal) would be a lost message too: the only
    // errors any message was answered with are the limit's.
    let sent_ids: Vec<Value> = sent.iter().map(|(rid, _)| json!(rid)).collect();
    let refused: Vec<&(Value, String)> =
        errors.iter().filter(|(rid, e)| sent_ids.contains(rid) && !e.contains("429")).collect();
    assert!(refused.is_empty(), "messages refused, not held: {refused:?}");

    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// One agent message, alone, leads a turn the limit refuses before its model reads a word: it
/// goes back under its own prompt id (`digest.rs` `requeue_unread`) with nothing queued behind it
/// to fold it into another turn. Its prompt id is still in the chat's prompt ledger with the
/// refused turn's outcome, so the copy must not answer as that prompt's duplicate and leave the
/// queue: once the limit lifts it goes in with a turn that completes.
#[tokio::test]
async fn a_lone_agent_message_a_429_refused_goes_in_once_the_limit_lifts() {
    let root = std::env::temp_dir().join(format!("acpmux-429-lone-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let (limit, wire) = (root.join("rate-limited"), root.join("wire.ndjson"));
    std::fs::write(&limit, "").unwrap();
    let env = BTreeMap::from([
        ("FAKE_RATE_LIMIT_FILE".to_owned(), limit.to_string_lossy().into_owned()),
        ("FAKE_WIRE_LOG".to_owned(), wire.to_string_lossy().into_owned()),
    ]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    hub.config.write().await.auto_resume_delays_ms = Some(DELAYS_MS.to_vec());
    let id = new_session(&mut c, "coord-429-lone").await;

    let text = "the only report from lane-1";
    let r = c.request(method::SESSION_PROMPT, from_agent(&id, "m-lone", "lane-1", text)).await;
    assert!(r.unwrap_err().contains("429"), "the limit refused the message's turn");
    assert_eq!(model_requests(&wire), 1, "the refused turn reached the model once");

    std::fs::remove_file(&limit).unwrap();
    let lifted = tokio::time::Instant::now();
    let bound = DELAYS_MS[DELAYS_MS.len() - 1] * 2 + 10_000;
    while lifted.elapsed() < Duration::from_millis(bound)
        && !completed_texts(&hub, &id).contains(text)
    {
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        completed_texts(&hub, &id).contains(text),
        "the refused agent message never went in with a completed turn; events {:?}",
        kinds(&hub, &id)
    );

    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
