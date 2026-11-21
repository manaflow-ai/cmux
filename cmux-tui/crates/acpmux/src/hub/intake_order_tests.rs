//! A chat's prompts take their place in the order they were sent (`intake_order.rs`): a prompt
//! whose reading is slow (its attachment) still goes before the plain one sent after it.

use super::intake_order::{BOUND, IntakeOrder, scope};
use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub with one open chat on the stand-in agent, its store in memory.
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

/// The person's prompt, served as a `session/prompt` request numbered `ticket` is: after
/// `read` (its uploads read, its chat's log) it goes to `prompt_with`.
fn sent(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    ticket: Arc<super::intake_order::Ticket>,
    read: impl std::future::Future<Output = ()> + Send + 'static,
    prompt_id: &str,
    accepted: tokio::sync::oneshot::Sender<Value>,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let opts = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        on_accepted: Some(Box::new(move |v| {
            let _ = accepted.send(v);
        })),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": prompt_id})];
    let (hub, s) = (hub.clone(), s.clone());
    tokio::spawn(scope(Some(ticket), async move {
        read.await;
        hub.prompt_with(&s, blocks, "test", false, opts).await
    }))
}

fn user_messages(hub: &Hub, s: &Session) -> Vec<Value> {
    hub.events(&s.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .map(|r| r.msg["promptId"].clone())
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_slow_attachment_prompt_still_goes_before_the_plain_one_sent_after_it() {
    let (hub, s) = chat().await;
    // Read in this order by the connection: the prompt with an attachment, then a plain one.
    let attach_ticket = hub.intake_order.take(&s.id);
    let plain_ticket = hub.intake_order.take(&s.id);
    // The attachment is still being read when the plain prompt is ready.
    let (uploaded, upload_read) = tokio::sync::oneshot::channel::<()>();
    let (attach_tx, attach_accepted) = tokio::sync::oneshot::channel();
    let attach = sent(
        &hub,
        &s,
        attach_ticket,
        async move {
            let _ = upload_read.await;
        },
        "with-attachment",
        attach_tx,
    );
    let (plain_tx, mut plain_accepted) = tokio::sync::oneshot::channel();
    let plain = sent(&hub, &s, plain_ticket, async {}, "plain", plain_tx);

    // The plain prompt waits: it takes no turn and no place in the queue before the first.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(plain_accepted.try_recv().is_err(), "the later prompt waits for the earlier one");
    assert!(s.turn().is_none(), "no turn started ahead of the earlier prompt");

    uploaded.send(()).unwrap();
    let first = tokio::time::timeout(WAIT, attach_accepted).await.unwrap().unwrap();
    assert_eq!(first["state"], "started", "{first}");
    let second = tokio::time::timeout(WAIT, plain_accepted).await.unwrap().unwrap();
    assert_eq!((&second["queued"], &second["position"]), (&json!(true), &json!(1)), "{second}");
    for done in [attach, plain] {
        let r = tokio::time::timeout(WAIT, done).await.unwrap().unwrap().unwrap();
        assert_eq!(r["stopReason"], "end_turn", "{r}");
    }
    assert_eq!(user_messages(&hub, &s), [json!("with-attachment"), json!("plain")]);
    assert_eq!(hub.intake_order.open_count(), 0, "every place was freed");
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_earlier_prompt_refused_while_reading_holds_no_later_one() {
    let (hub, s) = chat().await;
    let refused = hub.intake_order.take(&s.id);
    let plain_ticket = hub.intake_order.take(&s.id);
    let (plain_tx, plain_accepted) = tokio::sync::oneshot::channel();
    let plain = sent(&hub, &s, plain_ticket, async {}, "after-refused", plain_tx);
    tokio::time::sleep(Duration::from_millis(200)).await;
    // Its request ends (a bad upload, a refusal) before it reaches the chat.
    drop(refused);
    let accepted = tokio::time::timeout(BOUND / 2, plain_accepted)
        .await
        .expect("accepted once the earlier request ended, not at the bound")
        .unwrap();
    assert_eq!(accepted["state"], "started", "{accepted}");
    let r = tokio::time::timeout(WAIT, plain).await.unwrap().unwrap().unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    hub.shutdown_all().await;
}

#[tokio::test(start_paused = true)]
async fn a_prompt_waits_only_for_earlier_ones_to_its_own_chat_and_at_most_the_bound() {
    let order = Arc::new(IntakeOrder::default());
    let first = order.take("a");
    let other_chat = order.take("b");
    let second = order.take("a");
    // Another chat's prompt waits for none of this chat's.
    assert!(other_chat.wait_turn().await);
    // The first frees the second as it takes its place.
    let waiting = tokio::spawn({
        let second = second.clone();
        async move { second.wait_turn().await }
    });
    tokio::task::yield_now().await;
    assert!(!waiting.is_finished());
    first.release();
    assert!(waiting.await.unwrap(), "freed, not timed out");
    // One that never takes its place holds the next one only for the bound.
    let hung = order.take("a");
    let third = order.take("a");
    let started = tokio::time::Instant::now();
    assert!(!third.wait_turn().await, "the bound ended the wait");
    assert!(started.elapsed() >= BOUND);
    drop((hung, second, third, other_chat));
    assert_eq!(order.open_count(), 0);
}
