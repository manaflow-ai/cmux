//! Model names read as their catalog ids at every entry point (`hub/model_alias.rs`), and a turn
//! failed on its model retried once under its id (`model_reroute.rs`), on the stand-in agent
//! (`tests/fake_agent.py`) wrapped as Claude Code behaves: it takes its model at spawn
//! (`${model}` in its argv) and fails every prompt on a model it does not know with Claude Code's
//! `unrecognized_model` text. It knows only the catalog's own ids.

use crate::config::{Config, StoreMode};
use crate::hub::{Hub, NewRequest, PromptOptions, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// The stand-in agent; `argv[2]` is the model it was started on.
const WRAPPER: &str = r#"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fake_agent", sys.argv[1])
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)
inner = fake.handle_prompt
KNOWN = {"claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5"}
def handle(rid, params):
    model = sys.argv[2]
    if model not in KNOWN:
        msg = ("[claude-code:unrecognized_model] There's an issue with the selected model (%s). "
               "It may not exist or you may not have access to it. Run /model to pick a different model." % model)
        fake.send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32603, "message": msg}})
        return
    inner(rid, params)
fake.handle_prompt = handle
fake.main()
"#;

/// A hub whose harness `harness` runs the wrapped stand-in. Named `claude`, the catalog's
/// Claude Code entry is its; any other name has none (a harness the catalog does not know).
fn hub(harness: &str, name: &str) -> (Arc<Hub>, std::path::PathBuf) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let dir =
        std::env::temp_dir().join(format!("acpmux-model-reroute-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let argv = json!(["python3", "-c", WRAPPER, fake, "${model}"]);
    // Its own family: the wrapper's text would read as another harness's (`derive_family`).
    let cfg = json!({"harnesses": {harness: {"argv": argv, "family": harness}}, "defaultHarness": harness});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    (Hub::new(cfg, store), dir)
}

async fn chat(harness: &str, name: &str, model: &str) -> (Arc<Hub>, Arc<Session>) {
    let (hub, dir) = hub(harness, name);
    let req = NewRequest { cwd: Some(dir), model: Some(model.into()), ..NewRequest::default() };
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

/// Leo, 2026-11-22: 16 lanes started on `fable-5.2` died on their first turn. A chat on a model
/// the catalog folds (here on a harness with no catalog entry, so nothing rewrote it at the
/// start) fails its turn on `unrecognized_model`, is set to `claude-fable-5-2` and its turn goes
/// again once, and completes; one line says so in the transcript.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_turn_failed_on_its_model_is_rerouted_to_the_catalog_id_and_retried_once() {
    let (hub, s) = chat("fake", "reroute", "fable-5.2").await;
    assert_eq!(s.meta().model_request.as_deref(), Some("fable-5.2"), "no catalog entry: as given");
    let e = prompt(&hub, &s, "hello", "p-model").await.unwrap_err();
    assert!(e.message.contains("unrecognized_model"), "{}", e.message);

    until("the rerouted turn ends", || records(&hub, &s, "turn_result").len() == 2).await;
    let rerouted = records(&hub, &s, "model_reroute");
    assert_eq!(rerouted.len(), 1, "{rerouted:?}");
    assert_eq!(rerouted[0]["from"], "fable-5.2");
    assert_eq!(rerouted[0]["to"], "claude-fable-5-2");
    let line = rerouted[0]["text"].as_str().unwrap_or_default();
    assert!(line.starts_with("model-reroute: "), "{line}");
    assert!(line.ends_with(" fable-5.2 -> claude-fable-5-2, turn retried"), "{line}");
    let messages = records(&hub, &s, "user_message");
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert_eq!(messages[1]["promptId"], "p-model~resume-1");
    assert_eq!(messages[1]["text"], "hello", "the same prompt");
    assert_eq!(s.meta().model_request.as_deref(), Some("claude-fable-5-2"), "the switch stays");
    let row = hub.session_summary(&s);
    assert_eq!(row["lastTurn"]["status"], "completed", "{row}");
    assert!(row.get("retryDeciding").is_none(), "{row}");
}

/// A model the catalog does not know is not rerouted: the turn fails once, and its `lastTurn`
/// says why for a sweeper (`errorKind: model.unrecognized`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_model_the_catalog_does_not_know_fails_once_with_its_kind() {
    let (hub, s) = chat("fake", "unknown", "my-proxy-model").await;
    prompt(&hub, &s, "hello", "p-unknown").await.unwrap_err();
    until("the decision is heard", || !records(&hub, &s, "auto_resume_settled").is_empty()).await;
    tokio::time::sleep(Duration::from_millis(super::REROUTE_WAIT_MS + 500)).await;
    assert_eq!(records(&hub, &s, "user_message").len(), 1, "not sent again");
    assert!(records(&hub, &s, "model_reroute").is_empty());
    let row = hub.session_summary(&s);
    assert_eq!(row["lastTurn"]["status"], "failed", "{row}");
    assert_eq!(row["lastTurn"]["errorKind"], "model.unrecognized", "{row}");
    assert!(row.get("retryDeciding").is_none(), "{row}");
}

/// Every entry point on a harness the catalog knows reads the model as its id, and says so:
/// the start (`new -m`, ACP and MCP starts all reach `new_session`), `session/set_model` (the
/// CLI's `session set model=`, whose reply carries `modelRewrite` for its line) and a listed
/// name stays as written. An ambiguous name is refused with its choices.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_entry_point_reads_a_model_as_its_catalog_id() {
    let (hub, s) = chat("claude", "entry", "fable-5.2").await;
    assert_eq!(s.meta().model_request.as_deref(), Some("claude-fable-5-2"));
    let rewrites = records(&hub, &s, "model_rewrite");
    assert_eq!(rewrites.len(), 1, "{rewrites:?}");
    assert_eq!(rewrites[0]["text"], "model fable-5.2 -> claude-fable-5-2");
    assert_eq!(rewrites[0]["at"], "new");
    prompt(&hub, &s, "hello", "p-entry").await.unwrap();

    let reply = hub.client_set_model(&s, "Fable 5.1", false).await.unwrap();
    assert_eq!(reply["modelRewrite"], json!({"from": "Fable 5.1", "to": "claude-fable-5-1"}));
    assert_eq!(s.meta().model_request.as_deref(), Some("claude-fable-5-1"));
    hub.set_model(&s, "opus-5.5").await.unwrap();
    assert_eq!(s.meta().model_request.as_deref(), Some("claude-opus-5-5"));
    let rewrites = records(&hub, &s, "model_rewrite");
    let lines: Vec<&str> = rewrites.iter().filter_map(|r| r["text"].as_str()).collect();
    assert_eq!(
        lines,
        [
            "model fable-5.2 -> claude-fable-5-2",
            "model Fable 5.1 -> claude-fable-5-1",
            "model opus-5.5 -> claude-opus-5-5",
        ]
    );

    hub.set_model(&s, "opus").await.unwrap();
    assert_eq!(s.meta().model_request.as_deref(), Some("opus"), "a listed alias stays");
    assert_eq!(records(&hub, &s, "model_rewrite").len(), 3);

    let e = hub.set_model(&s, "claude").await.unwrap_err();
    let data = e.data.clone().unwrap_or_default();
    assert_eq!(data["reason"], "model.ambiguous", "{e:?}");
    assert!(e.message.contains("claude-fable-5-2"), "{}", e.message);
}
