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

/// A forced compaction Stop can finish while its session-wide cancel is still waiting
/// for writer capacity. Continue may start a logical turn, but its prompt must reach the
/// harness after that cancel, never before it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_delayed_compaction_cancel_cannot_cancel_the_next_turn() {
    let (hub, s) = chat(&["FAKE_RESET_CANCEL_ON_PROMPT=1"], false).await;
    let mut events = hub.subscribe();
    let running = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move {
            hub.prompt(&s, vec![json!({"type": "text", "text": "deaf-to-cancel"})], "test", false)
                .await
        })
    };
    tokio::time::timeout(WAIT, async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.msg["params"]["update"]["content"]["text"] == "running" {
                break;
            }
        }
    })
    .await
    .expect("the first prompt reached the harness");
    s.compacting.store(true, std::sync::atomic::Ordering::SeqCst);
    let old_turn = s.turn().unwrap().turn_id;
    // Simulate an earlier prompt handoff stuck on writer backpressure. Stop must settle
    // without this lock, while reserving its place ahead of the next prompt's write.
    let blocked_writer = s.input_handoff.clone().lock_owned().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.cancel_write_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let cancel = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.cancel(&s).await })
    };
    let result = tokio::time::timeout(Duration::from_secs(2), running)
        .await
        .expect("Stop must settle before its writer is released")
        .unwrap()
        .unwrap();
    assert_eq!(result["_meta"]["acpmux"]["cancelForced"], true);

    let (accepted_tx, accepted) = tokio::sync::oneshot::channel();
    let next = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move {
            let opts = PromptOptions {
                on_accepted: Some(Box::new(move |v| {
                    let _ = accepted_tx.send(v);
                })),
                ..Default::default()
            };
            hub.prompt_with(&s, vec![json!({"type": "text", "text": "slow"})], "test", false, opts)
                .await
        })
    };
    let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert_ne!(accepted["turnId"], old_turn);
    drop(blocked_writer);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    // A hosted adapter can deliver old metadata while Stop still waits on its
    // writer. It must be fenced here, before the adapter receives session/cancel.
    let tap = hub.session_tap(&s);
    let update = |kind, state| {
        Message::notification(
            method::SESSION_UPDATE,
            json!({"sessionId": s.meta().agent_session_id, "update": {"sessionUpdate": kind, "state": state}}),
        )
    };
    let before_metadata = s.seq.load(std::sync::atomic::Ordering::SeqCst);
    assert!(tap(crate::agent::Direction::In, &update("compaction", "running"), Some(7001)));
    assert!(tap(crate::agent::Direction::In, &update("compaction", "completed"), Some(7002)));
    assert!(tap(crate::agent::Direction::In, &update("compaction_summary", ""), Some(7003)));
    let metadata = hub.events(&s.id, before_metadata, 100).unwrap();
    assert!(metadata.iter().any(|e| e.kind == "compaction"
        && e.msg.pointer("/params/update/state") == Some(&json!("running"))));
    assert!(
        !metadata.iter().any(|e| e.kind == "compaction_summary"
            || (e.kind == "compaction"
                && e.msg.pointer("/params/update/state") == Some(&json!("completed")))),
        "late metadata escaped before cancel write: {metadata:?}"
    );
    assert!(s.compacting.load(std::sync::atomic::Ordering::SeqCst));
    assert!(
        metadata.iter().any(|e| e.kind == "compaction_metadata_fenced" && e.host_seq == Some(7002))
    );
    assert!(
        metadata.iter().any(|e| e.kind == "compaction_metadata_fenced" && e.host_seq == Some(7003))
    );
    // The translator on the remote host has not received Stop yet. A raw old
    // boundary then result must not reset the controller's current usage.
    let remote = crate::claude_stdio::Translator::new(
        s.meta().agent_session_id.unwrap(),
        "default",
        "haiku",
        "default",
    );
    s.meta.lock().unwrap().usage = Some(json!({"used": 123, "size": 200000}));
    let boundary = remote.inbound(&json!({"type":"system","subtype":"compact_boundary","compact_metadata":{"post_tokens":10}})).await;
    let result = remote.inbound(&json!({"type":"result","subtype":"success","num_turns":0,"duration_api_ms":0,"modelUsage":{"haiku":{"contextWindow":200000}}})).await;
    assert!(result.iter().any(|m| m.params().and_then(|p| p.pointer("/update/sessionUpdate"))
        == Some(&json!("usage_update"))));
    for (index, msg) in boundary.iter().chain(result.iter()).enumerate() {
        assert!(tap(crate::agent::Direction::In, msg, Some(7010 + index as u64)));
        if msg.method() == Some(method::SESSION_UPDATE) {
            hub.on_update(&s, msg.params(), false);
        }
    }
    assert_eq!(s.meta().usage.unwrap()["used"], 123, "late boundary-derived usage escaped");
    let records = hub.events(&s.id, before_metadata, 100).unwrap();
    assert!(
        !records.iter().any(|e| e.kind == "usage_update"
            && e.msg.pointer("/params/update/used") == Some(&json!(10)))
    );
    // A real API message still refreshes usage after the fence.
    let genuine = remote.inbound(&json!({"type":"stream_event","event":{"type":"message_delta","usage":{"input_tokens":250,"output_tokens":2}}})).await;
    for msg in &genuine {
        assert!(tap(crate::agent::Direction::In, msg, Some(7020)));
        hub.on_update(&s, msg.params(), false);
    }
    assert_eq!(s.meta().usage.unwrap()["used"], 250);
    // Give the unfixed path time to deliver the new prompt before releasing the delayed
    // cancel. With ordering in place this event cannot arrive until release.
    let _ = tokio::time::timeout(Duration::from_millis(200), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.msg["params"]["update"]["content"]["text"] == "tick0 " {
                break;
            }
        }
    })
    .await;
    release.send(()).unwrap();
    tokio::time::timeout(WAIT, cancel).await.unwrap().unwrap().unwrap();
    let result = tokio::time::timeout(WAIT, next).await.unwrap().unwrap().unwrap();
    assert_eq!(result["stopReason"], "end_turn", "the old cancel reached the new turn: {result}");
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let cancel = events.iter().find(|e| e.dir == "out" && e.kind == "session/cancel").unwrap();
    let next = events
        .iter()
        .find(|e| {
            e.dir == "out"
                && e.kind == "session/prompt"
                && e.msg["params"]["prompt"].to_string().contains("slow")
        })
        .unwrap();
    assert!(cancel.seq < next.seq, "the new prompt overtook the old cancel");
}

/// Queue one prompt and wait for its durable admission, not a timer or queue-length poll.
async fn queued_prompt(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    text: &str,
    interrupt: bool,
) -> (String, tokio::task::JoinHandle<Result<Value, RpcError>>) {
    let (accepted_tx, accepted) = tokio::sync::oneshot::channel();
    let (hub, session, text) = (hub.clone(), session.clone(), text.to_owned());
    let result = tokio::spawn(async move {
        let opts = PromptOptions {
            interrupt,
            on_accepted: Some(Box::new(move |value| {
                let _ = accepted_tx.send(value);
            })),
            ..Default::default()
        };
        hub.prompt_with(&session, vec![json!({"type": "text", "text": text})], "test", false, opts)
            .await
    });
    let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert_eq!(accepted["queued"], true);
    (accepted["promptId"].as_str().unwrap().to_owned(), result)
}

/// A compaction Stop withdraws pending work. Interrupt is different: only its explicit
/// replacement survives, whether selected through queue_edit or submitted as an interrupt.
async fn compaction_queue_stop(interrupt: Option<bool>) {
    let (hub, s) = chat(&["FAKE_RESET_CANCEL_ON_PROMPT=1"], false).await;
    let mut events = hub.subscribe();
    let running = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move {
            hub.prompt(&s, vec![json!({"type": "text", "text": "deaf-to-cancel"})], "test", false)
                .await
        })
    };
    tokio::time::timeout(WAIT, async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.msg["params"]["update"]["content"]["text"] == "running" {
                break;
            }
        }
    })
    .await
    .unwrap();
    s.compacting.store(true, std::sync::atomic::Ordering::SeqCst);
    let (promoted_id, promoted) = queued_prompt(&hub, &s, "previously promoted", false).await;
    assert!(hub.put_next(&s, &promoted_id, None).unwrap());
    let replacement = match interrupt {
        Some(submit_interrupt) => {
            let (id, answer) = queued_prompt(&hub, &s, "slow", submit_interrupt).await;
            if !submit_interrupt {
                let edited = hub
                    .queue_edit(
                        &s,
                        &json!({"promptId": id, "op": "interrupt"}),
                        Control::Local,
                        false,
                        None,
                    )
                    .await
                    .unwrap();
                assert_eq!(edited["sent"], "interrupt");
            }
            Some(answer)
        }
        None => {
            hub.cancel(&s).await.unwrap();
            None
        }
    };
    let stopped = tokio::time::timeout(Duration::from_secs(2), running)
        .await
        .expect("compaction Stop settles promptly")
        .unwrap()
        .unwrap();
    assert_eq!(stopped["_meta"]["acpmux"]["cancelForced"], true);
    let withdrawn = tokio::time::timeout(WAIT, promoted).await.unwrap().unwrap().unwrap();
    assert_eq!(withdrawn["_meta"]["acpmux"]["withdrawn"], true);
    assert_eq!(written(&hub, &s, "previously promoted"), 0);
    if let Some(replacement) = replacement {
        let answer = tokio::time::timeout(WAIT, replacement).await.unwrap().unwrap().unwrap();
        assert_eq!(answer["stopReason"], "end_turn");
        assert_eq!(written(&hub, &s, "slow"), 1);
    }
    assert!(s.queue().is_empty());
    assert!(s.turn().is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn compaction_stop_withdraws_a_previously_promoted_prompt() {
    compaction_queue_stop(None).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn compaction_interrupt_preserves_only_its_replacement_prompt() {
    compaction_queue_stop(Some(true)).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn compaction_queue_interrupt_preserves_only_its_replacement_prompt() {
    compaction_queue_stop(Some(false)).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_delayed_remote_floor_cancel_cannot_cancel_the_next_turn() {
    let (hub, s) = chat(&["FAKE_RESET_CANCEL_ON_PROMPT=1"], false).await;
    let running = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move {
            hub.prompt(&s, vec![json!({"type": "text", "text": "until-cancel"})], "test", false)
                .await
        })
    };
    let started = async {
        while s.meta().status != SessionStatus::Running {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, started).await.expect("the first turn runs");
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.cancel_write_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    hub.remote_floor_cancel(&s, "test.delayed");
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    let next = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move {
            hub.prompt(&s, vec![json!({"type": "text", "text": "slow"})], "test", false).await
        })
    };
    tokio::time::sleep(Duration::from_millis(200)).await;
    release.send(()).unwrap();
    let _ = tokio::time::timeout(WAIT, running).await.unwrap();
    let result = tokio::time::timeout(WAIT, next).await.unwrap().unwrap().unwrap();
    assert_eq!(
        result["stopReason"], "end_turn",
        "the delayed policy cancel hit the next turn: {result}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_during_prompt_startup_cancels_only_that_prompt() {
    let (hub, s) = chat(&["FAKE_RESET_CANCEL_ON_PROMPT=1"], false).await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let starting = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move {
            hub.prompt(&s, vec![json!({"type": "text", "text": "starting prompt"})], "test", false)
                .await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "Stop arrives before the turn is installed");
    hub.cancel(&s).await.unwrap();
    release.send(()).unwrap();
    stopped(tokio::time::timeout(WAIT, starting).await.unwrap().unwrap());
    assert_eq!(written(&hub, &s, "starting prompt"), 0);

    // Stop applies to work already admitted, not the next explicit user request.
    let next = hub.prompt(&s, vec![json!({"type": "text", "text": "slow"})], "test", false);
    let result = tokio::time::timeout(WAIT, next).await.unwrap().unwrap();
    assert_eq!(result["stopReason"], "end_turn");
    assert_eq!(written(&hub, &s, "slow"), 1);
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
    // A sign-in failure fails over; a usage limit waits for its reset (`auto_resume.rs`).
    let (hub, s) = chat(&["FAKE_AUTH_FAIL=1"], true).await;
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
