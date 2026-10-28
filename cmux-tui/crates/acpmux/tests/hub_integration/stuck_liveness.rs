//! A persistent harness outage is visible as `stuck` in every local session row.
//!
//! The fake ACP harness returns SR2's 503 for three consecutive turns.  The
//! fourth turn succeeds, proving that the liveness marker is cleared by the
//! next successful turn rather than becoming permanent.
use super::*;

fn row(hub: &Hub, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())
}

fn listed<'a>(reply: &'a Value, id: &str) -> &'a Value {
    reply["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["sessionId"] == id)
        .and_then(|entry| entry.pointer("/_meta/acpmux").or(Some(entry)))
        .unwrap()
}

async fn new_session(c: &mut TestClient) -> String {
    let reply = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "stuck-liveness"}}}),
        )
        .await
        .unwrap();
    reply["sessionId"].as_str().unwrap().to_owned()
}

async fn wait_for_stuck(hub: &Hub, id: &str) -> Value {
    for _ in 0..400 {
        let summary = row(hub, id);
        if summary["state"] == "stuck" {
            return summary;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    row(hub, id)
}

#[tokio::test]
async fn three_503s_are_stuck_in_the_summary_and_session_list_then_success_clears_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    // Keep the third retry pending long enough to inspect the stuck row. The
    // person's successful prompt below supersedes that pending retry.
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20, 20, 60_000]);
    let id = new_session(&mut c).await;
    let failed = c
        .request(
            method::SESSION_PROMPT,
            json!({
                "sessionId": id,
                "prompt": [{"type": "text", "text": "cap-fail-three: build it"}],
                "_meta": {"acpmux": {"promptId": "p-stuck"}}
            }),
        )
        .await;
    assert!(failed.unwrap_err().contains("no non-exhausted claude accounts"));

    let stuck = wait_for_stuck(&hub, &id).await;
    assert_eq!(stuck["state"], "stuck", "{stuck}");
    assert_eq!(stuck["stuckReason"], "harness_unavailable", "{stuck}");
    assert!(stuck["stuckSince"].as_u64().is_some(), "{stuck}");
    assert!(stuck["stuckError"].as_str().is_some(), "{stuck}");
    let error = stuck["stuckError"].as_str().unwrap();
    assert!(error.contains("503"), "{error}");
    assert!(!error.contains("127.0.0.1:4016"), "credentials/URLs must be redacted: {error}");

    // Both list surfaces carry the same summary fields as the direct ls row.
    let listed_sessions = c.request(method::SESSION_LIST, json!({})).await.unwrap();
    let list_row = listed(&listed_sessions, &id);
    assert_eq!(list_row["state"], "stuck", "{listed_sessions}");
    assert_eq!(list_row["stuckReason"], "harness_unavailable", "{listed_sessions}");
    let mux_sessions = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    let mux_row = listed(&mux_sessions, &id);
    assert_eq!(mux_row["state"], "stuck", "{mux_sessions}");
    assert_eq!(mux_row["stuckReason"], "harness_unavailable", "{mux_sessions}");

    // A successful person turn clears the marker immediately after its turn.
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "recovered"}]}),
    )
    .await
    .unwrap();
    let recovered = row(&hub, &id);
    assert_ne!(recovered["state"], "stuck", "{recovered}");
    assert!(recovered["stuckReason"].is_null(), "{recovered}");
    assert!(recovered["stuckSince"].is_null(), "{recovered}");
    assert!(recovered["stuckError"].is_null(), "{recovered}");
}
