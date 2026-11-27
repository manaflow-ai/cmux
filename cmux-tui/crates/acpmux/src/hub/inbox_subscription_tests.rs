use super::*;

#[test]
fn replay_keeps_latest_self_binding_and_survives_remove() {
    let records = vec![
        crate::store::EventRecord {
            seq: 1,
            at: 1,
            dir: "mux".into(),
            kind: RECORD_KIND.into(),
            msg: json!({"threadId":"pr:1","ownerSessionId":"owner","active":true}),
            host_seq: None,
        },
        crate::store::EventRecord {
            seq: 2,
            at: 2,
            dir: "mux".into(),
            kind: RECORD_KIND.into(),
            msg: json!({"threadId":"pr:2","ownerSessionId":"other","active":true}),
            host_seq: None,
        },
        crate::store::EventRecord {
            seq: 3,
            at: 3,
            dir: "mux".into(),
            kind: RECORD_KIND.into(),
            msg: json!({"threadId":"pr:1","ownerSessionId":"owner","active":false}),
            host_seq: None,
        },
    ];
    assert!(replay("owner", records).is_empty());

    let active = vec![crate::store::EventRecord {
        seq: 4,
        at: 4,
        dir: "mux".into(),
        kind: RECORD_KIND.into(),
        msg: json!({"threadId":"pr:3","ownerSessionId":"owner","active":true}),
        host_seq: None,
    }];
    assert_eq!(replay("owner", active).keys().next().map(String::as_str), Some("pr:3"));
}
