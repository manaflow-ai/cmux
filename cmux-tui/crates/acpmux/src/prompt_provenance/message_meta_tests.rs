use super::{MESSAGE_META, marked, recorded};
use serde_json::json;

/// A record's provenance is the sender's alone: its message copies (one of its own, one per
/// joined message of a digest) sit beside it, and reading the record puts them back.
#[test]
fn a_record_keeps_its_message_copies_beside_its_provenance() {
    let copy = |id: &str| json!({"messageId": id, "sender": {"name": "lane", "sessionId": "s"}});
    let own =
        json!({"kind": "agent_message", "from": "acp:s", "to": "acp:t", MESSAGE_META: copy("m-0")});
    let digest = json!({"kind": "agent_digest", "messages": [
        {"promptId": "p-1", "from": "lane", "provenance": {"kind": "session_message", MESSAGE_META: copy("m-1")}},
        {"promptId": "p-2", "from": "person"},
        {"promptId": "p-3", "from": "lane", "provenance": {"kind": "session_message"}},
        {"promptId": "p-4", "from": "lane", "provenance": {"kind": "session_message", MESSAGE_META: copy("m-4")}},
    ]});
    for provenance in [own, digest] {
        let record = marked(json!({"promptId": "p"}), Some(&provenance));
        let shown = record.pointer("/_meta/provenance").unwrap();
        assert!(!shown.to_string().contains(MESSAGE_META), "{record}");
        assert!(record.pointer(&format!("/_meta/{MESSAGE_META}")).is_some(), "{record}");
        assert_eq!(recorded(&record), Some(provenance));
    }
    // No copy: the record is as before, and so is what reading it gives.
    let plain = json!({"kind": "agent_message", "from": "acp:s", "to": "acp:t"});
    let record = marked(json!({"promptId": "p"}), Some(&plain));
    assert_eq!(record["_meta"], json!({"provenance": plain}));
    assert_eq!(recorded(&record), Some(plain));
}
