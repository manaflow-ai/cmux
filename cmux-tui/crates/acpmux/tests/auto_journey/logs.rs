//! Prompts sent to a hub, and what a chat's log holds.

use std::sync::Arc;
use std::time::{Duration, Instant};

use acpmux::hub::{Hub, PromptOptions, Session};
use acpmux::store::EventRecord;
use serde_json::json;

/// How long a wait may take before the test fails.
pub const DEADLINE: Duration = Duration::from_secs(60);

/// Waits until `ready` holds.
pub async fn until(what: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + DEADLINE;
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting for: {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Sends `text` to the chat under `prompt_id` and returns once the hub has recorded it (it
/// started a turn or waits in the queue). The turn runs on by itself.
pub async fn send(hub: &Arc<Hub>, session: &Arc<Session>, prompt_id: &str, text: &str) {
    let (recorded_tx, recorded) = tokio::sync::oneshot::channel();
    let options = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        on_accepted: Some(Box::new(move |_| {
            let _ = recorded_tx.send(());
        })),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({ "type": "text", "text": text })];
    let (hub, session) = (Arc::clone(hub), Arc::clone(session));
    tokio::spawn(async move { hub.prompt_with(&session, blocks, "test", false, options).await });
    let in_time = tokio::time::timeout(DEADLINE, recorded).await;
    in_time.expect("the prompt is recorded in time").expect("the hub took the prompt");
}

/// The chat's whole log; empty while the hub does not have the chat.
pub fn log_of(hub: &Arc<Hub>, id: &str) -> Vec<EventRecord> {
    hub.events(id, 0, 100_000).unwrap_or_default()
}

/// The chat's log once `done` holds of it.
pub async fn log_when(
    hub: &Arc<Hub>,
    id: &str,
    what: &str,
    done: impl Fn(&[EventRecord]) -> bool,
) -> Vec<EventRecord> {
    let deadline = Instant::now() + DEADLINE;
    loop {
        let log = log_of(hub, id);
        if done(&log) {
            return log;
        }
        if Instant::now() >= deadline {
            let kinds: Vec<String> =
                log.iter().map(|event| format!("{}:{}", event.kind, event.msg)).collect();
            panic!("{what} did not happen; the log: {kinds:#?}");
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// The texts of the prompts in a log, in order.
pub fn prompts(log: &[EventRecord]) -> Vec<String> {
    let texts = log.iter().filter(|event| event.kind == "user_message");
    texts.filter_map(|event| event.msg["text"].as_str().map(str::to_owned)).collect()
}

/// How often `text` is a prompt of the log.
pub fn times(log: &[EventRecord], text: &str) -> usize {
    prompts(log).iter().filter(|sent| *sent == text).count()
}

/// The log's records through `seq`, each as its number and kind.
pub fn through(log: &[EventRecord], seq: u64) -> Vec<(u64, String)> {
    let kept = log.iter().filter(|event| event.seq <= seq);
    kept.map(|event| (event.seq, event.kind.clone())).collect()
}
