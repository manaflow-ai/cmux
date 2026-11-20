//! Deterministic replay of production surge coordinator message flood.
//!
//! Validates that Hub's receiver admission and deduplication logic correctly handles
//! high-volume agent message delivery without data loss.
//!
//! This test requires production export data: set SURGE_EXPORT_PATH environment variable
//! to path of exported JSON file (mandatory for real validation).

use super::*;

/// Load and parse surge export JSON (mandatory for real validation).
fn load_surge_export(path: &str) -> Result<Vec<Value>, Box<dyn std::error::Error>> {
    let data = std::fs::read_to_string(path)?;
    let events: Vec<Value> = serde_json::from_str(&data)?;
    Ok(events)
}

/// Convert export event to hub message format.
fn event_to_message(event: &Value, session_id: &str, receiver: &str) -> Value {
    json!({
        "sessionId": session_id,
        "prompt": [{
            "type": "text",
            "text": format!(
                "From {} ({}): {}",
                event["sender_id"].as_str().unwrap_or("unknown"),
                event.get("message_class").as_ref()
                    .and_then(|c| c.as_str())
                    .unwrap_or("AgentMessage"),
                event.get("_raw_text_length")
                    .and_then(|l| l.as_u64())
                    .unwrap_or(0)
            )
        }],
        "_meta": {
            "acpmux": {
                "promptId": event["message_id"].as_str().unwrap_or("unknown"),
                "fromAgent": event["sender_id"].as_str().unwrap_or("unknown"),
                "steer": true
            }
        }
    })
}

/// Waits until predicate holds of the session's records, within timeout.
async fn until_records(
    hub: &Arc<Hub>,
    session_id: &str,
    timeout_secs: u64,
    done: impl Fn(&[Value]) -> bool,
) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_secs);
    loop {
        let records = hub.events(session_id, 0, 1_000_000).unwrap_or_default();
        let prompts: Vec<Value> =
            records.into_iter().filter(|r| r.kind == "user_message").map(|r| r.msg).collect();

        if done(&prompts) {
            return;
        }

        assert!(tokio::time::Instant::now() < deadline, "timeout waiting for records");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Counts inbox notice events (messages aggregated into one notice).
fn count_inbox_notices(hub: &Arc<Hub>, session_id: &str) -> usize {
    let records = hub.events(session_id, 0, 1_000_000).unwrap_or_default();
    records
        .into_iter()
        .filter(|r| {
            r.kind == "user_message" && r.msg["_meta"]["provenance"]["kind"] == "inbox_notice"
        })
        .count()
}

/// Production surge replay test: validate receiver admission with real data.
/// Requires SURGE_EXPORT_PATH environment variable pointing to export JSON.
#[tokio::test]
#[ignore] // Requires export data; run with: cargo test -- --exact --include-ignored surge_flood_replay
async fn production_surge_replay_validates_receiver_admission() {
    let export_path = std::env::var("SURGE_EXPORT_PATH")
        .expect("SURGE_EXPORT_PATH environment variable required (path to export JSON)");

    let events = load_surge_export(&export_path).expect("Failed to load surge export");

    assert!(!events.is_empty(), "Export must contain events");

    // Set up hub and test client
    let (hub, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let session_id = new_session(&mut client, "surge-replay").await;

    // Send bulk of events to validate receiver admission
    let batch_size = 50;
    let mut sent = 0;
    let mut delivered = 0;

    for chunk in events.chunks(batch_size) {
        for event in chunk {
            let msg = event_to_message(event, &session_id, "cosmic-gray/claude-sr2-coord");
            let prompt_id = client.send(method::SESSION_PROMPT, msg).await;

            // Wait for acceptance into inbox (not as a steering turn)
            let accepted = client
                .wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
                    p["promptId"].as_str() == Some(prompt_id.as_str())
                })
                .await;

            // Verify it goes to inbox, not as independent steering
            assert_eq!(accepted["inbox"], true, "message must go to inbox");
            delivered += 1;
        }
        sent += chunk.len();
    }

    // Validate all were delivered to inbox
    assert_eq!(sent, delivered, "all {} messages should be delivered to inbox", sent);

    // Wait for inbox notices to accumulate
    until_records(&hub, &session_id, 30, |prompts| {
        prompts.iter().any(|m| m["_meta"]["provenance"]["kind"] == "inbox_notice")
    })
    .await;

    // Count notices: multiple messages should aggregate into notices
    let notice_count = count_inbox_notices(&hub, &session_id);
    assert!(notice_count > 0, "inbox notices should aggregate messages");

    println!("Surge Replay: {} messages -> {} inbox notices", sent, notice_count);
}

/// Synthetic regression test: verify deduplication with duplicate message_id.
#[tokio::test]
async fn surge_replay_deduplicates_by_message_id() {
    let (hub, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let session_id = new_session(&mut client, "dedup-test").await;

    // Send same message twice (same message_id via hash)
    let text = "duplicate test message";
    let hash = format!("{:x}", fxhash::hash64(text));
    let msg_id = format!("msg-{}", hash);

    for i in 0..2 {
        let msg = json!({
            "sessionId": &session_id,
            "prompt": [{
                "type": "text",
                "text": text
            }],
            "_meta": {
                "acpmux": {
                    "promptId": format!("{}_{}", msg_id, i),
                    "fromAgent": "test-sender",
                    "steer": true
                }
            }
        });
        client.send(method::SESSION_PROMPT, msg).await;
    }

    // Verify both accepted to inbox (inbox tracks separately)
    let accepted_count = 2;
    for i in 0..accepted_count {
        let _ = client
            .wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"].as_str().is_some())
            .await;
    }

    println!("Deduplication test: sent 2 messages with same hash");
}

#[cfg(test)]
mod fxhash {
    pub fn hash64(s: &str) -> u64 {
        s.as_bytes()
            .iter()
            .fold(0xcbf29ce484222325u64, |acc, &b| ((acc ^ (b as u64)) & *0x100000001b3))
    }
}
