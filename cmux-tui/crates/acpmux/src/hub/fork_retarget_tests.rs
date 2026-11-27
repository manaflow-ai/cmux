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
                        "other": {"argv": ["python3", fake], "family": "other",
                                  "env": {"FAKE_NEW_MODE": "strict"}},
                        // Takes its model over ACP and refuses `bad-model`.
                        "picky": {"argv": ["python3", fake], "family": "picky",
                                  "env": {"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "1",
                                          "FAKE_REFUSE_ID": "bad-model"}},
                        // Takes its model at spawn, from its defaults' env only.
                        "spawned": {"argv": ["python3", fake], "family": "spawned",
                                    "env": {"FAKE_NEW_MODE": "strict"}},
                        // Takes its model at spawn, as Claude Code does, and lists two.
                        "listing": {"argv": ["python3", fake], "family": "listing",
                                    "env": {"FAKE_MODEL_ARG": "${model}", "FAKE_NEW_MODE": "strict"},
                                    "models": ["haiku", "opus"]}},
                     "defaults": {"spawned": {"env": {"FAKE_MODEL_ARG": "${model}"}}},
                     "webAskingModes": {"fake": ["normal", "strict"],
                                         "other": ["normal", "strict"],
                                         "picky": ["normal", "strict"],
                                         "spawned": ["normal", "strict"],
                                         "listing": ["normal", "strict"]},
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

/// A hub whose `lister` harness lists its models (a `model` option, as Claude Code and OpenCode
/// do) and takes any `set_model`, as Claude Code does; each model set is logged to `calls`.
fn lister_hub(calls: &std::path::Path) -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let lister = json!({"argv": ["python3", fake], "family": "lister",
                        "env": {"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude",
                                "FAKE_PICKER_INITIAL_MODE": "acceptEdits",
                                "FAKE_CALLS": calls.to_str().unwrap()}});
    // `nofork` has no session/fork: its fork is made from acpmux's transcript. `lister2` is
    // another harness of the same family, a switch target with the same modes.
    let mut nofork = lister.clone();
    nofork["env"]["FAKE_NO_FORK"] = json!("1");
    let lister2 = lister.clone();
    let mut refuses_asking = lister.clone();
    refuses_asking["family"] = json!("claude");
    refuses_asking["env"]["FAKE_PICKER_INITIAL_MODE"] = json!("bypassPermissions");
    refuses_asking["env"]["FAKE_REFUSE_MODES"] = json!("default,acceptEdits,plan");
    let native = json!({"kind": "claude-stdio", "family": "claude",
        "argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py")]});
    // Another family whose modes (`normal`, `strict`) no list names: a chat in one asks.
    let moded = json!({"argv": ["python3", fake], "family": "moded",
                       "env": {"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "1"}});
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}, "lister": lister,
                                   "nofork": nofork, "lister2": lister2, "moded": moded,
                                   "native": native, "refuses-asking": refuses_asking},
                     "webAskingModes": {"lister": ["default", "plan"],
                                         "moded": ["normal", "strict"]},
                     "defaultHarness": "fake",
                     // New chats start in full access, the default a person has: a fork must
                     // still start at its chat's own level.
                     "defaultPermissionMode": "fullAccess",
                     "titles": {"generate": false}});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The model `session`'s agent runs, as its meta shows it.
fn model_option(session: &Session) -> Option<String> {
    let meta = session.meta();
    let opts = meta.config_options.as_deref().and_then(Value::as_array)?;
    let model = opts.iter().find(|o| o["id"] == "model")?;
    model["currentValue"].as_str().map(str::to_owned)
}

/// The last model the agent session `sid` was told to run (`FAKE_CALLS`).
fn last_model_set(calls: &std::path::Path, sid: &str) -> Option<String> {
    let text = std::fs::read_to_string(calls).unwrap_or_default();
    text.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|c| c["params"]["sessionId"] == sid)
        .filter_map(|c| match c["method"].as_str()? {
            "session/set_model" => c["params"]["modelId"].as_str().map(str::to_owned),
            "session/set_config_option" if c["params"]["configId"] == "model" => {
                c["params"]["value"].as_str().map(str::to_owned)
            }
            _ => None,
        })
        .next_back()
}

fn live(hub: &Hub) -> usize {
    hub.sessions()
        .into_iter()
        .filter(|s| s.meta().status != crate::store::SessionStatus::Closed)
        .count()
}

/// A fork on the chat's own harness that names a model runs that model, its agent and its meta
/// alike; one the harness does not list is refused with no fork left. It ran the chat's model
/// (fork-hammer 2026-11-22: `session fork -m opencode/big-pickle` ran deepseek-v4.1-flash-free).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fork_on_its_own_harness_runs_the_model_it_names() {
    let dir = tempfile::tempdir().unwrap();
    let calls = dir.path().join("calls.jsonl");
    let hub = lister_hub(&calls);
    let parent = hub
        .new_session(NewRequest {
            harness: Some("lister".into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"ONE"})], "test", false).await.unwrap();
    hub.set_model(&parent, "claude-opus-5-5").await.unwrap();

    // `harness` empty: the chat's own (`acpmux session fork CHAT -m MODEL`).
    let fork = hub
        .fork_to(
            &parent,
            to_model("", "claude-sonnet-5-5"),
            None,
            None,
            Default::default(),
            None,
            true,
        )
        .await
        .unwrap();
    assert_eq!(fork.meta().harness, "lister");
    assert_eq!(fork.meta().parent_id.as_deref(), Some(parent.id.as_str()));
    let sid = fork.meta().agent_session_id.expect("started before the reply");
    assert_eq!(last_model_set(&calls, &sid).as_deref(), Some("claude-sonnet-5-5"));
    assert_eq!(model_option(&fork).as_deref(), Some("claude-sonnet-5-5"));
    // The parent keeps its own.
    assert_eq!(model_option(&parent).as_deref(), Some("claude-opus-5-5"));

    // Named with its harness, as `-m HARNESS/MODEL` spells it.
    let fork = hub
        .fork_to(
            &parent,
            to_model("lister", "lister/claude-haiku-5-5"),
            None,
            None,
            Default::default(),
            None,
            true,
        )
        .await
        .unwrap();
    assert_eq!(model_option(&fork).as_deref(), Some("claude-haiku-5-5"));

    let before = live(&hub);
    let refused = hub
        .fork_to(&parent, to_model("", "no-such-model"), None, None, Default::default(), None, true)
        .await
        .err()
        .expect("refused");
    assert_eq!(refused.code, -32602, "{}", refused.message);
    assert!(refused.message.contains("no-such-model"), "{}", refused.message);
    assert!(refused.message.contains("claude-sonnet-5-5"), "{}", refused.message);
    assert_eq!(live(&hub), before, "a refused model change left a fork");
}

/// A switch onto another harness takes its model as `-m HARNESS/MODEL` spells it, and one the
/// harness does not list fails the switch, not its first prompt (fork-hammer 2026-11-22:
/// `--harness claude -m claude/haiku` forked, then every prompt failed "There's an issue with
/// the selected model (claude/haiku)").
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_takes_harness_slash_model_and_refuses_a_model_its_harness_does_not_list() {
    let dir = tempfile::tempdir().unwrap();
    let calls = dir.path().join("calls.jsonl");
    let hub = lister_hub(&calls);
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"ONE"})], "test", false).await.unwrap();

    let fork = hub
        .fork_to(
            &parent,
            to_model("lister", "lister/claude-haiku-5-5"),
            None,
            None,
            Default::default(),
            None,
            true,
        )
        .await
        .unwrap();
    assert_eq!(fork.meta().harness, "lister");
    let sid = fork.meta().agent_session_id.expect("started before the reply");
    assert_eq!(last_model_set(&calls, &sid).as_deref(), Some("claude-haiku-5-5"));
    assert_eq!(model_option(&fork).as_deref(), Some("claude-haiku-5-5"));

    let before = live(&hub);
    let refused = hub
        .fork_to(
            &parent,
            to_model("lister", "lister/no-such-model"),
            None,
            None,
            Default::default(),
            None,
            true,
        )
        .await
        .err()
        .expect("refused");
    assert_eq!(refused.code, -32602, "{}", refused.message);
    assert!(refused.message.contains("no-such-model"), "{}", refused.message);
    assert!(live(&hub) <= before, "a refused switch left a fork");
}

/// A switch onto a harness that takes its model at spawn (Claude Code) and lists its models:
/// `listing/haiku` spawns it on `haiku`, and a model it does not list is refused by the fork
/// call (fork-hammer 2026-11-22: `--harness claude -m claude/haiku` failed its first prompt).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_onto_a_spawn_model_harness_reads_harness_slash_model_and_refuses_unlisted() {
    let hub = hub();
    let parent = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    let fork = hub
        .fork_to(
            &parent,
            to_model("listing", "listing/haiku"),
            None,
            None,
            Default::default(),
            None,
            true,
        )
        .await
        .unwrap();
    assert_eq!(fork.meta().harness, "listing");
    assert_eq!(fork.meta().model_request.as_deref(), Some("haiku"));
    let before = live(&hub);
    let refused = hub
        .fork_to(
            &parent,
            to_model("listing", "listing/sonnet"),
            None,
            None,
            Default::default(),
            None,
            true,
        )
        .await
        .err()
        .expect("refused");
    assert_eq!(refused.code, -32602, "{}", refused.message);
    // The models it lists, its profile's among them (the fake also reports its own).
    assert!(
        refused.message.contains("haiku") && refused.message.contains("opus"),
        "{}",
        refused.message
    );
    assert_eq!(live(&hub), before, "a refused switch left a fork");
}

/// Starts a turn on `session` that runs until it is cancelled, and waits until it runs.
async fn working(hub: &Arc<Hub>, session: &Arc<Session>) -> tokio::task::JoinHandle<()> {
    let turn = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            let until = vec![json!({"type": "text", "text": "until-cancel"})];
            let _ = hub.prompt(&session, until, "test", false).await;
        })
    };
    let started = std::time::Instant::now();
    while !matches!(
        session.meta().status,
        crate::store::SessionStatus::Running | crate::store::SessionStatus::Waiting
    ) {
        assert!(started.elapsed().as_secs() < 20, "the turn never started");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    turn
}

/// A fork made from acpmux's transcript (a working chat of an agent with no session/fork, as
/// pi) runs the chat's model, and so does a fork of that fork. It ran the harness's default: its
/// first agent was never told the chat's settings, which only a resumed agent session got
/// (cmux#50092).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_transcript_fork_and_its_fork_run_the_chats_model() {
    let dir = tempfile::tempdir().unwrap();
    let calls = dir.path().join("calls.jsonl");
    let hub = lister_hub(&calls);
    let parent = hub
        .new_session(NewRequest {
            harness: Some("nofork".into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"ONE"})], "test", false).await.unwrap();
    hub.set_model(&parent, "claude-opus-5-5").await.unwrap();

    let mut chat = parent.clone();
    for step in ["TWO", "THREE"] {
        let turn = working(&hub, &chat).await;
        let fork =
            hub.fork(&chat, None, None, Default::default(), None, None, false).await.unwrap();
        hub.cancel(&chat).await.unwrap();
        let _ = turn.await;
        assert_eq!(forked_from(&hub, &fork).as_deref(), Some("transcript"), "{step}");
        // Its first prompt carries the chat's transcript; then the model its own agent runs, as
        // the agent says, not as acpmux's meta does.
        hub.prompt(&fork, vec![json!({"type":"text", "text": step})], "test", false).await.unwrap();
        let before = replies(&hub, &fork).len();
        let ask = vec![json!({"type":"text", "text": "picked-model"})];
        hub.prompt(&fork, ask, "test", false).await.unwrap();
        assert_eq!(&replies(&hub, &fork)[before..], "claude-opus-5-5", "{step}");
        chat = fork;
    }
    hub.shutdown_all().await;
}

/// How `fork` was made (its `forked` record's `from`).
fn forked_from(hub: &Hub, fork: &Session) -> Option<String> {
    let events = hub.events(&fork.id, 0, 10_000).unwrap();
    let forked = events.iter().find(|e| e.kind == "forked")?;
    forked.msg.get("from").and_then(Value::as_str).map(str::to_owned)
}

/// A switch onto another harness starts at the chat's own permission level: in the chat's mode
/// where the new harness has it, as a chat it starts would (`start_mode.rs` "Inherit"). It started
/// in the level a new chat starts at: a chat under `ask` became a `bypassPermissions` fork
/// (cmux#50094).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_keeps_the_chats_permission_mode() {
    let dir = tempfile::tempdir().unwrap();
    let calls = dir.path().join("calls.jsonl");
    let hub = lister_hub(&calls);
    // Same family: the chat's own mode.
    let parent = hub
        .new_session(NewRequest {
            harness: Some("lister".into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type":"text", "text":"ONE"})], "test", false).await.unwrap();
    hub.set_mode(&parent, "acceptEdits").await.unwrap();
    let fork = hub
        .fork_to(&parent, to("lister2"), None, None, Default::default(), None, true)
        .await
        .unwrap();
    assert_eq!(fork.meta().harness, "lister2");
    assert_eq!(crate::web_modes::mode_of(&fork.meta()).as_deref(), Some("acceptEdits"));

    // Another family, from a chat in a mode that asks (pi's, any mode the lists do not name):
    // not the full access new chats start in.
    let asking = hub
        .new_session(NewRequest {
            harness: Some("moded".into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    hub.prompt(&asking, vec![json!({"type":"text", "text":"ONE"})], "test", false).await.unwrap();
    assert_eq!(crate::web_modes::mode_of(&asking.meta()).as_deref(), Some("normal"));
    let fork = hub
        .fork_to(&asking, to("lister"), None, None, Default::default(), None, true)
        .await
        .unwrap();
    assert_eq!(fork.meta().harness, "lister");
    let mode = crate::web_modes::mode_of(&fork.meta());
    assert_ne!(mode.as_deref(), Some("bypassPermissions"), "a fork of an asking chat");
    // Nor did its start try that mode (a refused try is only recorded on the fork).
    let tried: Vec<Value> = hub
        .events(&fork.id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "mode" || e.kind == "start_default_skipped")
        .map(|e| e.msg.clone())
        .collect();
    assert!(
        !tried.iter().any(|m| m["modeId"] == "bypassPermissions"),
        "a fork of an asking chat tried full access: {tried:?}"
    );
    hub.shutdown_all().await;
}

/// A cross-family asking fork is launched asking, and a target that cannot keep
/// that level is refused even when the parent has no explicit policy.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_asking_fork_starts_claude_asking_and_refuses_a_broader_target() {
    let dir = tempfile::tempdir().unwrap();
    let hub = lister_hub(&dir.path().join("calls.jsonl"));
    let parent = hub
        .new_session(NewRequest {
            harness: Some("moded".into()),
            cwd: Some(dir.path().to_path_buf()),
            ..Default::default()
        })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type": "text", "text": "ONE"})], "test", false).await.unwrap();
    assert!(parent.meta().permission_policy.is_none());
    let fork = hub
        .fork_to(&parent, to("native"), None, None, Default::default(), None, false)
        .await
        .unwrap();
    assert_eq!(crate::web_modes::mode_of(&fork.meta()).as_deref(), Some("default"));
    let before_reply = replies(&hub, &fork).len();
    hub.prompt(&fork, vec![json!({"type": "text", "text": "spawn flags"})], "test", false)
        .await
        .unwrap();
    let argv: Vec<String> = serde_json::from_str(&replies(&hub, &fork)[before_reply..]).unwrap();
    let at = argv.iter().position(|arg| arg == "--permission-mode").unwrap();
    assert_eq!(argv[at + 1], "default");
    let before = live(&hub);
    let refused = hub
        .fork_to(&parent, to("refuses-asking"), None, None, Default::default(), None, false)
        .await;
    assert!(refused.is_err(), "a target that refuses asking must not remain broader");
    assert_eq!(live(&hub), before, "a refused fork remained live");
    let explicit = hub
        .fork_with_start(
            &parent,
            Some(to("refuses-asking")),
            None,
            None,
            Default::default(),
            None,
            false,
            super::fork_subagent::ForkStart {
                mode: Some("bypassPermissions".into()),
                person: true,
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(crate::web_modes::mode_of(&explicit.meta()).as_deref(), Some("bypassPermissions"));
    hub.shutdown_all().await;
}

/// ForkStart's model selection uses the same normalization as an explicit retarget,
/// and a simultaneous mode selection still applies.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fork_start_normalizes_its_model_and_keeps_its_explicit_mode() {
    let dir = tempfile::tempdir().unwrap();
    let hub = lister_hub(&dir.path().join("calls.jsonl"));
    let parent = hub
        .new_session(NewRequest {
            harness: Some("lister".into()),
            cwd: Some(dir.path().to_path_buf()),
            ..Default::default()
        })
        .await
        .unwrap();
    hub.prompt(&parent, vec![json!({"type": "text", "text": "ONE"})], "test", false).await.unwrap();
    for target in [None, Some(to("lister2"))] {
        let own = target.is_none();
        let fork = hub
            .fork_with_start(
                &parent,
                target,
                None,
                None,
                Default::default(),
                None,
                false,
                super::fork_subagent::ForkStart {
                    model: own.then(|| "lister/claude-opus-5-5".into()),
                    mode: Some("acceptEdits".into()),
                    person: true,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(crate::web_modes::mode_of(&fork.meta()).as_deref(), Some("acceptEdits"));
        if own {
            hub.prompt(&fork, vec![json!({"type": "text", "text": "picked-model"})], "test", false)
                .await
                .unwrap();
            assert!(replies(&hub, &fork).ends_with("claude-opus-5-5"));
        }
    }
    hub.shutdown_all().await;
}

/// Catalog aliases must reach native launch arguments on both own-harness and retarget forks.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fork_catalog_aliases_reach_the_native_spawn_model() {
    let dir = tempfile::tempdir().unwrap();
    let hub = lister_hub(&dir.path().join("calls.jsonl"));
    for harness in ["native", "lister"] {
        let parent = hub
            .new_session(NewRequest {
                harness: Some(harness.into()),
                cwd: Some(dir.path().to_path_buf()),
                ..Default::default()
            })
            .await
            .unwrap();
        hub.prompt(&parent, vec![json!({"type": "text", "text": "ONE"})], "test", false)
            .await
            .unwrap();
        for alias in ["fable-5.2", "claude/fable-5.2"] {
            let fork = hub
                .fork_with_start(
                    &parent,
                    (harness != "native")
                        .then(|| Retarget { model: Some(alias.into()), ..to("native") }),
                    None,
                    None,
                    Default::default(),
                    None,
                    false,
                    super::fork_subagent::ForkStart {
                        model: (harness == "native").then(|| alias.into()),
                        ..Default::default()
                    },
                )
                .await
                .unwrap();
            assert_eq!(fork.meta().model_request.as_deref(), Some("claude-fable-5-2"));
            let before = replies(&hub, &fork).len();
            hub.prompt(&fork, vec![json!({"type": "text", "text": "spawn flags"})], "test", false)
                .await
                .unwrap();
            let argv: Vec<String> = serde_json::from_str(&replies(&hub, &fork)[before..]).unwrap();
            let at = argv.iter().position(|arg| arg == "--model").unwrap();
            assert_eq!(argv[at + 1], "claude-fable-5-2", "{harness}: {alias}");
        }
    }
    hub.shutdown_all().await;
}
