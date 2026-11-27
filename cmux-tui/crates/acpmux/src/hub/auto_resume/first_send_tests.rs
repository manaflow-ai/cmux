//! A chat's first send that a revoked OAuth token failed goes again once (`first_send.rs`),
//! on the stand-in agent (`tests/fake_agent.py`) with its prompt handler wrapped: a prompt
//! `revoked-once: X` fails with Claude's "OAuth token revoked" the first time this test's agent
//! sees one, `revoked-always: X` every time.

use super::FIRST_SEND_RETRY_MS;
use crate::config::{Config, StoreMode};
use crate::hub::{Hub, NewRequest, PromptOptions, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(20);
const REVOKED: &str = "Failed to authenticate: OAuth token revoked";

/// The stand-in agent, its prompts wrapped as the module doc says; `argv[2]` is the file that
/// says a `revoked-once` prompt already failed.
const WRAPPER: &str = r#"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fake_agent", sys.argv[1])
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)
inner = fake.handle_prompt
def handle(rid, params):
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    once = text.startswith("revoked-once:") and not os.path.exists(sys.argv[2])
    if once or text.startswith("revoked-always:"):
        open(sys.argv[2], "a").close()
        fake.send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": "Failed to authenticate: OAuth token revoked"}})
        return
    inner(rid, params)
fake.handle_prompt = handle
fake.main()
"#;

async fn chat(name: &str) -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let dir = std::env::temp_dir().join(format!("acpmux-first-send-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let marker = dir.join("revoked-once").display().to_string();
    let argv = json!(["python3", "-c", WRAPPER, fake, marker]);
    let cfg = json!({"harnesses": {"fake": {"argv": argv}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(dir), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

async fn prompt(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    text: &str,
    prompt_id: &str,
) -> Result<Value, RpcError> {
    let blocks = vec![json!({"type": "text", "text": text})];
    let opts = PromptOptions { prompt_id: Some(prompt_id.to_owned()), ..Default::default() };
    hub.prompt_with(s, blocks, "test", false, opts).await
}

fn records(hub: &Hub, s: &Session, kind: &str) -> Vec<Value> {
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    events.into_iter().filter(|e| e.kind == kind).map(|e| e.msg).collect()
}

async fn until(what: &str, check: impl Fn() -> bool) {
    let wait = async {
        while !check() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, wait).await.unwrap_or_else(|_| panic!("timed out: {what}"));
}

/// Longer than the retry's wait: a retry that was coming has started by then.
async fn past_the_wait() {
    tokio::time::sleep(Duration::from_millis(FIRST_SEND_RETRY_MS + 1_500)).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_first_send_a_revoked_token_failed_goes_again_once_and_completes() {
    let (hub, s) = chat("once").await;
    let e = prompt(&hub, &s, "revoked-once: hello", "p-first").await.unwrap_err();
    assert!(e.message.contains("OAuth token revoked"), "{}", e.message);
    let failed = Instant::now();
    // Its retry is being decided while it waits: a wait holds its answer for it.
    let row = hub.session_summary(&s);
    assert_eq!(row["retryDeciding"], true, "{row}");
    let scheduled = records(&hub, &s, "first_send_retry");
    assert_eq!(scheduled.len(), 1, "{scheduled:?}");
    assert_eq!(scheduled[0]["promptId"], "p-first");
    assert_eq!(scheduled[0]["delayMs"], FIRST_SEND_RETRY_MS);

    until("the retry's turn ends", || records(&hub, &s, "turn_result").len() == 2).await;
    let started = records(&hub, &s, "turn_started");
    assert_eq!(started.len(), 2, "{started:?}");
    assert!(failed.elapsed() >= Duration::from_millis(FIRST_SEND_RETRY_MS / 2), "it waited");
    let messages = records(&hub, &s, "user_message");
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert_eq!(messages[1]["promptId"], "p-first~resume-1");
    assert_eq!(messages[1]["text"], "revoked-once: hello", "the same prompt");
    let provenance = &messages[1]["_meta"]["provenance"];
    assert_eq!(provenance["kind"], "auto_resume", "{provenance}");
    assert_eq!(provenance["attempt"], 1, "{provenance}");
    assert_eq!(provenance["turnId"], messages[0]["turnId"], "{provenance}");
    assert!(provenance.get("manual").is_none(), "{provenance}");
    let row = hub.session_summary(&s);
    assert_eq!(row["lastTurn"]["status"], "completed", "{row}");
    assert!(row.get("retryDeciding").is_none(), "{row}");

    past_the_wait().await;
    assert_eq!(records(&hub, &s, "user_message").len(), 2, "sent again once");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_retried_first_send_that_fails_again_is_not_retried_again() {
    let (hub, s) = chat("again").await;
    prompt(&hub, &s, "revoked-always: hello", "p-again").await.unwrap_err();
    until("the retry's turn ends", || records(&hub, &s, "turn_result").len() == 2).await;
    past_the_wait().await;
    let messages = records(&hub, &s, "user_message");
    assert_eq!(messages.len(), 2, "one retry, never a loop: {messages:?}");
    assert_eq!(records(&hub, &s, "first_send_retry").len(), 1);
    let row = hub.session_summary(&s);
    assert_eq!(row["lastTurn"]["status"], "failed", "{row}");
    assert!(row["lastTurn"]["errorText"].as_str().unwrap_or_default().contains(REVOKED), "{row}");
    assert!(row.get("retryDeciding").is_none(), "{row}");
    // The decision is heard: no retry for the retry.
    let settled = records(&hub, &s, "auto_resume_settled");
    assert!(
        settled.iter().any(|m| m["promptId"] == "p-again~resume-1" && m["why"] == "not_retried"),
        "{settled:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_later_turn_a_revoked_token_failed_is_not_retried() {
    let (hub, s) = chat("later").await;
    prompt(&hub, &s, "hello", "p-1").await.unwrap();
    prompt(&hub, &s, "revoked-always: then", "p-2").await.unwrap_err();
    past_the_wait().await;
    assert_eq!(records(&hub, &s, "user_message").len(), 2, "not sent again");
    assert!(records(&hub, &s, "first_send_retry").is_empty());
    let settled = records(&hub, &s, "auto_resume_settled");
    assert!(settled.iter().any(|m| m["promptId"] == "p-2"), "{settled:?}");
    assert_eq!(hub.session_summary(&s)["lastTurn"]["status"], "failed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stop_during_the_wait_keeps_the_first_send_from_going_again() {
    let (hub, s) = chat("stop").await;
    prompt(&hub, &s, "revoked-once: hello", "p-stop").await.unwrap_err();
    let _ = hub.cancel(&s).await;
    past_the_wait().await;
    assert_eq!(records(&hub, &s, "user_message").len(), 1, "Stop held it");
    let skipped = records(&hub, &s, "auto_resume_skipped");
    assert!(
        skipped.iter().any(|m| m["firstSend"] == true && m["skipped"] == "stopped"),
        "{skipped:?}"
    );
    assert_eq!(hub.session_summary(&s)["lastTurn"]["status"], "failed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_prompt_during_the_wait_takes_the_chat_instead() {
    let (hub, s) = chat("prompt").await;
    prompt(&hub, &s, "revoked-once: hello", "p-old").await.unwrap_err();
    prompt(&hub, &s, "something else", "p-new").await.unwrap();
    past_the_wait().await;
    let messages = records(&hub, &s, "user_message");
    let ids: Vec<_> = messages.iter().map(|m| m["promptId"].clone()).collect();
    assert_eq!(ids, [json!("p-old"), json!("p-new")], "not sent again");
    let skipped = records(&hub, &s, "auto_resume_skipped");
    assert!(
        skipped.iter().any(|m| m["firstSend"] == true && m["skipped"] == "superseded"),
        "{skipped:?}"
    );
}
