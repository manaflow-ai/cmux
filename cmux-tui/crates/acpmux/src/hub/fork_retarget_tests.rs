//! A fork onto another harness (`fork.rs` `Retarget`; Leo 2026-11-11: "if i switch to a
//! different model in a chat, it should just be able to seamlesly within the same pane do
//! stuff"): the fork runs the picked harness, shows the chat's history, and its first prompt
//! gives the new agent the conversation. Switching back is another such fork.

use super::*;
use crate::hub::NewRequest;

fn hub() -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {
                        "fake": {"argv": ["python3", fake]},
                        "other": {"argv": ["python3", fake], "family": "other"},
                        // Takes its model over ACP and refuses `bad-model`.
                        "picky": {"argv": ["python3", fake], "family": "picky",
                                  "env": {"FAKE_PICKER": "1", "FAKE_REFUSE_ID": "bad-model"}},
                        // Takes its model at spawn, from its defaults' env only.
                        "spawned": {"argv": ["python3", fake], "family": "spawned"}},
                     "defaults": {"spawned": {"env": {"FAKE_MODEL_ARG": "${model}"}}},
                     "defaultHarness": "fake",
                     "titles": {"generate": false}});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn to(harness: &str) -> Retarget {
    Retarget { harness: harness.into(), model: None, remote: false }
}

/// The text the agent answered in `session`'s turns.
fn replies(hub: &Hub, session: &Session) -> String {
    hub.events(&session.id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect()
}

fn prompts(hub: &Hub, session: &Session) -> Vec<String> {
    hub.events(&session.id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "user_message")
        .filter_map(|e| e.msg.get("text").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fork_onto_another_harness_carries_the_conversation_and_switches_back() {
    let hub = hub();
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"PARENT-WORDS"})], "test", false)
        .await
        .unwrap();

    let fork = hub
        .fork_to(&parent, to("other"), None, None, Default::default(), None, true)
        .await
        .unwrap();
    let meta = fork.meta();
    assert_eq!(meta.harness, "other");
    assert_eq!(meta.family.as_deref(), Some("other"));
    assert_eq!(meta.parent_id.as_deref(), Some(parent.id.as_str()));
    // Started before the reply, on its own agent session of the new harness.
    assert!(meta.agent_session_id.is_some());
    assert_eq!(meta.agent_session_family.as_deref(), Some("non-claude"));
    // The fork shows the chat's history.
    assert_eq!(prompts(&hub, &fork), vec!["PARENT-WORDS".to_owned()]);
    // Its first prompt gives the new agent the conversation.
    hub.prompt(&fork, vec![json!({"type":"text", "text":"FORK-WORDS"})], "test", false)
        .await
        .unwrap();
    let said = replies(&hub, &fork);
    assert!(said.contains("restored_transcript"), "{said}");
    // Briefed that it was forked from the chat, and whose the earlier replies are (Leo,
    // 2026-11-11: "you were forked from this chat").
    let from = format!("forked from fake chat {} ({})", parent.meta().name, parent.id);
    assert!(said.contains(&from), "{said}");
    assert!(said.contains("the earlier replies are fake's, not yours"), "{said}");
    assert!(said.contains("PARENT-WORDS"), "{said}");
    assert!(said.contains("FORK-WORDS"), "{said}");
    // The parent is untouched.
    assert_eq!(parent.meta().harness, "fake");

    // Switching back: another fork, onto the first harness, with both turns.
    let back =
        hub.fork_to(&fork, to("fake"), None, None, Default::default(), None, true).await.unwrap();
    assert_eq!(back.meta().harness, "fake");
    assert_eq!(prompts(&hub, &back), vec!["PARENT-WORDS".to_owned(), "FORK-WORDS".to_owned()]);
    hub.prompt(&back, vec![json!({"type":"text", "text":"BACK-WORDS"})], "test", false)
        .await
        .unwrap();
    let said = replies(&hub, &back);
    assert!(said.contains("PARENT-WORDS") && said.contains("FORK-WORDS"), "{said}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fork_onto_another_harness_works_before_the_chat_has_a_turn() {
    let hub = hub();
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    let fork = hub
        .fork_to(&parent, to("other"), None, None, Default::default(), None, true)
        .await
        .unwrap();
    assert_eq!(fork.meta().harness, "other");
    hub.prompt(&fork, vec![json!({"type":"text", "text":"FIRST"})], "test", false).await.unwrap();
    assert!(replies(&hub, &fork).contains("FIRST"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fork_onto_its_own_harness_is_an_ordinary_fork() {
    let hub = hub();
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"ONE"})], "test", false).await.unwrap();
    let fork =
        hub.fork_to(&parent, to("fake"), None, None, Default::default(), None, true).await.unwrap();
    assert_eq!(fork.meta().harness, "fake");
    assert_eq!(fork.meta().parent_id.as_deref(), Some(parent.id.as_str()));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fork_onto_an_unknown_harness_is_refused() {
    let hub = hub();
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"ONE"})], "test", false).await.unwrap();
    let refused = hub
        .fork_to(&parent, to("nope"), None, None, Default::default(), None, true)
        .await
        .err()
        .expect("refused");
    assert_eq!(refused.code, -32602, "{}", refused.message);
}

fn to_model(harness: &str, model: &str) -> Retarget {
    Retarget { harness: harness.into(), model: Some(model.into()), remote: false }
}

/// `${model}` in the target's defaults' env makes the model a spawn parameter, as `session/new`
/// decides it: the fork's agent starts with it (review of cmux#41030, F1).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_onto_a_harness_whose_defaults_take_the_model_spawns_with_it() {
    let hub = hub();
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    let fork = hub
        .fork_to(&parent, to_model("spawned", "m-1"), None, None, Default::default(), None, true)
        .await
        .unwrap();
    assert_eq!(fork.meta().harness, "spawned");
    assert_eq!(fork.meta().model_request.as_deref(), Some("m-1"));
}

/// A model the switch named that the target refuses fails the switch, and no fork is left: the
/// next prompt would otherwise run the harness's own default (review of cmux#41030, F2). A model
/// it takes is set before the reply.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_whose_named_model_the_harness_refuses_fails_and_leaves_no_fork() {
    let hub = hub();
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    let before = hub.sessions().len();
    let refused = hub
        .fork_to(
            &parent,
            to_model("picky", "bad-model"),
            None,
            None,
            Default::default(),
            None,
            true,
        )
        .await
        .err()
        .expect("refused");
    assert!(refused.message.contains("bad-model"), "{}", refused.message);
    let live: Vec<_> = hub
        .sessions()
        .into_iter()
        .filter(|s| s.meta().status != crate::store::SessionStatus::Closed)
        .collect();
    assert!(live.len() <= before, "a refused switch left a fork: {}", live.len());
    let fork = hub
        .fork_to(
            &parent,
            to_model("picky", "good-model"),
            None,
            None,
            Default::default(),
            None,
            true,
        )
        .await
        .unwrap();
    assert_eq!(fork.meta().harness, "picky");
}
