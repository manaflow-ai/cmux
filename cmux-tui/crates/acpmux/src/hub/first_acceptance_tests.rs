//! A resend of a client prompt id whose first run the chat's inbox took (`turns.rs`
//! `first_acceptance`, `server/outbox.rs` `taken_without_turn`).
//!
//! Leo's daemon, 2026-11-25: an outbox delivery's first attempt got no acceptance within 120 s;
//! every retry sent the same id, heard a duplicate with no turn (an inbox message has none),
//! which the outbox could not count as taken, and waited for the message's answer. 250 messages
//! to three coordinators retried every 120 s until the daemon restarted.

use super::*;
use crate::hub::former_names::tests::{chat, hub};
use std::time::Duration;

fn ledger_entry(session: &Session, id: &str) -> PromptOutcome {
    let outcome = Arc::new(tokio::sync::watch::channel(None).0);
    session.prompts.lock().unwrap().push_back((id.to_owned(), outcome.clone()));
    outcome
}

#[tokio::test]
async fn a_resend_answers_with_the_inbox_receipt_its_first_run_got() {
    let hub = hub();
    let session = chat(&hub, "01-target", "target");
    let outcome = ledger_entry(&session, "msg_1");
    let mut first = outcome.subscribe();
    // In flight, not accepted yet: the resend waits for it (it neither answers "taken" nor
    // gives up).
    let waiting = {
        let session = session.clone();
        tokio::spawn(async move { first_acceptance(&session, "msg_1", &mut first).await })
    };
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!waiting.is_finished(), "answered before the first run was accepted");
    // The inbox takes it: a receipt, with no turn. The resend hears it at once, though the
    // message's own answer (`outcome`) is still to come.
    let receipt = json!({"sessionId": session.id, "promptId": "msg_1", "queued": false,
                         "inbox": true});
    keep_acceptance(&session, "msg_1", &receipt);
    let kept = tokio::time::timeout(Duration::from_secs(2), waiting)
        .await
        .expect("the resend still waited after the inbox took the message")
        .unwrap()
        .expect("an acceptance");
    assert_eq!(kept["inbox"], true);
    // The outbox counts that duplicate as taken; one with no turn and no receipt it does not.
    let notice = json!({"promptId": "msg_1", "duplicate": true, "turnId": null, "inbox": true});
    assert!(crate::server::outbox::taken_without_turn(&notice));
    let bare = json!({"promptId": "msg_1", "duplicate": true, "turnId": null});
    assert!(!crate::server::outbox::taken_without_turn(&bare));
    assert!(outcome.borrow().is_none());
}

#[tokio::test]
async fn a_resend_of_a_first_run_refused_unaccepted_hears_no_acceptance() {
    let hub = hub();
    let session = chat(&hub, "01-target2", "target2");
    let outcome = ledger_entry(&session, "msg_2");
    let mut first = outcome.subscribe();
    let waiting = {
        let session = session.clone();
        tokio::spawn(async move { first_acceptance(&session, "msg_2", &mut first).await })
    };
    tokio::time::sleep(Duration::from_millis(20)).await;
    outcome.send_replace(Some(Err(RpcError::invalid_params("refused"))));
    let kept = tokio::time::timeout(Duration::from_secs(2), waiting).await.unwrap().unwrap();
    assert!(kept.is_none());
}
