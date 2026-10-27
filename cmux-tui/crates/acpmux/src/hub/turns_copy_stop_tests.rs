//! A Stop that comes while a prompt's model-sized copies are made (`model_copies.rs`,
//! `turns::agent_blocks`) is never overtaken: the prompt is not written to the agent, at a
//! turn's start, for a steer into a running turn, or on the fallback after a failover.

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub with one open chat on a stand-in agent run with `env`, that fails over to itself
/// (`FAKE_FALLBACK=1`) when `fails_over`.
async fn chat(env: &[&str], fails_over: bool) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut argv = vec!["/usr/bin/env"];
    argv.extend(env);
    argv.extend(["python3", fake]);
    let mut cfg = json!({"harnesses": {"fake": {"argv": argv}}, "defaultHarness": "fake"});
    if fails_over {
        cfg["harnesses"]["fake"]["fallback"] = json!("fake-fallback");
        let fallback = ["/usr/bin/env", "FAKE_FALLBACK=1", "python3", fake];
        cfg["harnesses"]["fake-fallback"] = json!({"argv": fallback});
    }
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// Arms the pause in `agent_blocks`: it fires `arrived` and waits for `release`.
fn arm(hub: &Hub) -> (tokio::sync::oneshot::Receiver<()>, tokio::sync::oneshot::Sender<()>) {
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.copy_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    (arrived, release)
}

/// How many `session/prompt` requests holding `text` were written to the agent.
fn written(hub: &Hub, session: &Session, text: &str) -> usize {
    let records = hub.events(&session.id, 0, 100_000).unwrap();
    let prompts = records.iter().filter(|r| r.dir == "out" && r.kind == "session/prompt");
    prompts.filter(|r| r.msg["params"]["prompt"].to_string().contains(text)).count()
}

fn stopped(r: Result<Value, RpcError>) {
    let e = r.expect_err("the prompt ran after the Stop");
    assert_eq!(e.data.as_ref().map(|d| d["reason"].clone()), Some(json!("stopped")), "{e:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_while_a_turns_copies_are_made_keeps_its_prompt_from_the_agent() {
    let (hub, s) = chat(&[], false).await;
    let (arrived, release) = arm(&hub);
    let run = {
        let (hub, s) = (hub.clone(), s.clone());
        let text = vec![json!({"type": "text", "text": "hello there"})];
        tokio::spawn(
            async move { hub.prompt_with(&s, text, "test", false, Default::default()).await },
        )
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the copies are made").unwrap();
    let _ = hub.cancel(&s).await;
    let _ = release.send(());
    stopped(tokio::time::timeout(WAIT, run).await.expect("the prompt answers").unwrap());
    assert_eq!(written(&hub, &s, "hello there"), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_while_a_steers_copies_are_made_keeps_it_from_the_agent_and_starts_no_turn() {
    let (hub, s) = chat(&["FAKE_CLAUDE_STEER=1"], false).await;
    let running = {
        let (hub, s) = (hub.clone(), s.clone());
        let text = vec![json!({"type": "text", "text": "until-cancel"})];
        tokio::spawn(
            async move { hub.prompt_with(&s, text, "test", false, Default::default()).await },
        )
    };
    let started = async {
        while s.meta().status != SessionStatus::Running {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, started).await.expect("the turn runs");
    let (arrived, release) = arm(&hub);
    let steer = {
        let (hub, s) = (hub.clone(), s.clone());
        let text = vec![json!({"type": "text", "text": "steer this in"})];
        tokio::spawn(
            async move { hub.prompt_with(&s, text, "test", true, Default::default()).await },
        )
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the copies are made").unwrap();
    let _ = hub.cancel(&s).await;
    let _ = release.send(());
    stopped(tokio::time::timeout(WAIT, steer).await.expect("the steer answers").unwrap());
    let _ = tokio::time::timeout(WAIT, running).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(written(&hub, &s, "steer this in"), 0, "the steer reached the agent");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_while_a_failovers_copies_are_made_keeps_the_prompt_from_the_fallback() {
    let (hub, s) = chat(&[], true).await;
    let (arrived, release) = arm(&hub);
    let run = {
        let (hub, s) = (hub.clone(), s.clone());
        let text = vec![json!({"type": "text", "text": "slow-limit"})];
        tokio::spawn(
            async move { hub.prompt_with(&s, text, "test", false, Default::default()).await },
        )
    };
    // The first agent's copies: let them through, and pause at the fallback's.
    tokio::time::timeout(WAIT, arrived).await.expect("the copies are made").unwrap();
    let (arrived, release_fallback) = arm(&hub);
    let _ = release.send(());
    tokio::time::timeout(WAIT, arrived).await.expect("it fails over").unwrap();
    let _ = hub.cancel(&s).await;
    let _ = release_fallback.send(());
    stopped(tokio::time::timeout(WAIT, run).await.expect("the prompt answers").unwrap());
    assert_eq!(written(&hub, &s, "slow-limit"), 1, "the fallback got the prompt after the Stop");
}
