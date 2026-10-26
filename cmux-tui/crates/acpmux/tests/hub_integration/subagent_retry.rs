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
    let (hub, mut c) = super::stop::claude_setup().await;
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
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(outcomes(&hub, &id), ["scheduled", "fired"]);
    assert_eq!(user_messages(&hub, &id).len(), 2);
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
    for _ in 0..200 {
        if user_messages(&hub, &id).len() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(user_messages(&hub, &id)[1]["_meta"]["provenance"]["kind"], "subagent_retry");
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
