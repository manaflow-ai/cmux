//! A reply that goes back belongs to the turn that answered the question (review B2 of #39055):
//! a question whose turn never started (a Stop kept it from the agent) gets no reply, and the
//! next turn's reply never goes to its asker.

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub on the stand-in agent, with sessions `alpha` (the asker) and `beta` (asked).
async fn two_chats() -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let argv = ["/usr/bin/env", "FAKE_RESET_CANCEL_ON_PROMPT=1", "python3", fake];
    let cfg = json!({"harnesses": {"fake": {"argv": argv}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let chat = async |name: &str| {
        let mut req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        req.name = Some(name.to_owned());
        hub.new_session(req).await.unwrap()
    };
    let (alpha, beta) = (chat("w5s-asker").await, chat("w5s-answers").await);
    (hub, alpha, beta)
}

/// `asker`'s `--no-wait --class question` to `to`, as the daemon binds it to the asker's proven
/// session (`server/requests.rs`): a `session_message` with `fromSessionId`.
fn asks(asker: &Session, to: &Session) -> PromptOptions {
    let provenance =
        crate::prompt_provenance::session_message(&asker.id, &asker.meta().name, &to.id);
    let bound = crate::prompt_provenance::BoundSender::of_session(&asker.id, &asker.meta());
    PromptOptions {
        provenance: Some(crate::prompt_provenance::stamp_sender(provenance, Some(&bound))),
        class: Some(crate::prompt_class::PromptClass::Question),
        ..PromptOptions::default()
    }
}

fn text(t: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": t})]
}

/// Whether any record of session `id` holds `needle`.
fn holds(hub: &Hub, id: &str, needle: &str) -> bool {
    let records = hub.events(id, 0, 100_000).unwrap();
    records.iter().any(|r| r.msg.to_string().contains(needle))
}

/// Waits until `session` runs no turn and queues nothing: every report it was sent is in.
async fn settled(session: &Session) {
    let idle = async {
        loop {
            let queued = !session.queue.lock().unwrap_or_else(|e| e.into_inner()).is_empty();
            if session.turn().is_none() && !queued {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    };
    tokio::time::timeout(WAIT, idle).await.expect("the chat settles");
}

/// Runs the person's prompt `t` in `session` to its end.
async fn persons_turn(hub: &Arc<Hub>, session: &Arc<Session>, t: &str) {
    let answer = tokio::time::timeout(WAIT, hub.prompt(session, text(t), "test", false));
    let answer = answer.await.unwrap().unwrap();
    assert_eq!(answer["stopReason"], "end_turn", "{answer}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn w5s_a_question_a_stop_kept_from_its_turn_never_gets_the_next_turns_reply() {
    let (hub, alpha, beta) = two_chats().await;
    // Both agents run already, so a report is in alpha's records as soon as it is sent; beta has
    // a turn of its own before the question (an unstarted turn's capture read that one).
    persons_turn(&hub, &alpha, "ALPHA-WARM").await;
    persons_turn(&hub, &beta, "PERSONS-EARLIER-TURN").await;

    // alpha's question to beta takes beta's turn; a Stop comes before the turn starts.
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let asked = {
        let (hub, alpha, beta) = (hub.clone(), alpha.clone(), beta.clone());
        tokio::spawn(async move {
            let q = text("QUESTION-STOPPED What is 8*8?");
            hub.prompt_with(&beta, q, "test", false, asks(&alpha, &beta)).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    hub.cancel(&beta).await.unwrap();
    release.send(()).unwrap();
    let stopped = tokio::time::timeout(WAIT, asked).await.unwrap().unwrap();
    assert!(stopped.is_err(), "the Stop kept the question from beta's agent: {stopped:?}");

    // The person's next prompt to beta runs a turn of its own.
    persons_turn(&hub, &beta, "PERSONS-OWN-TURN").await;

    // Then alpha asks again, and that reply does reach alpha: any report sent before it is in
    // alpha's records by then.
    let again =
        hub.prompt_with(&beta, text("QUESTION-ANSWERED"), "test", false, asks(&alpha, &beta));
    tokio::time::timeout(WAIT, again).await.unwrap().unwrap();
    let reached = async {
        while !holds(&hub, &alpha.id, "QUESTION-ANSWERED") {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    };
    tokio::time::timeout(WAIT, reached).await.expect("alpha got beta's reply to its question");
    settled(&alpha).await;
    for other in ["PERSONS-OWN-TURN", "PERSONS-EARLIER-TURN"] {
        assert!(
            !holds(&hub, &alpha.id, other),
            "{other}: a turn that did not answer alpha's question reported to alpha"
        );
    }
}
