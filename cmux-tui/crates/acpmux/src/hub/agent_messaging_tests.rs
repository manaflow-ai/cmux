//! Agent-to-agent messaging that an agent gets right the first time (round-2 orchestration eval,
//! 2026-11-08): the session that gave a chat its work sends its next step as a prompt whose reply
//! answers the send (`inbox.rs` `inbox_route`), a waiting send the receiver's inbox would hold
//! without waking it is refused at once (`not_woken`), and a turn still coming keeps a wait from
//! reading the idle state from before (`Hub::work_coming`).

use super::*;
use crate::prompt_class::PromptClass;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub on the stand-in agent with one open chat, its store in memory.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// Session `from`'s plain send of `text` (`session/prompt` as an agent's `acpmux send` makes
/// it), of `class`, waiting for the reply when `wake_or_fail`. `accepted` hears its acceptance.
fn send(
    hub: &Arc<Hub>,
    to: &Arc<Session>,
    from: &str,
    prompt_id: &str,
    text: &str,
    class: PromptClass,
    wake_or_fail: bool,
) -> (tokio::task::JoinHandle<Result<Value, RpcError>>, tokio::sync::oneshot::Receiver<Value>) {
    let provenance = json!({"kind": "session_message", "from": format!("acp:{from}"),
                            "fromName": from, "to": format!("acp:{}", to.id), "verified": true});
    let (tx, accepted) = tokio::sync::oneshot::channel();
    let opts = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        provenance: Some(provenance),
        agent: Some(from.to_owned()),
        class: Some(class),
        inbox: true,
        wake_or_fail,
        on_accepted: Some(Box::new(move |v| {
            let _ = tx.send(v);
        })),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": text})];
    let (hub, to) = (hub.clone(), to.clone());
    (tokio::spawn(async move { hub.prompt_with(&to, blocks, "test", false, opts).await }), accepted)
}

/// The prompt ids of the chat's turns, in order.
fn turns(hub: &Hub, s: &Session) -> Vec<Value> {
    let records = hub.events(&s.id, 0, 100_000).unwrap();
    let turns = records.into_iter().filter(|r| r.kind == "user_message");
    turns.map(|r| r.msg["promptId"].clone()).collect()
}

/// The chat ran its first work from `s-coord` and is idle again.
async fn delegated() -> (Arc<Hub>, Arc<Session>) {
    let (hub, s) = chat().await;
    let (first, _) = send(&hub, &s, "s-coord", "p-1", "first step", PromptClass::Result, true);
    let done = tokio::time::timeout(WAIT, first).await.unwrap().unwrap().unwrap();
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    assert_eq!(s.meta().delegator.as_deref(), Some("s-coord"));
    (hub, s)
}

/// The eval's A3: only the first send to a chat ran as a turn; every later one from the same
/// sender became an "[inbox]" notice, answered with apologies. The session that gave the chat
/// its work sends its next step as a prompt of its own, and the send answers with that turn.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_delegators_next_send_runs_as_its_own_turn_and_answers_with_it() {
    let (hub, s) = delegated().await;
    let (next, accepted) =
        send(&hub, &s, "s-coord", "p-2", "second step", PromptClass::Result, true);
    let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert_ne!(accepted["inbox"], true, "not an inbox item: {accepted}");
    let done = tokio::time::timeout(WAIT, next).await.unwrap().unwrap().unwrap();
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    assert_eq!(turns(&hub, &s), [json!("p-1"), json!("p-2")], "its own turn, its own prompt");
    assert!(s.inbox.lock().unwrap().items.is_empty(), "nothing waits in the inbox");
}

/// The eval's A5: an agent's `send --wait --timeout 300` to an idle chat it did not start hung all
/// 300 s, its message held in the inbox and `send --status` saying delivered. A waiting send of a
/// class that does not wake the chat is refused at once, and nothing is delivered.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_waiting_send_that_cannot_wake_an_idle_chat_is_refused_at_once() {
    let (hub, s) = delegated().await;
    let (asked, _) = send(&hub, &s, "s-other", "p-x", "status?", PromptClass::Result, true);
    let refused = tokio::time::timeout(Duration::from_secs(5), asked)
        .await
        .expect("refused at once, not after a flush")
        .unwrap()
        .expect_err("a held message is no answer");
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "send.not_woken", "{refused:?}");
    assert!(refused.message.contains("--class question"), "names the fix: {}", refused.message);
    assert!(s.inbox.lock().unwrap().items.is_empty(), "nothing was delivered");
    assert!(!hub.work_coming(&s.id), "no turn comes for it");

    // The same message that does not wait (`send --no-wait`) is held, and says so.
    let (held, accepted) = send(&hub, &s, "s-other", "p-y", "fyi", PromptClass::Result, false);
    let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert_eq!(accepted["inbox"], true, "{accepted}");
    assert_eq!(accepted[crate::cli::output::HELD_IN_INBOX], true, "{accepted}");
    assert!(!hub.work_coming(&s.id), "a held message brings no turn");
    held.abort();

    // A question wakes it: never refused, and a turn comes until its notice ran.
    let (question, accepted) =
        send(&hub, &s, "s-other", "p-q", "which branch?", PromptClass::Question, true);
    let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert!(accepted.get(crate::cli::output::HELD_IN_INBOX).is_none(), "{accepted}");
    assert!(hub.work_coming(&s.id), "its notice's turn is still coming");
    let answered = tokio::time::timeout(WAIT, question).await.unwrap().unwrap().unwrap();
    assert_eq!(answered["stopReason"], "end_turn", "{answered}");
    let settled = async {
        while hub.work_coming(&s.id) {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, settled).await.expect("nothing more comes once it ran");
}

/// A waiting FYI is refused at once while a cut turn's continuation may still fire: the
/// continuation brings a turn, but FYIs alone still wait for the flush (router review of #38603
/// at 8991049, F1). A result from the chat's delegator still goes in as before.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_waiting_fyi_is_refused_while_a_continuation_may_fire() {
    let (hub, s) = delegated().await;
    hub.set_ending_for_test(&s, Some("cut"));
    let (asked, _) = send(&hub, &s, "s-other", "p-f", "CI is slow", PromptClass::Fyi, true);
    let refused = tokio::time::timeout(Duration::from_secs(5), asked)
        .await
        .expect("refused at once, not after a flush")
        .unwrap()
        .expect_err("a held FYI is no answer");
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "send.not_woken", "{refused:?}");
    assert!(s.inbox.lock().unwrap().items.is_empty(), "nothing was delivered");

    // A result from someone else is held for the continuation, never refused, as before.
    let (held, accepted) = send(&hub, &s, "s-other", "p-r", "done", PromptClass::Result, true);
    let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert_eq!(accepted["inbox"], true, "{accepted}");
    assert!(accepted.get(crate::cli::output::HELD_IN_INBOX).is_none(), "{accepted}");
    held.abort();
    hub.set_ending_for_test(&s, None);
}

/// A prompt queued behind a turn starts when that turn ends: between the end and its start (the
/// turn taken, the chat not running) a turn still comes, so a `wait` for the end does not answer
/// with the turn before it (the `send --no-wait` then `wait` of a queued prompt printed the
/// previous turn's reply). A held prompt (a failed turn holds the queue) brings no turn by itself.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_queued_behind_the_ending_turn_is_work_coming() {
    let (hub, s) = chat().await;
    let run = |prompt_id: &str, text: &str| {
        let opts =
            PromptOptions { prompt_id: Some(prompt_id.to_owned()), ..PromptOptions::default() };
        let blocks = vec![json!({"type": "text", "text": text})];
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
    };
    let first = run("p-a", "until-cancel");
    let running = async {
        while s.turn().is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(WAIT, running).await.expect("the first turn started");
    let second = run("p-b", "hello");
    let queued = async {
        while s.queued() == 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(WAIT, queued).await.expect("the second prompt queued");
    // Hold the first turn's end once it has taken the turn.
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.finish_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let turn_id = s.turn().unwrap().turn_id;
    hub.cancel_turn(&s, &turn_id).await;
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "the end took the turn");
    assert!(hub.work_coming(&s.id), "the queued prompt's turn is still coming");
    let _ = release.send(());
    let _ = tokio::time::timeout(WAIT, first).await.unwrap().unwrap();
    let done = tokio::time::timeout(WAIT, second).await.unwrap().unwrap().unwrap();
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    assert!(!hub.work_coming(&s.id), "nothing more comes once it ran");
}
