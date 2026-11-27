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
