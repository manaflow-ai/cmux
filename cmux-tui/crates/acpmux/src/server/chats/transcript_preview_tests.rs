use super::*;

#[test]
fn terminal_agent_history_oversized_rows_fit_the_wire_without_moving_other_turns() {
    let escaped = "\u{0001}🐈\n\\\"".repeat(1 << 14);
    let tool = PastTool {
        id: "1".into(),
        call: json!({"title":escaped}),
        done: Value::Null,
        started_at: None,
        ended_at: None,
        proposed: None,
    };
    let mut page = TranscriptPage::default();
    for n in 0..32 {
        page.turns.push(PastTurn {
            prompt: format!("prompt {n}"),
            answer: if n % 2 == 1 { "short answer".into() } else { escaped.clone() },
            tools: if n == 18 { vec![tool.clone(); 12] } else { Vec::new() },
            ..PastTurn::default()
        });
    }
    page.turns[0].prompt = escaped.repeat(2);
    let rows = turns(&page);
    assert_eq!(rows.len(), 32);
    assert_eq!(rows[0]["truncated"], true);
    assert_eq!(rows[18]["truncated"], true);
    for (n, row) in rows.iter().enumerate().skip(1) {
        assert_eq!(row["prompt"], format!("prompt {n}"));
        if n % 2 == 1 {
            assert_eq!(row["answer"], "short answer");
            assert_eq!(row["truncated"], false);
        }
    }
    let reply = crate::rpc::Message::ok(
        json!(123),
        json!({
            "key":format!("claude-code:{}", "a".repeat(128)), "title":title(&escaped),
            "before":u64::MAX,"pageEnd":u64::MAX, "createdMs":u64::MAX,"updatedMs":u64::MAX,
            "turns":rows,
        }),
    )
    .to_line();
    assert!(reply.len() < 1024 * 1024, "serialized page is {} bytes", reply.len());
}
