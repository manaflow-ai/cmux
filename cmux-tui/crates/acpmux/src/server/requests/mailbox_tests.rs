use super::{
    parse_metadata, report_recipient, require_local_origin, validate_binding,
    validate_report_recipient,
};
use crate::mailbox::{Mailbox, MailboxError, SendInput};
use crate::server::Origin;
use crate::session_identity::SessionReceipt;
use serde_json::json;
use std::collections::BTreeMap;

fn receipt(host: &str, mux: &str, generation: u64) -> SessionReceipt {
    SessionReceipt::new(host, mux, Some(format!("agent-{mux}")), generation)
}

#[test]
fn spoofed_sender_identity_is_rejected() {
    let expected = receipt("local", "sender", 7);
    let spoofed = receipt("local", "other", 7);
    let error = validate_binding("sender", "local/other", &spoofed, &expected)
        .expect_err("spoofed sender must fail");
    assert_eq!(error.data.unwrap()["reason"], "mailbox_identity_mismatch");
}

#[test]
fn stale_restart_receipt_is_rejected() {
    let expected = receipt("local", "sender", 8);
    let stale = receipt("local", "sender", 7);
    let error = validate_binding("sender", "local/sender", &stale, &expected)
        .expect_err("stale receipt must fail");
    assert_eq!(error.data.unwrap()["reason"], "mailbox_identity_stale_generation");
}

#[test]
fn duplicate_id_binding_conflict_is_not_hidden_by_a_bare_id() {
    let expected = receipt("local", "sender", 7);
    assert!(validate_binding("sender", "sender", &expected, &expected).is_ok());
    let mailbox = Mailbox::memory();
    let input = |sender: &str| SendInput {
        id: "duplicate".into(),
        sender: sender.into(),
        recipient: "local/recipient".into(),
        body: "body".into(),
        metadata: BTreeMap::new(),
    };
    mailbox.send(input("local/sender")).unwrap();
    assert!(matches!(mailbox.send(input("local/other")), Err(MailboxError::IdConflict(_))));
}

#[test]
fn qualified_routing_returns_the_server_qualified_id() {
    let expected = receipt("local", "recipient", 7);
    assert_eq!(
        validate_binding("recipient", "local/recipient", &expected, &expected).unwrap(),
        "local/recipient"
    );
}

#[test]
fn remote_mailbox_rpc_is_rejected() {
    let error = require_local_origin(Origin::Web).expect_err("remote mailbox must fail closed");
    assert_eq!(error.code, -32602);
    assert_eq!(error.data.unwrap()["reason"], "mailbox_remote_refused");
    assert!(require_local_origin(Origin::Peer).is_err());
}

#[test]
fn local_mailbox_origins_are_allowed() {
    assert!(require_local_origin(Origin::Local).is_ok());
    assert!(require_local_origin(Origin::LocalApp).is_ok());
}

#[test]
fn null_metadata_is_normalized_to_empty_object() {
    let metadata = parse_metadata(&json!({"metadata": null})).expect("null is valid");
    assert!(metadata.is_empty());
}

#[test]
fn non_object_metadata_is_rejected() {
    let error =
        parse_metadata(&json!({"metadata": "invalid"})).expect_err("metadata must be an object");
    assert!(error.message.contains("metadata must be an object"));
}

#[test]
fn reports_alias_is_detected_and_validated() {
    let params = json!({"recipient": "reports:leo"});
    assert_eq!(report_recipient(&params), Some("reports:leo"));
    assert!(validate_report_recipient("reports:leo").is_ok());
    for invalid in ["reports:", "reports:   ", "agent"] {
        assert!(validate_report_recipient(invalid).is_err(), "{invalid} must be rejected");
    }
    assert_eq!(report_recipient(&json!({"recipient": "agent"})), None);
}
