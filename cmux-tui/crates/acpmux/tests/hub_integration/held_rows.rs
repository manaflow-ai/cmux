//! The rows of a turn's opening records wait behind its first output (`server/held_rows.rs`):
//! each is still sent, once, in row order, before the turn's answer.
use super::*;

#[tokio::test]
async fn a_turns_opening_rows_are_all_sent_in_row_order_before_its_answer() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "held"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // A connection that watches the list and has the chat open, as a peer daemon's link does.
    c.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    c.request(method::MUX_ATTACH, json!({"session": "held", "limit": 100})).await.unwrap();
    for turn in 0..3 {
        let prompt = c
            .send(
                method::SESSION_PROMPT,
                json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("hello {turn}")}]}),
            )
            .await;
        let (answer, seen) = c.response(prompt).await;
        answer.unwrap();
        let rows: Vec<&Value> = seen
            .iter()
            .filter(|(m, p)| m == "_acpmux/session_changed" && p["sessionId"] == id.as_str())
            .map(|(_, p)| p)
            .collect();
        let kinds: Vec<&str> = rows.iter().filter_map(|p| p["recordKind"].as_str()).collect();
        let methods: Vec<&str> = seen.iter().map(|(m, _)| m.as_str()).collect();
        for opening in ["user_message", "turn_started"] {
            assert_eq!(kinds.iter().filter(|k| **k == opening).count(), 1, "{kinds:?} {methods:?}");
        }
        assert!(kinds.contains(&"status") && kinds.contains(&"turn_end"), "{kinds:?}");
        // Row order is the order of their records: a held row is never passed by a later row.
        let seqs: Vec<u64> = rows.iter().filter_map(|p| p["listSeq"].as_u64()).collect();
        assert_eq!(seqs.len(), rows.len(), "{rows:?}");
        assert!(seqs.windows(2).all(|w| w[0] < w[1]), "{kinds:?} {seqs:?}");
        let record_seqs: Vec<u64> = rows.iter().filter_map(|p| p["seq"].as_u64()).collect();
        assert!(record_seqs.windows(2).all(|w| w[0] <= w[1]), "{kinds:?} {record_seqs:?}");
        // The row of each opening record carries that record's own seq, as its event does.
        for (m, p) in &seen {
            if m == "_acpmux/event" && p["kind"] == "turn_started" {
                let row = rows.iter().find(|r| r["recordKind"] == "turn_started").unwrap();
                assert_eq!(row["seq"], p["seq"], "{row} {p}");
            }
        }
    }
}

/// A connection that asked for row patches (`sessionChangedDelta`, as every peer link does) hears
/// a held row as a `session_patch` once it holds the chat's row, as it hears every other row:
/// sent whole, the five rows of each turn were most of a streaming chat's bytes on a peer link.
#[tokio::test]
async fn held_rows_go_as_patches_to_a_connection_that_asked_for_them() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    c.request(
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "test"},
            "_meta": {"acpmux": {"sessionChangedDelta": 2}}}),
    )
    .await
    .unwrap();
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "held-patch"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    c.request(method::MUX_ATTACH, json!({"session": "held-patch", "limit": 100})).await.unwrap();
    let mut row_seq = None::<u64>;
    for turn in 0..3 {
        let prompt = c
            .send(
                method::SESSION_PROMPT,
                json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("hello {turn}")}]}),
            )
            .await;
        let (answer, seen) = c.response(prompt).await;
        answer.unwrap();
        let rows: Vec<(&str, &Value)> = seen
            .iter()
            .filter(|(m, p)| {
                (m == "_acpmux/session_changed" || m == "_acpmux/session_patch")
                    && p["sessionId"] == id.as_str()
            })
            .map(|(m, p)| (m.as_str(), p))
            .collect();
        let kinds: Vec<(&str, &str)> =
            rows.iter().map(|(m, p)| (*m, p["recordKind"].as_str().unwrap_or(""))).collect();
        for opening in ["user_message", "turn_started"] {
            assert_eq!(kinds.iter().filter(|(_, k)| *k == opening).count(), 1, "{kinds:?}");
        }
        // Every row notice carries the next rowSeq: none is lost or sent twice.
        for (m, p) in &rows {
            let seq = p["rowSeq"].as_u64().unwrap_or_else(|| panic!("{m} {p}"));
            if let Some(prev) = row_seq {
                assert_eq!(seq, prev + 1, "{kinds:?}");
            }
            row_seq = Some(seq);
        }
        if turn > 0 {
            for (m, p) in &rows {
                if held_kind(p) {
                    assert_eq!(*m, "_acpmux/session_patch", "{kinds:?}");
                }
            }
        }
    }
}

fn held_kind(p: &Value) -> bool {
    matches!(p["recordKind"].as_str(), Some("user_message" | "turn_started" | "status"))
}
