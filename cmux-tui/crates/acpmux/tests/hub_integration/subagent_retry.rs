//! A Claude subagent that failed on a transient upstream error is resumed in its chat
//! (`hub/subagent_retry.rs`). Leo, 2026-10-26: "this needs to retry :(" — two of his chat's
//! subagents ended "Subagent failed" on SR2's "503 no non-exhausted claude accounts available",
//! and nothing brought them back.
use super::*;

/// Every record of a session, oldest first.
fn records(hub: &Hub, id: &str) -> Vec<acpmux::store::EventRecord> {
    hub.events(id, 0, 10_000).unwrap()
}

/// The `subagent_retry` records' outcomes (`skipped:<why>` for a skip).
fn outcomes(hub: &Hub, id: &str) -> Vec<String> {
    records(hub, id)
        .into_iter()
        .filter(|e| e.kind == "subagent_retry")
        .map(|e| match e.msg["skipped"].as_str() {
            Some(why) => format!("skipped:{why}"),
            None => e.msg["outcome"].as_str().unwrap_or_default().to_owned(),
        })
        .collect()
}

fn user_messages(hub: &Hub, id: &str) -> Vec<Value> {
    records(hub, id).into_iter().filter(|e| e.kind == "user_message").map(|e| e.msg).collect()
}

/// Waits (up to 20 s) until `pred` holds for the session's retry outcomes.
async fn until(hub: &Hub, id: &str, pred: impl Fn(&[String]) -> bool) -> Vec<String> {
    for _ in 0..400 {
        let got = outcomes(hub, id);
        if pred(&got) {
            return got;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    outcomes(hub, id)
}

/// A Claude chat with `delays` as `autoResumeDelaysMs`, after its first turn ("agent-503" or
/// another) ended.
async fn chat(first: &str, delays: Vec<u64>) -> (Arc<Hub>, TestClient, String) {
    chat_env(first, delays, BTreeMap::new()).await
}

async fn chat_env(
    first: &str,
    delays: Vec<u64>,
    env: BTreeMap<String, String>,
) -> (Arc<Hub>, TestClient, String) {
    let (hub, mut c) = super::stop::claude_setup_env(env).await;
    hub.config.write().await.auto_resume_delays_ms = Some(delays);
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, first, Some("p-first"))).await.unwrap();
    (hub, c, id)
}

#[tokio::test]
async fn a_subagent_a_503_failed_is_resumed_in_its_chat() {
    let (hub, _c, id) = chat("agent-503", vec![50]).await;
    let got = until(&hub, &id, |o| o.iter().any(|o| o == "fired")).await;
    assert_eq!(got[..2], ["scheduled", "fired"], "{got:?}");
    // "fired" is logged just before its prompt.
    messages_until(&hub, &id, 2).await;
    // The chat's agent is told, in the same chat, to resume that agent by its id.
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    let retry = &messages[1];
    let provenance = &retry["_meta"]["provenance"];
    assert_eq!(provenance["kind"], "subagent_retry");
    assert_eq!(provenance["agentId"], "a503a503a503a503");
    assert_eq!(provenance["attempt"], 1);
    let subagent = provenance["subagentId"].as_str().unwrap();
    assert!(subagent.ends_with("/toolu_a503"), "{provenance}");
    let text = retry["text"].as_str().unwrap();
    assert!(text.contains("SendMessage to \"a503a503a503a503\""), "{text}");
    assert!(text.contains("\"Push relay\""), "{text}");
    assert!(text.contains("503 no non-exhausted"), "{text}");
    // While it waited, its subagent entry said so.
    let entries: Vec<Value> = records(&hub, &id)
        .into_iter()
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents/0").cloned())
        .filter(|e| e["id"] == subagent)
        .collect();
    let waiting = entries.iter().find(|e| e["retry"].is_object()).expect("a waiting entry");
    assert_eq!(waiting["state"], "failed");
    assert_eq!(waiting["retryable"], true);
    assert_eq!(waiting["retry"]["attempt"], 1);
    assert_eq!(waiting["retry"]["of"], 1);
    assert_eq!(waiting["retry"]["reason"], "capacity");
    assert!(waiting["retry"]["nextAt"].as_u64().unwrap() > 1_700_000_000_000, "{waiting}");
    // The resume runs that same subagent again, and nothing more is retried.
    for _ in 0..200 {
        if entries_of(&hub, &id, subagent).last().is_some_and(|e| e["state"] == "running") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let last = entries_of(&hub, &id, subagent).last().cloned().unwrap();
    assert_eq!(last["state"], "running", "{last}");
    assert_eq!(last["agentId"], "a503a503a503a503");
    // Running again, it is no longer retryable.
    let resumed = entries_of(&hub, &id, subagent);
    assert!(
        resumed.iter().any(|e| e["state"] == "running" && e["retryable"] == false),
        "{resumed:?}"
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(outcomes(&hub, &id), ["scheduled", "fired"]);
    assert_eq!(user_messages(&hub, &id).len(), 2);
}

/// Waits (up to 10 s) for the session's `n`th user message.
async fn messages_until(hub: &Hub, id: &str, n: usize) {
    for _ in 0..200 {
        if user_messages(hub, id).len() >= n {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn entries_of(hub: &Hub, id: &str, subagent: &str) -> Vec<Value> {
    records(hub, id)
        .into_iter()
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents/0").cloned())
        .filter(|e| e["id"] == subagent)
        .collect()
}

/// Claude Code runs a turn of its own for the failure's notification, which acpmux never
/// prompted: the retry waits for its end rather than land in it.
#[tokio::test]
async fn the_retry_waits_for_claudes_own_turn() {
    let gate = std::env::temp_dir().join(format!("acpmux-a503-{}", uuid::Uuid::now_v7()));
    let (hub, _c, id) = chat(&format!("agent-503-held: {}", gate.display()), vec![20]).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(outcomes(&hub, &id), ["scheduled"], "it fired into Claude Code's own turn");
    assert_eq!(user_messages(&hub, &id).len(), 1);
    std::fs::write(&gate, "").unwrap();
    let got = until(&hub, &id, |o| o.iter().any(|o| o == "fired")).await;
    let _ = std::fs::remove_file(&gate);
    assert_eq!(got[..2], ["scheduled", "fired"], "{got:?}");
    messages_until(&hub, &id, 2).await;
    assert_eq!(user_messages(&hub, &id)[1]["_meta"]["provenance"]["kind"], "subagent_retry");
}

/// Stop ends the wait, and the skipped retry never fires. The wait is a minute long, so the Stop
/// always lands in it whatever the machine's load; Stop wakes it, and a woken wait that fired
/// anyway would show within the 600 ms below.
#[tokio::test]
async fn stop_skips_the_wait() {
    let (hub, mut c, id) = chat("agent-503", vec![60_000]).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let got = until(&hub, &id, |o| o.len() >= 2).await;
    assert_eq!(got, ["scheduled", "skipped:stopped"]);
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert_eq!(outcomes(&hub, &id), ["scheduled", "skipped:stopped"]);
    assert_eq!(user_messages(&hub, &id).len(), 1);
    // A person can still retry it.
    let skipped = entries_of(&hub, &id, &retried(&hub, &id)).last().cloned().unwrap();
    assert_eq!(skipped["retryable"], true, "{skipped}");
}

/// A bad request would only fail again: it is never retried.
#[tokio::test]
async fn a_subagent_a_bad_request_failed_is_not_retried() {
    let (hub, _c, id) = chat("agent-400", vec![20]).await;
    // Its failure is logged, with why.
    for _ in 0..200 {
        if records(&hub, &id).iter().any(|e| {
            e.msg.pointer("/params/_meta/acpmux/subagents/0/error").is_some_and(|v| !v.is_null())
        }) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(outcomes(&hub, &id), Vec::<String>::new());
    assert_eq!(user_messages(&hub, &id).len(), 1);
}

/// The id of the subagent the session's first retry is for.
fn retried(hub: &Hub, id: &str) -> String {
    records(hub, id)
        .into_iter()
        .find(|e| e.kind == "subagent_retry")
        .and_then(|e| e.msg["subagentId"].as_str().map(str::to_owned))
        .unwrap()
}

/// A dropped connection is transient too.
#[tokio::test]
async fn a_subagent_a_dropped_connection_failed_is_resumed() {
    let (hub, _c, id) = chat("agent-reset", vec![20]).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "fired")).await;
    let scheduled = records(&hub, &id).into_iter().find(|e| e.kind == "subagent_retry").unwrap();
    assert_eq!(scheduled.msg["reason"], "transport", "{:?}", scheduled.msg);
}

/// A resume that fails on the 503 again waits for its next attempt, and after the configured
/// attempts it is given up.
#[tokio::test]
async fn a_subagent_that_keeps_failing_is_given_up_after_the_attempts() {
    let env = BTreeMap::from([("FAKE_CLAUDE_RESUME_FAILS".to_owned(), "1".to_owned())]);
    let (hub, _c, id) = chat_env("agent-503", vec![20, 20], env).await;
    let got = until(&hub, &id, |o| o.iter().any(|o| o == "exhausted")).await;
    assert_eq!(
        got,
        ["scheduled", "fired", "scheduled", "fired", "exhausted"],
        "two attempts, then given up"
    );
    messages_until(&hub, &id, 4).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 4, "the first prompt, two retries and the failure: {messages:?}");
    let attempts: Vec<Value> =
        messages[1..3].iter().map(|m| m["_meta"]["provenance"]["attempt"].clone()).collect();
    assert_eq!(attempts, [json!(1), json!(2)]);
    // Given up, the parent's agent is told so, typed: never a silent end.
    let told = &messages[3];
    let provenance = &told["_meta"]["provenance"];
    assert_eq!(provenance["kind"], "subagent_failed", "{told}");
    assert_eq!(provenance["agentId"], "a503a503a503a503");
    assert_eq!(provenance["attempts"], 2);
    assert_eq!(provenance["reason"], "capacity");
    let text = told["text"].as_str().unwrap();
    assert!(text.contains("failed for good") && text.contains("not done"), "{text}");
    assert!(text.contains("\"Push relay\""), "{text}");
    // The automatic attempts are over; a person's retry still works.
    let given_up = entries_of(&hub, &id, &retried(&hub, &id)).last().cloned().unwrap();
    assert_eq!(given_up["state"], "failed", "{given_up}");
    assert_eq!(given_up["retry"], Value::Null, "{given_up}");
    assert_eq!(given_up["retryable"], true, "{given_up}");
}

/// A person's turn runs when the retry fires: its prompt waits in the queue behind that turn
/// and runs after it, never steered into it. The subagent fails only once that turn runs (the
/// fake fails it when the test writes `late`), so the retry is due inside the turn whatever the
/// machine's load.
#[tokio::test]
async fn the_retry_queues_behind_a_running_turn() {
    let late = std::env::temp_dir().join(format!("acpmux-a503-late-{}", uuid::Uuid::now_v7()));
    let gate = std::env::temp_dir().join(format!("acpmux-a503-hold-{}", uuid::Uuid::now_v7()));
    let (hub, mut c, id) = chat(&format!("agent-503-late: {}", late.display()), vec![20]).await;
    let hold = c
        .send(
            method::SESSION_PROMPT,
            prompt(&id, &format!("hold: {}", gate.display()), Some("p-hold")),
        )
        .await;
    for _ in 0..400 {
        if hub.resolve(&id).unwrap().turn().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert!(hub.resolve(&id).unwrap().turn().is_some(), "the person's turn never started");
    assert_eq!(outcomes(&hub, &id), Vec::<String>::new(), "failed before the person's turn");
    std::fs::write(&late, "").unwrap();
    let got = until(&hub, &id, |o| o.iter().any(|o| o == "fired")).await;
    assert_eq!(got[..2], ["scheduled", "fired"], "{got:?}");
    // "fired" is logged just before its prompt goes in: the queue takes it.
    let queued_retry = |hub: &Hub| {
        records(hub, &id)
            .into_iter()
            .filter(|e| e.kind == "queued")
            .any(|e| e.msg["promptId"].as_str().is_some_and(|p| p.starts_with("subagent-retry-")))
    };
    for _ in 0..200 {
        if queued_retry(&hub) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let queued: Vec<Value> =
        records(&hub, &id).into_iter().filter(|e| e.kind == "queued").map(|e| e.msg).collect();
    assert!(queued_retry(&hub), "{queued:?}");
    assert!(hub.resolve(&id).unwrap().turn().is_some(), "the person's turn ended early");
    assert_eq!(user_messages(&hub, &id).len(), 2, "only the person's prompts ran so far");
    std::fs::write(&gate, "").unwrap();
    c.response(hold).await.0.unwrap();
    messages_until(&hub, &id, 3).await;
    let _ = std::fs::remove_file(&late);
    let _ = std::fs::remove_file(&gate);
    let messages = user_messages(&hub, &id);
    assert_eq!(messages[1]["promptId"], "p-hold");
    assert_eq!(messages[2]["_meta"]["provenance"]["kind"], "subagent_retry");
}

/// Closing the chat ends the wait.
#[tokio::test]
async fn close_skips_the_wait() {
    let (hub, _c, id) = chat("agent-503", vec![60_000]).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    let session = hub.resolve(&id).unwrap();
    hub.kill(&session, false).await.unwrap();
    let got = until(&hub, &id, |o| o.len() >= 2).await;
    assert_eq!(got, ["scheduled", "skipped:closed"]);
    // With its chat closed, nothing can retry it.
    let closed = entries_of(&hub, &id, &retried(&hub, &id)).last().cloned().unwrap();
    assert_eq!(closed["retryable"], false, "{closed}");
}

/// A resume the translator can no longer name (it forgot the agent after 64 other failures)
/// still ends the retry: Claude Code's raw `task_started` for its agent id says it runs again.
#[tokio::test]
async fn a_resume_of_a_forgotten_agent_ends_its_retry() {
    let env = BTreeMap::from([("FAKE_CLAUDE_FORGET_AGENTS".to_owned(), "1".to_owned())]);
    let (hub, _c, id) = chat_env("agent-503", vec![50], env).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "fired")).await;
    messages_until(&hub, &id, 2).await;
    let subagent = retried(&hub, &id);
    for _ in 0..200 {
        if entries_of(&hub, &id, &subagent).last().is_some_and(|e| e["state"] == "running") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // Only acpmux's own entry says it runs again: the translator forgot it.
    let last = entries_of(&hub, &id, &subagent).last().cloned().unwrap();
    assert_eq!((&last["state"], &last["retryable"]), (&json!("running"), &json!(false)), "{last}");
    // Its turn ended with nothing more to retry.
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(outcomes(&hub, &id), ["scheduled", "fired"]);
    assert_eq!(user_messages(&hub, &id).len(), 2);
}

/// The last entry of every subagent a retry was scheduled for.
fn last_entries(hub: &Hub, id: &str) -> Vec<Value> {
    let mut subs: Vec<String> = records(hub, id)
        .into_iter()
        .filter(|e| e.kind == "subagent_retry")
        .filter_map(|e| e.msg["subagentId"].as_str().map(str::to_owned))
        .collect();
    subs.sort();
    subs.dedup();
    subs.iter().filter_map(|s| entries_of(hub, id, s).last().cloned()).collect()
}

/// Closing a chat after a Stop, or after the attempts were used up, says no retry can work.
#[tokio::test]
async fn close_after_stop_or_giving_up_is_not_retryable() {
    let (hub, mut c, id) = chat("agent-503", vec![60_000]).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    until(&hub, &id, |o| o.len() >= 2).await;
    assert_eq!(last_entries(&hub, &id)[0]["retryable"], true);
    hub.kill(&hub.resolve(&id).unwrap(), false).await.unwrap();
    assert_eq!(last_entries(&hub, &id)[0]["retryable"], false, "stopped, then closed");

    let env = BTreeMap::from([("FAKE_CLAUDE_RESUME_FAILS".to_owned(), "1".to_owned())]);
    let (hub, _c, id) = chat_env("agent-503", vec![20], env).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "exhausted")).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(last_entries(&hub, &id)[0]["retryable"], true);
    hub.kill(&hub.resolve(&id).unwrap(), false).await.unwrap();
    assert_eq!(last_entries(&hub, &id)[0]["retryable"], false, "given up, then closed");
}

/// A chat keeps at most 32 failed subagents no retry waits for: past that, after a Stop or once
/// the attempts are used up, the oldest is forgotten and says it can't be retried.
#[tokio::test]
async fn failures_past_the_limit_are_forgotten_after_a_stop_or_giving_up() {
    let extra = || BTreeMap::from([("FAKE_CLAUDE_EXTRA_503".to_owned(), "32".to_owned())]);
    let forgotten = |hub: &Hub, id: &str| {
        last_entries(hub, id).iter().filter(|e| e["retryable"] == false).count()
    };
    // 33 waiting retries, then Stop.
    let (hub, mut c, id) = chat_env("agent-503", vec![60_000], extra()).await;
    let got = until(&hub, &id, |o| o.iter().filter(|o| *o == "scheduled").count() == 33).await;
    assert_eq!(got.len(), 33, "{got:?}");
    assert_eq!(forgotten(&hub, &id), 0);
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    until(&hub, &id, |o| o.len() >= 66).await;
    assert_eq!(forgotten(&hub, &id), 1, "stopped");
    // No automatic attempts: each is given up at once.
    let (hub, _c, id) = chat_env("agent-503", vec![], extra()).await;
    let got = until(&hub, &id, |o| o.len() >= 33).await;
    assert!(got.iter().all(|o| o == "exhausted"), "{got:?}");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(forgotten(&hub, &id), 1, "given up");
}

/// A forgotten agent (the translator no longer names it) that fails again after its resume is
/// retried again, and given up after the attempts, as a remembered one is.
#[tokio::test]
async fn a_forgotten_agent_that_keeps_failing_is_given_up_after_the_attempts() {
    let env = BTreeMap::from([
        ("FAKE_CLAUDE_FORGET_AGENTS".to_owned(), "1".to_owned()),
        ("FAKE_CLAUDE_RESUME_FAILS".to_owned(), "1".to_owned()),
    ]);
    let (hub, _c, id) = chat_env("agent-503", vec![20, 20], env).await;
    let got = until(&hub, &id, |o| o.iter().any(|o| o == "exhausted")).await;
    assert_eq!(got, ["scheduled", "fired", "scheduled", "fired", "exhausted"]);
    let last = entries_of(&hub, &id, &retried(&hub, &id)).last().cloned().unwrap();
    assert_eq!((&last["state"], &last["retryable"]), (&json!("failed"), &json!(true)), "{last}");
}

/// A forgotten agent that completes after its resume ends completed, and nothing more fires.
#[tokio::test]
async fn a_forgotten_agent_that_completes_after_its_resume_ends_completed() {
    let env = BTreeMap::from([
        ("FAKE_CLAUDE_FORGET_AGENTS".to_owned(), "1".to_owned()),
        ("FAKE_CLAUDE_RESUME_COMPLETES".to_owned(), "1".to_owned()),
    ]);
    let (hub, _c, id) = chat_env("agent-503", vec![50], env).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "fired")).await;
    let subagent = retried(&hub, &id);
    for _ in 0..200 {
        if entries_of(&hub, &id, &subagent).last().is_some_and(|e| e["state"] == "completed") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let last = entries_of(&hub, &id, &subagent).last().cloned().unwrap();
    assert_eq!(
        (&last["state"], &last["retryable"]),
        (&json!("completed"), &json!(false)),
        "{last}"
    );
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(outcomes(&hub, &id), ["scheduled", "fired"]);
}

const RETRY: &str = "_acpmux/retry";

/// Waits (up to 10 s) until the subagent's last entry is `state`.
async fn entry_until(hub: &Hub, id: &str, subagent: &str, state: &str) {
    for _ in 0..200 {
        if entries_of(hub, id, subagent).last().is_some_and(|e| e["state"] == state) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A person's retry (the Retry button, `acpmux retry --subagent`) of a subagent whose automatic
/// retries Stop ended: sent now, in the same chat, as the resume prompt the automatic retry sends,
/// marked manual. The subagent runs again; then there is nothing to retry.
#[tokio::test]
async fn a_person_retries_a_stopped_subagent_now() {
    let (hub, mut c, id) = chat("agent-503", vec![60_000]).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    until(&hub, &id, |o| o.len() >= 2).await;
    let subagent = retried(&hub, &id);
    let v = c.request(RETRY, json!({"sessionId": id, "subagentId": subagent})).await.unwrap();
    assert_eq!(v["kind"], "subagent", "{v}");
    let prompt_id = v["promptId"].as_str().unwrap().to_owned();
    assert!(prompt_id.starts_with("subagent-retry-"), "{v}");
    assert!(v["turnId"].is_string(), "{v}");
    assert_eq!(outcomes(&hub, &id), ["scheduled", "skipped:stopped", "fired"]);
    messages_until(&hub, &id, 2).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages[1]["promptId"], prompt_id.as_str());
    let provenance = &messages[1]["_meta"]["provenance"];
    assert_eq!(provenance["kind"], "subagent_retry", "{provenance}");
    assert_eq!(provenance["manual"], true, "{provenance}");
    assert_eq!(provenance["subagentId"], subagent.as_str(), "{provenance}");
    assert_eq!(provenance["agentId"], "a503a503a503a503", "{provenance}");
    assert_eq!(provenance["attempt"], 1, "{provenance}");
    let text = messages[1]["text"].as_str().unwrap();
    assert!(text.contains("SendMessage to \"a503a503a503a503\""), "{text}");
    // The same subagent runs again, and a second retry has nothing to retry.
    entry_until(&hub, &id, &subagent, "running").await;
    let e = c.request(RETRY, json!({"sessionId": id, "subagentId": subagent})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");
    assert!(e.contains("resumed"), "{e}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(outcomes(&hub, &id), ["scheduled", "skipped:stopped", "fired"]);
    assert_eq!(user_messages(&hub, &id).len(), 2);
}

/// A person's retry while the automatic one waits fires that one now: its prompt id and attempt,
/// once. The subagent may be named by its agent id, as `acpmux retry --subagent` takes it.
#[tokio::test]
async fn a_person_retry_fires_the_waiting_retry_now() {
    let (hub, mut c, id) = chat("agent-503", vec![60_000]).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    let scheduled = records(&hub, &id).into_iter().find(|e| e.kind == "subagent_retry").unwrap();
    let v =
        c.request(RETRY, json!({"sessionId": id, "subagentId": "a503a503a503a503"})).await.unwrap();
    assert_eq!(v["promptId"], scheduled.msg["promptId"], "{v}");
    assert_eq!(v["kind"], "subagent", "{v}");
    assert_eq!(outcomes(&hub, &id), ["scheduled", "fired"]);
    let fired = records(&hub, &id).into_iter().filter(|e| e.kind == "subagent_retry").nth(1);
    assert_eq!(fired.unwrap().msg["manual"], true);
    messages_until(&hub, &id, 2).await;
    let provenance = &user_messages(&hub, &id)[1]["_meta"]["provenance"];
    assert_eq!((&provenance["attempt"], &provenance["manual"]), (&json!(1), &json!(true)));
    entry_until(&hub, &id, &retried(&hub, &id), "running").await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(outcomes(&hub, &id), ["scheduled", "fired"], "the waiting retry fired once");
    assert_eq!(user_messages(&hub, &id).len(), 2);
}

/// What a person's subagent retry refuses: an id the chat has no subagent of, a turn that runs
/// (the waiting retry stays as it was), and a subagent whose failure would only fail again.
#[tokio::test]
async fn a_person_subagent_retry_is_refused_by_name() {
    let gate = std::env::temp_dir().join(format!("acpmux-a503-busy-{}", uuid::Uuid::now_v7()));
    let (hub, mut c, id) = chat("agent-503", vec![60_000]).await;
    until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    let e = c.request(RETRY, json!({"sessionId": id, "subagentId": "nope"})).await.unwrap_err();
    assert!(e.starts_with("retry.unknown_subagent"), "{e}");
    let hold = c
        .send(
            method::SESSION_PROMPT,
            prompt(&id, &format!("hold: {}", gate.display()), Some("p-hold")),
        )
        .await;
    for _ in 0..200 {
        if hub.resolve(&id).unwrap().turn().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let subagent = retried(&hub, &id);
    let e = c.request(RETRY, json!({"sessionId": id, "subagentId": subagent})).await.unwrap_err();
    assert!(e.starts_with("retry.busy"), "{e}");
    assert_eq!(outcomes(&hub, &id), ["scheduled"]);
    std::fs::write(&gate, "").unwrap();
    c.response(hold).await.0.unwrap();
    let _ = std::fs::remove_file(&gate);

    let (hub, mut c, id) = chat("agent-400", vec![20]).await;
    let mut failed = None;
    for _ in 0..200 {
        failed = records(&hub, &id).into_iter().find_map(|e| {
            let entry = e.msg.pointer("/params/_meta/acpmux/subagents/0")?.clone();
            (entry["state"] == "failed").then(|| entry["id"].as_str().unwrap().to_owned())
        });
        if failed.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let subagent = failed.expect("the bad request's failed subagent");
    let e = c.request(RETRY, json!({"sessionId": id, "subagentId": subagent})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");
    assert!(e.contains("not_retryable"), "{e}");
}

/// A Claude chat whose log lives in `dir`, as a daemon's does: a second hub on it is the
/// daemon after a restart.
fn durable(dir: &std::path::Path, env: BTreeMap<String, String>, delays: Vec<u64>) -> Arc<Hub> {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("claude".to_owned(), profile)]),
        default_harness: Some("claude".into()),
        auto_resume_delays_ms: Some(delays),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    let hub = Hub::new(cfg, store);
    hold_person_key(&hub);
    hub
}

async fn connect_to(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.become_person().await;
    c
}

/// Restarts the daemon on `dir`: its chat `id` read again and its queues resumed.
async fn restarted(
    dir: &std::path::Path,
    env: BTreeMap<String, String>,
    delays: Vec<u64>,
    id: &str,
) -> (Arc<Hub>, TestClient) {
    let hub = durable(dir, env, delays);
    let c = connect_to(&hub).await;
    hub.resume_queues();
    hub.session_summary(&hub.resolve(id).unwrap());
    (hub, c)
}

/// The restart's own `subagent_retry` outcomes: those after the last `rearmed`.
fn since_rearmed(got: &[String]) -> Vec<String> {
    let from = got.iter().rposition(|o| o == "rearmed").map_or(got.len(), |i| i + 1);
    got[from..].to_vec()
}

/// A daemon restart while a subagent's retry waits re-arms it: the restarted daemon logs it
/// re-armed and fires the attempt, rather than settle it `retryable: false` and lose it (8 of
/// 26 top-level helpers that failed on a 503 on one lane VM, 2026-11-24).
#[tokio::test]
async fn a_restart_while_a_retry_waits_rearms_it() {
    let dir = std::env::temp_dir().join(format!("acpmux-rearm-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir, BTreeMap::new(), vec![60_000]);
    let mut c = connect_to(&hub).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "agent-503", Some("p-first"))).await.unwrap();
    let got = until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    assert_eq!(got, ["scheduled"]);
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let (hub, _c) = restarted(&dir, BTreeMap::new(), vec![50], &id).await;
    let got = until(&hub, &id, |o| since_rearmed(o).iter().any(|o| o == "fired")).await;
    let after = since_rearmed(&got);
    assert!(got.iter().any(|o| o == "rearmed"), "{got:?}");
    assert_eq!(after, ["scheduled", "fired"], "{got:?}");
    let subagent = retried(&hub, &id);
    let rearmed: Vec<Value> =
        entries_of(&hub, &id, &subagent).into_iter().filter(|e| e["rearmed"] == true).collect();
    assert_eq!(rearmed.len(), 1, "{rearmed:?}");
    assert_eq!(rearmed[0]["retryable"], true);
    // The attempt goes in, and the subagent runs again.
    messages_until(&hub, &id, 2).await;
    let messages = user_messages(&hub, &id);
    let retry = messages.last().unwrap();
    assert_eq!(retry["_meta"]["provenance"]["kind"], "subagent_retry", "{retry}");
    assert_eq!(retry["_meta"]["provenance"]["attempt"], 1, "{retry}");
    entry_until(&hub, &id, &subagent, "running").await;
    hub.shutdown_all().await;
    drop(hub);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Duress: a subagent that fails on every resume, with a daemon restart after each attempt is
/// scheduled. Each restart re-arms it with the attempts its log counted, so the configured
/// attempts run and then the parent is told: no restart loses it, and no restart resets its
/// budget.
#[tokio::test]
async fn restarts_after_every_failure_neither_lose_a_subagent_nor_reset_its_attempts() {
    let faults: usize =
        std::env::var("DURESS_FAULTS").ok().and_then(|n| n.parse().ok()).unwrap_or(3);
    let dir = std::env::temp_dir().join(format!("acpmux-duress-{}", uuid::Uuid::now_v7()));
    let env = || BTreeMap::from([("FAKE_CLAUDE_RESUME_FAILS".to_owned(), "1".to_owned())]);
    // The daemon that restarts `k` times waits 30 ms for attempt `k` (the one it re-armed) and
    // a minute for every other: each next attempt is cut off by the next restart.
    let delays = |k: usize| (0..faults).map(|i| if i + 1 == k { 30 } else { 60_000 }).collect();
    let hub = durable(&dir, env(), delays(0));
    let mut c = connect_to(&hub).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "agent-503", Some("p-first"))).await.unwrap();
    until(&hub, &id, |o| o.iter().any(|o| o == "scheduled")).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let mut restarts = 1;
    loop {
        let (hub, c) = restarted(&dir, env(), delays(restarts), &id).await;
        // This daemon fires the re-armed attempt; its failure schedules the next, or gives up.
        let got = until(&hub, &id, |o| {
            let after = since_rearmed(o);
            after.iter().any(|o| o == "exhausted")
                || after.iter().filter(|o| *o == "scheduled").count() >= 2
        })
        .await;
        let after = since_rearmed(&got);
        if after.iter().any(|o| o == "exhausted") {
            let fired = got.iter().filter(|o| *o == "fired").count();
            assert_eq!(fired, faults, "each attempt once across {restarts} restarts: {got:?}");
            messages_until(&hub, &id, faults + 2).await;
            let told = user_messages(&hub, &id).pop().unwrap();
            assert_eq!(told["_meta"]["provenance"]["kind"], "subagent_failed", "{told}");
            assert_eq!(told["_meta"]["provenance"]["attempts"], faults, "{told}");
            hub.shutdown_all().await;
            break;
        }
        assert!(restarts <= faults, "more restarts than attempts: {got:?}");
        // The next attempt waits: cut it off with another restart, its wait long.
        hub.shutdown_all().await;
        drop(c);
        drop(hub);
        restarts += 1;
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// Duress, many at once: `DURESS_FAULTS` chats (default 8) each lose a subagent to an injected
/// 503, and the daemon restarts while every retry waits. Counts the subagents the restarted
/// daemon resumes (its attempt fires) and those it loses; prints `DURESS lost L of N`.
#[tokio::test]
async fn a_restart_during_many_waiting_retries_loses_none() {
    let n: usize = std::env::var("DURESS_FAULTS").ok().and_then(|n| n.parse().ok()).unwrap_or(8);
    let dir = std::env::temp_dir().join(format!("acpmux-duress-n-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir, BTreeMap::new(), vec![60_000]);
    let mut c = connect_to(&hub).await;
    let mut ids = Vec::new();
    for k in 0..n {
        let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
        let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
        let first = format!("p-first-{k}");
        c.request(method::SESSION_PROMPT, prompt(&id, "agent-503", Some(&first))).await.unwrap();
        ids.push(id);
    }
    for id in &ids {
        until(&hub, id, |o| o.iter().any(|o| o == "scheduled")).await;
    }
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let hub = durable(&dir, BTreeMap::new(), vec![50]);
    let _c = connect_to(&hub).await;
    hub.resume_queues();
    for id in &ids {
        hub.session_summary(&hub.resolve(id).unwrap());
    }
    let mut lost = 0;
    for id in &ids {
        let fired = |o: &[String]| o.iter().filter(|o| *o == "fired").count() >= 1;
        if !fired(&until(&hub, id, fired).await) {
            lost += 1;
        }
    }
    println!("DURESS lost {lost} of {n} injected faults (one restart while every retry waited)");
    hub.shutdown_all().await;
    drop(hub);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(lost, 0, "lost {lost} of {n}");
}
