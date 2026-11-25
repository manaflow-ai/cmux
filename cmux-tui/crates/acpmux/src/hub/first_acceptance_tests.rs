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
async fn wedge_a_resend_answers_with_the_inbox_receipt_its_first_run_got() {
    let hub = hub();
    let session = chat(&hub, "01-target", "target");
    let outcome = ledger_entry(&session, "msg_1");
    let outcome_for_wait = outcome.clone();
    let mut first = outcome.subscribe();
    // In flight, not accepted yet: the resend waits for it (it neither answers "taken" nor
    // gives up).
    let waiting = {
        let session = session.clone();
        tokio::spawn(async move {
            first_acceptance(&session, "msg_1", outcome_token(&outcome_for_wait), &mut first).await
        })
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
async fn a_pending_inbox_receipt_survives_a_513_acceptance_burst() {
    let hub = hub();
    let session = chat(&hub, "01-burst", "burst");
    let outcome = ledger_entry(&session, "msg_pending");
    let receipt = json!({"sessionId": session.id, "promptId": "msg_pending", "queued": false,
                         "inbox": true});
    keep_acceptance(&session, "msg_pending", &receipt);

    // Fill the cache with later accepted prompts. The first one is still pending and has no
    // turn id, so it must be retained while completed or unknown entries are evicted.
    for i in 0..KEPT_ACCEPTS {
        let id = format!("later-{i}");
        // A receipt is only kept for a prompt with a live ledger outcome. Keep every later
        // outcome pending so this burst exercises the overflow map, not an empty-cache path.
        let _later_outcome = ledger_entry(&session, &id);
        keep_acceptance(&session, &id, &json!({"promptId": id, "queued": true}));
    }

    assert_eq!(
        session.accepted_prompts.lock().unwrap().len(),
        KEPT_ACCEPTS,
        "the public acceptance ring grew past its bound"
    );
    assert_eq!(
        session.pending_acceptances.lock().unwrap().len(),
        KEPT_ACCEPTS + 1,
        "the live overflow receipts were not retained"
    );

    let mut first = outcome.subscribe();
    let kept = tokio::time::timeout(
        Duration::from_secs(2),
        first_acceptance(&session, "msg_pending", outcome_token(&outcome), &mut first),
    )
    .await
    .expect("the pending acceptance was evicted by the burst")
    .expect("the pending acceptance remains available");
    assert_eq!(kept["inbox"], true, "{kept}");
    release_acceptance(&session, "msg_pending", &outcome);
    assert!(!session.pending_acceptances.lock().unwrap().contains_key("msg_pending"));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn wedge_a_resend_of_a_first_run_refused_unaccepted_hears_no_acceptance() {
    let hub = hub();
    let session = chat(&hub, "01-target2", "target2");
    let outcome = ledger_entry(&session, "msg_2");
    let outcome_for_wait = outcome.clone();
    let mut first = outcome.subscribe();
    let waiting = {
        let session = session.clone();
        tokio::spawn(async move {
            first_acceptance(&session, "msg_2", outcome_token(&outcome_for_wait), &mut first).await
        })
    };
    tokio::time::sleep(Duration::from_millis(20)).await;
    outcome.send_replace(Some(Err(RpcError::invalid_params("refused"))));
    let kept = tokio::time::timeout(Duration::from_secs(2), waiting).await.unwrap().unwrap();
    assert!(kept.is_none());
}

#[tokio::test]
async fn a_refused_new_attempt_does_not_reuse_an_old_acceptance_receipt() {
    let hub = hub();
    let session = chat(&hub, "01-retry", "retry");
    let old = ledger_entry(&session, "reused");
    let old_token = outcome_token(&old);
    let mut old_first = old.subscribe();

    // A completed outcome may be pruned while the acceptance cache still has room for it.
    // Starting the next attempt must retire that stale receipt atomically with ledger creation.
    keep_acceptance(
        &session,
        "reused",
        &json!({"promptId": "reused", "queued": true, "generation": "old"}),
    );
    session.prompts.lock().unwrap().clear();
    let next = begin_outcome(&session, "reused").expect("the refused retry creates an outcome");
    let next_token = outcome_token(&next);
    keep_acceptance(
        &session,
        "reused",
        &json!({"promptId": "reused", "queued": true, "generation": "new"}),
    );
    let kept = session.accepted_prompts.lock().unwrap().clone();
    assert_eq!(kept.len(), 1, "the old generation receipt was not retired: {kept:?}");
    assert_eq!(kept[0].0, "reused");
    assert_eq!(kept[0].1, next_token);
    assert_ne!(kept[0].1, old_token);
    let waiting = tokio::time::timeout(
        Duration::from_millis(50),
        first_acceptance(&session, "reused", old_token, &mut old_first),
    )
    .await;
    assert!(waiting.is_err(), "stale receipt acknowledged the new attempt");
    old.send_replace(Some(Err(RpcError::invalid_params("refused"))));
    assert!(
        tokio::time::timeout(
            Duration::from_secs(2),
            first_acceptance(&session, "reused", old_token, &mut old_first),
        )
        .await
        .unwrap()
        .is_none()
    );
    let _ = next;
}
