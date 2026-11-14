use super::{is_duplicate, kept_another};
use serde_json::json;

/// A sender's copy is recorded only for the message the peer's acceptance names, and only
/// when that acceptance is no duplicate; a peer that names none is taken at its word.
#[test]
fn an_acceptance_confirms_only_the_message_it_names() {
    let named = json!({"sessionId": "t", "promptId": "p", "messageId": "p",
                           "messageSenderId": "sender-a"});
    for names in [true, false] {
        assert!(!kept_another(&named, Some(("sender-a", "p")), names));
        assert!(kept_another(&named, Some(("sender-a", "delivery-1")), names));
        // Another session's send of the same prompt id is not ours either.
        assert!(kept_another(&named, Some(("sender-b", "p")), names));
        assert!(!kept_another(&named, None, names));
    }
    // An acceptance naming no message: from a peer that names messages it is another
    // prompt's (a person's, under the same id), so it confirms no session's send; from a
    // peer that never names one it is taken at its word.
    let unnamed = json!({"sessionId": "t", "promptId": "p"});
    assert!(kept_another(&unnamed, Some(("sender-a", "p")), true));
    assert!(!kept_another(&unnamed, Some(("sender-a", "delivery-1")), false));
    let half = json!({"sessionId": "t", "promptId": "p", "messageId": "p"});
    assert!(kept_another(&half, Some(("sender-a", "p")), true));
    assert!(!kept_another(&half, Some(("sender-a", "p")), false));
    assert!(is_duplicate(&json!({"promptId": "p", "duplicate": true, "turnId": "t1"})));
    assert!(is_duplicate(&json!({"stopReason": "end_turn",
                                     "_meta": {"acpmux": {"duplicate": true}}})));
    assert!(!is_duplicate(&named));
}

/// An empty `messageId` is no id: the receiver keeps the prompt id, and so does the sender.
#[test]
fn a_forwarded_message_is_named_as_its_receiver_names_it() {
    use super::super::outbox::forwarded_message_id;
    let with = |meta: serde_json::Value| json!({"_meta": {"acpmux": meta}});
    assert_eq!(forwarded_message_id(&with(json!({"messageId": "", "promptId": "p"}))), "p");
    assert_eq!(forwarded_message_id(&with(json!({"messageId": "m", "promptId": "p"}))), "m");
    assert_eq!(forwarded_message_id(&with(json!({"promptId": "p"}))), "p");
}
