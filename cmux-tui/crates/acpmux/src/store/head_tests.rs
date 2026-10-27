//! `RecordHead::read`: the head of a line the daemon wrote, and None for any other (`store.rs`).

use super::*;

fn line(rec: &EventRecord) -> Vec<u8> {
    serde_json::to_vec(rec).unwrap()
}

#[test]
fn a_written_record_reads_its_head_and_parses_whole() {
    let mut rec = EventRecord {
        seq: 42,
        at: 1_700,
        dir: "in".into(),
        kind: "tool_call_update".into(),
        msg: json_msg(),
        host_seq: Some(9),
    };
    for host_seq in [Some(9), None] {
        rec.host_seq = host_seq;
        let bytes = line(&rec);
        let head = RecordHead::read(&bytes).expect("head");
        assert_eq!(
            (head.seq, head.at, head.dir, head.kind, head.host_seq),
            (42, 1_700, "in", "tool_call_update", host_seq)
        );
        assert_eq!(head.record(), Some(rec.clone()));
        assert!(head.may_contain(b"\"hostSeq\":5"));
        assert!(!head.may_contain(b"\"spawnAgent\""));
    }
}

/// The record's own `hostSeq` is its last field; one inside `msg` is not it.
fn json_msg() -> Value {
    serde_json::json!({"params": {"x": "y"}, "z": {"hostSeq": 5}})
}

#[test]
fn a_line_of_another_shape_has_no_head() {
    let rec = EventRecord {
        seq: 1,
        at: 2,
        dir: "mux".into(),
        kind: "a\"b".into(),
        msg: Value::Null,
        host_seq: None,
    };
    // An escaped kind is left to a parse.
    assert!(RecordHead::read(&line(&rec)).is_none());
    for other in [
        &br#"{"at":2,"seq":1,"dir":"mux","kind":"status","msg":{}}"#[..],
        br#"{"seq":1,"at":2,"dir":"mux","kind":"status","hostSeq":3,"msg":{}}"#,
        br#"{"seq":1,"at":2,"dir":"mux","kind":"status","msg":{"a""#,
        br#"{"seq":1,"at":2,"dir":"mux","kind":"status","msg":{"a":1,"hostSeq":3}}"#,
    ] {
        let head = RecordHead::read(other);
        assert!(
            head.as_ref().is_none_or(|h| h.host_seq.is_none()),
            "{}",
            String::from_utf8_lossy(other)
        );
    }
    // A msg that ends in a `hostSeq` of its own gives the record none.
    let nested = br#"{"seq":1,"at":2,"dir":"mux","kind":"status","msg":{"a":1,"hostSeq":3}}"#;
    assert_eq!(RecordHead::read(nested).map(|h| h.host_seq), Some(None));
}
