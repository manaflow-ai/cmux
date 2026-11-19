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
//! - no message is lost: once the limit lifts, every one is in a conversation that went on (a
//!   turn that completes, or a cut turn a completed turn came after);
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

/// The texts the agent has in a conversation that went on: every `user_message` of a turn that
/// completed, or of a turn the 429 cut that a completed turn came after. The cut turn's prompt
/// reached the agent and stays in its conversation; its continuation, or the queued turn that
/// took the continuation's place, goes on from there and does not send it again (#47337
/// counted the same on real Claude Code: 280 of 280 reached the model, none twice).
fn completed_texts(hub: &Hub, id: &str) -> String {
    let all = events(hub, id);
    let last_completed =
        all.iter().rposition(|e| e.kind == "turn_result" && e.msg["status"] == "completed");
    let went_on: Vec<&Value> = all
        .iter()
        .enumerate()
        .filter(|(i, e)| {
            e.kind == "turn_result"
                && (e.msg["status"] == "completed" || last_completed.is_some_and(|l| *i < l))
        })
        .map(|(_, e)| &e.msg["turnId"])
        .collect();
    all.iter()
        .filter(|e| e.kind == "user_message" && went_on.contains(&&e.msg["turnId"]))
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

/// The backoff is the session's, not the turn's (the 2026-11-19 NIGHTLY storm, cmux#47337). The
/// first turn hits the limit and is held; a message from another agent queues; at the reset it
/// takes the continuation's place (`folded`) and hits the limit again. That second hold must not
/// start over at the first step, and no hold's deadline may move earlier: #45977's continuation
/// moved the failure's deadline to its own first step, and every folded turn began the waits
/// again, so a coordinator under a 429 sent more full-context requests than before the hold.
#[tokio::test]
async fn a_folded_turn_that_hits_the_limit_again_holds_longer_not_from_the_first_step() {
    const WAITS: [u64; 3] = [300, 900, 2_700];
    let root = std::env::temp_dir().join(format!("acpmux-429-fold-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let limit = root.join("rate-limited");
    std::fs::write(&limit, "").unwrap();
    let env =
        BTreeMap::from([("FAKE_RATE_LIMIT_FILE".to_owned(), limit.to_string_lossy().into_owned())]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    hub.config.write().await.auto_resume_delays_ms = Some(WAITS.to_vec());
    let id = new_session(&mut c, "coord-fold").await;
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
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-0", "lane-0", "report 0")).await;

    // The message's turn takes the continuation's place and fails on the limit too.
    let k = until(&hub, &id, |k| {
        k.iter().filter(|k| *k == "turn_result").count() >= 2
            && k.iter().filter(|k| *k == "rate_limit_held").count() >= 2
    })
    .await;
    // Let the second failure's continuation set its own wait.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let results: Vec<u64> = of_kind(&hub, &id, "turn_result").iter().map(|e| e.at).collect();
    assert!(results.len() >= 2, "{k:?}");
    let skipped = of_kind(&hub, &id, "auto_resume_skipped");
    assert!(skipped.iter().any(|e| e.msg["skipped"] == "folded"), "no fold: {k:?}");

    // Every deadline each failure's hold took, in order: none moves earlier than the one before.
    let held = of_kind(&hub, &id, "rate_limit_held");
    let hold_of = |i: usize| -> Vec<u64> {
        let next = results.get(i + 1).copied().unwrap_or(u64::MAX);
        held.iter()
            .filter(|e| e.at >= results[i] && e.at < next)
            .map(|e| e.msg["until"].as_u64().unwrap())
            .collect()
    };
    let (first, second) = (hold_of(0), hold_of(1));
    for deadlines in [&first, &second] {
        assert!(
            deadlines.windows(2).all(|w| w[1] >= w[0]),
            "a hold's deadline moved earlier: {deadlines:?} (failures at {results:?})"
        );
    }
    let length = |deadlines: &[u64], i: usize| deadlines.last().unwrap() - results[i];
    let (a, b) = (length(&first, 0), length(&second, 1));
    eprintln!(
        "429 fold: first hold {a} ms {first:?}, second hold {b} ms {second:?}, waits {WAITS:?}"
    );
    // The second 429 in a row waits the second step: three times the first, less the stagger.
    assert!(
        b * 2 >= a * 3,
        "the folded turn's hold started the backoff over: first {a} ms, second {b} ms \
         (configured {WAITS:?}; deadlines {first:?} then {second:?})"
    );
    let cap = WAITS[WAITS.len() - 1];
    assert!(b <= cap + cap / 5 + 100, "a hold past the longest wait: {b} ms");

    // The limit lifts: the report goes in with a completed turn.
    std::fs::remove_file(&limit).unwrap();
    let k = until(&hub, &id, |_| completed_texts(&hub, &id).contains("report 0")).await;
    assert!(completed_texts(&hub, &id).contains("report 0"), "the report was lost: {k:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A 429 that outlasts every configured wait (gui-429-finish's live storm, 2026-11-19: turns that
/// fail in about a second each spent one step of the ladder, the fourth landed about 20 minutes
/// in, and then the ladder was used up, so 279 of 280 queued messages still sat there 20 minutes
/// after the limit lifted). While the 429 lasts the chat keeps probing at the longest wait, never
/// giving up; at the first success every message goes in, within one wait of the lift.
#[tokio::test]
async fn a_429_that_outlasts_the_waits_keeps_probing_and_delivers_soon_after_the_lift() {
    const WAITS: [u64; 2] = [100, 250];
    let root = std::env::temp_dir().join(format!("acpmux-429-long-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let limit = root.join("rate-limited");
    std::fs::write(&limit, "").unwrap();
    let env =
        BTreeMap::from([("FAKE_RATE_LIMIT_FILE".to_owned(), limit.to_string_lossy().into_owned())]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), false).await;
    hub.config.write().await.auto_resume_delays_ms = Some(WAITS.to_vec());
    let id = new_session(&mut c, "coord-long").await;
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
    // Agents report while the first hold lasts; their turn takes the continuation's place.
    for n in 0..5 {
        let text = format!("report {n} from lane-{n}");
        c.send(
            method::SESSION_PROMPT,
            from_agent(&id, &format!("m-{n}"), &format!("lane-{n}"), &text),
        )
        .await;
    }
    // The limit lasts ten times the longest wait: far past the two configured attempts.
    tokio::time::sleep(Duration::from_millis(WAITS[1] * 10)).await;
    let k = kinds(&hub, &id);
    assert!(
        !k.iter().any(|k| k == "auto_resume_exhausted"),
        "the chat gave up while the 429 lasted: {k:?}"
    );
    let starts = of_kind(&hub, &id, "turn_started").len();
    assert!(starts >= 4, "it stopped probing: {starts} turns in {} ms: {k:?}", WAITS[1] * 10);
    let cap = WAITS[WAITS.len() - 1];
    let bound = cap + cap / 5 + 100;
    let at: Vec<u64> = of_kind(&hub, &id, "turn_started").iter().map(|e| e.at).collect();
    let gaps: Vec<u64> = at.windows(2).map(|w| w[1] - w[0]).collect();
    assert!(gaps.iter().all(|g| *g <= bound), "a probe past the longest wait {bound} ms: {gaps:?}");

    // The limit lifts: every report is in a conversation that went on, within one wait.
    std::fs::remove_file(&limit).unwrap();
    let lifted = tokio::time::Instant::now();
    let all = |hub: &Hub| {
        let done = completed_texts(hub, &id);
        (0..5).all(|n| done.contains(&format!("report {n} from lane-{n}")))
    };
    while !all(&hub) && lifted.elapsed() < Duration::from_millis(bound + 2_000) {
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let took = lifted.elapsed().as_millis();
    eprintln!(
        "429 long: {starts} turns while held, gaps {gaps:?} ms, delivered {took} ms after the lift"
    );
    assert!(all(&hub), "reports not delivered {took} ms after the lift: {:?}", kinds(&hub, &id));
    assert!(
        took <= u128::from(bound + 1_000),
        "delivered {took} ms after the lift (bound {bound})"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// One model request per probe (gui-429-finish's live storm, 2026-11-19, 13:44:45: each 60 s
/// probe sent two full-context bodies, 72648 B then 76365 B). A probe turn takes about a second to
/// fail (Claude Code's own retries), and the other agents' notice steered into it meanwhile, a
/// second request into the same limit. While the chat is in a 429 streak no notice steers into
/// its turn: what comes in waits for the next probe, or goes in after the one that succeeds.
#[tokio::test]
async fn a_probe_under_a_429_is_one_model_request_with_no_steer_into_it() {
    const WAITS: [u64; 1] = [400];
    let root = std::env::temp_dir().join(format!("acpmux-429-probe-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let (limit, wire) = (root.join("rate-limited"), root.join("wire.ndjson"));
    std::fs::write(&limit, "").unwrap();
    let env = BTreeMap::from([
        ("FAKE_RATE_LIMIT_FILE".to_owned(), limit.to_string_lossy().into_owned()),
        ("FAKE_RATE_LIMIT_DELAY_MS".to_owned(), "300".to_owned()),
        ("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned()),
        ("FAKE_WIRE_LOG".to_owned(), wire.to_string_lossy().into_owned()),
    ]);
    let (hub, mut c) = setup_inbox(PermissionPolicy::ApproveAll, env, BTreeMap::new(), true).await;
    hub.config.write().await.auto_resume_delays_ms = Some(WAITS.to_vec());
    let id = new_session(&mut c, "coord-probe").await;
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
    // Other agents report every 50 ms for 3 s: some land while a probe runs.
    for n in 0..60 {
        let text = format!("report {n} from lane-{}", n % 7);
        c.send(
            method::SESSION_PROMPT,
            from_agent(&id, &format!("m-{n}"), &format!("lane-{}", n % 7), &text),
        )
        .await;
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let starts = of_kind(&hub, &id, "turn_started").len();
    let requests = model_requests(&wire);
    eprintln!("429 probe: {starts} turns, {requests} model requests while held");
    assert!(starts >= 3, "too few probes to judge: {:?}", kinds(&hub, &id));
    assert_eq!(
        requests,
        starts,
        "a probe sent more than one model request (a notice steered into it): {:?}",
        kinds(&hub, &id)
    );

    // The limit lifts: every report goes in.
    std::fs::remove_file(&limit).unwrap();
    let k = until(&hub, &id, |_| {
        let done = completed_texts(&hub, &id);
        (0..60).all(|n| done.contains(&format!("report {n} from")))
    })
    .await;
    let done = completed_texts(&hub, &id);
    let missing: Vec<usize> =
        (0..60).filter(|n| !done.contains(&format!("report {n} from"))).collect();
    assert!(missing.is_empty(), "reports not delivered: {missing:?}: {k:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
