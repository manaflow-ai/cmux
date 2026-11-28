//! The fork hammer: every fork kind, on every harness flavor, from every state a chat is in.
//!
//! Leo, 2026-11-22: "i also do wonder about the state of affairs of our forking behaviour and if
//! it's as good as it can be. i basically never use it, and like never use codex or opencode or
//! whatever, so we ought to really hammer it hard and just test tons of variations of it."
//!
//! Each flavor is the fake agent acting as a real harness answers `session/fork`: Codex's
//! (defaults back from the fork), OpenCode's (only once no prompt runs, replaying the forked
//! turns), Claude's ACP adapter (`Internal error` on a chat with no turn), Kimi or pi's (no
//! `session/fork` at all), a slow one, and Claude Code itself (`claude-stdio`,
//! `--resume --fork-session`). Every fork, from a chat that is idle with no turn, idle after a
//! turn, or mid-turn, onto its own harness or any other, must:
//!
//! - come back within its bound, as a chat of the named harness whose parent is the chat;
//! - add exactly one live session;
//! - show the chat's turns, and answer its own first prompt;
//! - leave the chat as it was: its turns, its harness, and a chat that still answers.
//!
//! One case per variation would be some 70 tests of the same lines; one table names each failing
//! variation in a single run instead.

use super::*;
use crate::hub::NewRequest;
use std::time::Duration;

/// How long one fork, or one prompt, may take before the variation counts as hung.
const BOUND: Duration = Duration::from_secs(30);

/// The flavors: (harness name, the variation it stands for).
const FLAVORS: &[(&str, &str)] = &[
    ("plain", "an agent with session/fork"),
    ("codex", "Codex: the fork answers with the harness defaults"),
    ("opencode", "OpenCode 1.19: forks only when idle, replays the forked turns"),
    ("acp-claude", "Claude's ACP adapter: Internal error on a chat with no turn"),
    ("nofork", "Kimi or pi: no session/fork, forked from acpmux's transcript"),
    ("slow", "an agent that answers session/fork 400 ms late"),
    ("native", "Claude Code (claude-stdio): --resume --fork-session"),
];

#[derive(Clone, Copy, Debug)]
enum State {
    /// A new chat, no turn yet.
    Fresh,
    /// After one finished turn.
    Idle,
    /// While a turn runs.
    Working,
}

/// A hub whose new chats start in an asking mode (`full_access`: in full access, as a person's
/// do by default).
fn hub(full_access: bool) -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let agent =
        |family: &str, env: Value| json!({"argv": ["python3", fake], "family": family, "env": env});
    let cfg = json!({"harnesses": {
                        "plain": agent("plain", json!({})),
                        "codex": agent("codex-like", json!({"FAKE_FORK_DEFAULTS": "1"})),
                        "opencode": agent("opencode", json!({"FAKE_FORK_BUSY": "1", "FAKE_FORK_REPLAY": "1"})),
                        "acp-claude": agent("acp-claude", json!({"FAKE_FORK_ERROR": "1"})),
                        "nofork": agent("nofork", json!({"FAKE_NO_FORK": "1"})),
                        "slow": agent("slow", json!({"FAKE_FORK_DELAY_MS": "400"})),
                        "native": {"kind": "claude-stdio", "family": "claude",
                                   "argv": ["python3", claude]}},
                     // Each fake flavor has a mode that asks, as every real harness does: a switch
                     // never starts a fork that asks less than its chat (`start_mode.rs`).
                     "webAskingModes": {"plain": ["normal", "strict"],
                                         "codex-like": ["normal", "strict"],
                                         "opencode": ["normal", "strict"],
                                         "acp-claude": ["normal", "strict"],
                                         "nofork": ["normal", "strict"],
                                         "slow": ["normal", "strict"]},
                     "defaultHarness": "plain",
                     "titles": {"generate": false}});
    let mut cfg = cfg;
    if full_access {
        cfg["defaultPermissionMode"] = json!("fullAccess");
    }
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The refusal a variation must meet, by the rules acpmux keeps on purpose:
/// - a chat with no turn has nothing to fork, unless its agent forks it itself (`NOTHING_TO_FORK`);
/// - an agent's own fork that fails while the chat is idle is said, not swapped for a transcript
///   copy that would lose what the agent kept (`fork.rs`), so the ACP adapter's error shows;
/// - a switch never starts a session that asks less than its chat: Codex and OpenCode have no
///   reviewed mode that asks (`web_modes::REFUSED_FAMILIES`), so an asking chat cannot move there.
fn must_refuse(full_access: bool, from: &str, state: State, onto: Option<&str>) -> Option<&'static str> {
    match (onto, state) {
        (None, State::Fresh) if matches!(from, "acp-claude" | "nofork" | "native") => {
            Some("no turn yet")
        }
        (None, State::Idle) if from == "acp-claude" => Some("acp-claude could not fork this chat"),
        (Some("codex" | "opencode"), _) if !full_access => Some("would ask less than this one"),
        _ => None,
    }
}

fn text(words: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": words})]
}

fn replies(hub: &Hub, session: &Session) -> String {
    hub.events(&session.id, 0, 100_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect()
}

fn prompts(hub: &Hub, session: &Session) -> Vec<String> {
    hub.events(&session.id, 0, 100_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "user_message")
        .filter_map(|e| e.msg.get("text").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

fn live(hub: &Hub) -> usize {
    hub.sessions()
        .into_iter()
        .filter(|s| s.meta().status != crate::store::SessionStatus::Closed)
        .count()
}

async fn bounded<T>(what: &str, f: impl std::future::Future<Output = T>) -> Result<T, String> {
    tokio::time::timeout(BOUND, f).await.map_err(|_| format!("{what}: hung past {BOUND:?}"))
}

/// The prompt that keeps `harness`'s turn running until it is cancelled.
fn long_turn(harness: &str) -> &'static str {
    if harness == "native" { "long-step" } else { "until-cancel" }
}

/// Whether `harness`'s agent echoes a prompt's words (Claude Code's stand-in answers with its
/// command line instead).
fn echoes(harness: &str) -> bool {
    harness != "native"
}

/// Starts a turn that runs until cancelled, once it runs.
async fn working(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
) -> Result<tokio::task::JoinHandle<()>, String> {
    let long = long_turn(&session.meta().harness);
    let turn = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            let _ = hub.prompt(&session, text(long), "test", false).await;
        })
    };
    let started = std::time::Instant::now();
    while !matches!(
        session.meta().status,
        crate::store::SessionStatus::Running | crate::store::SessionStatus::Waiting
    ) {
        if started.elapsed() > BOUND {
            return Err("the chat's turn never started".into());
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    Ok(turn)
}

/// One variation: a chat on `from`, in `state`, forked onto `onto` (`None`: an ordinary fork of
/// its own harness). `Err` says what broke.
async fn variation(
    hub: &Arc<Hub>,
    full_access: bool,
    from: &str,
    state: State,
    onto: Option<&str>,
) -> Result<(), String> {
    let parent = bounded(
        "new chat",
        hub.new_session(NewRequest {
            harness: Some(from.into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        }),
    )
    .await?
    .map_err(|e| format!("new chat refused: {}", e.message))?;
    let said = format!("PARENT-{}", parent.id);
    if !matches!(state, State::Fresh) {
        bounded("the chat's turn", hub.prompt(&parent, text(&said), "test", false))
            .await?
            .map_err(|e| format!("the chat's turn failed: {}", e.message))?;
    }
    let before_prompts = prompts(hub, &parent);
    let turn = match state {
        State::Working => Some(working(hub, &parent).await?),
        _ => None,
    };
    let before = live(hub);
    let forked = match onto {
        None => {
            bounded("fork", hub.fork(&parent, None, None, Default::default(), None, None, false))
                .await
        }
        Some(h) => {
            let to = Retarget { harness: h.into(), model: None, remote: false };
            bounded("switch", hub.fork_to(&parent, to, None, None, Default::default(), None, true))
                .await
        }
    };
    if let Some(turn) = turn {
        let _ = hub.cancel(&parent).await;
        let _ = bounded("the chat's cancelled turn", turn).await?;
    }
    let forked = forked?;
    if let Some(why) = must_refuse(full_access, from, state, onto) {
        return match forked {
            Ok(fork) => Err(format!("forked to {}, want a refusal: {why}", fork.id)),
            Err(e) if !e.message.contains(why) => Err(format!("refused {:?}, want {why}", e.message)),
            Err(_) if parent.meta().harness != from => {
                Err(format!("refused, but the chat now runs {}", parent.meta().harness))
            }
            Err(_) => Ok(()),
        };
    }
    let fork = forked.map_err(|e| format!("refused: {}", e.message))?;
    let mut broke = Vec::new();
    let meta = fork.meta();
    if meta.harness != onto.unwrap_or(from) {
        broke.push(format!("runs {}", meta.harness));
    }
    if meta.parent_id.as_deref() != Some(parent.id.as_str()) {
        broke.push(format!("parent is {:?}", meta.parent_id));
    }
    if live(hub) != before + 1 {
        broke.push(format!("{} live sessions after one fork, {before} before", live(hub)));
    }
    let shown = prompts(hub, &fork);
    if !matches!(state, State::Fresh) && !shown.iter().any(|p| p == &said) {
        broke.push(format!("shows {shown:?}, not the chat's turn"));
    }
    let ask = format!("FORK-{}", fork.id);
    let heard = replies(hub, &fork).len();
    match bounded("the fork's first prompt", hub.prompt(&fork, text(&ask), "test", false)).await {
        Err(e) => broke.push(e),
        Ok(Err(e)) => broke.push(format!("its first prompt failed: {}", e.message)),
        Ok(Ok(_)) => {
            let answer = replies(hub, &fork)[heard..].to_owned();
            if answer.is_empty() || (echoes(&meta.harness) && !answer.contains(&ask)) {
                broke.push(format!("its first prompt got no answer: {answer:?}"));
            }
        }
    }
    // The chat is as it was, and still answers.
    if parent.meta().harness != from {
        broke.push(format!("the chat now runs {}", parent.meta().harness));
    }
    let after = format!("AFTER-{}", parent.id);
    match bounded("the chat after the fork", hub.prompt(&parent, text(&after), "test", false)).await
    {
        Err(e) => broke.push(e),
        Ok(Err(e)) => broke.push(format!("the chat's next prompt failed: {}", e.message)),
        Ok(Ok(_)) => {}
    }
    let mut want = before_prompts;
    if matches!(state, State::Working) {
        want.push(long_turn(from).into());
    }
    want.push(after);
    let now = prompts(hub, &parent);
    if now != want {
        broke.push(format!("the chat's turns became {now:?}, want {want:?}"));
    }
    if broke.is_empty() { Ok(()) } else { Err(broke.join("; ")) }
}

fn report(failed: &[String], ran: usize) {
    assert!(
        failed.is_empty(),
        "{} of {ran} fork variations broke:\n{}",
        failed.len(),
        failed.join("\n")
    );
}

/// Every flavor forked onto its own harness, from every state.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_flavor_forks_from_every_state() {
    let hub = hub(false);
    let (mut failed, mut ran) = (Vec::new(), 0);
    for (flavor, about) in FLAVORS {
        for state in [State::Fresh, State::Idle, State::Working] {
            ran += 1;
            if let Err(why) = variation(&hub, false, flavor, state, None).await {
                failed.push(format!("{flavor} ({about}), {state:?}: {why}"));
            }
        }
    }
    hub.shutdown_all().await;
    report(&failed, ran);
}

/// Every flavor switched onto every other one, idle after a turn and mid-turn, from chats that ask
/// and from chats in full access.
async fn switches(full_access: bool) {
    let hub = hub(full_access);
    let (mut failed, mut ran) = (Vec::new(), 0);
    for (from, _) in FLAVORS {
        for (onto, _) in FLAVORS.iter().filter(|(h, _)| h != from) {
            for state in [State::Idle, State::Working] {
                ran += 1;
                if let Err(why) = variation(&hub, full_access, from, state, Some(onto)).await {
                    failed.push(format!("{from} -> {onto}, {state:?}: {why}"));
                }
            }
        }
    }
    hub.shutdown_all().await;
    report(&failed, ran);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_flavor_switches_onto_every_other_from_an_asking_chat() {
    switches(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_flavor_switches_onto_every_other_in_full_access() {
    switches(true).await;
}

/// A fork of a fork of a fork, each onto the next flavor: the last one shows every turn.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chain_of_forks_through_every_flavor_keeps_every_turn() {
    // In full access, so the chain may pass through Codex and OpenCode.
    let hub = hub(true);
    let mut chat = hub
        .new_session(NewRequest {
            harness: Some(FLAVORS[0].0.into()),
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    let mut said = Vec::new();
    for (i, (flavor, _)) in
        FLAVORS.iter().enumerate().skip(1).chain(FLAVORS.iter().enumerate().take(1))
    {
        let words = format!("STEP-{i}");
        hub.prompt(&chat, text(&words), "test", false).await.unwrap();
        said.push(words);
        let to = Retarget { harness: (*flavor).into(), model: None, remote: false };
        chat = bounded(
            "chain fork",
            hub.fork_to(&chat, to, None, None, Default::default(), None, true),
        )
        .await
        .unwrap()
        .unwrap_or_else(|e| panic!("onto {flavor}: {}", e.message));
        assert_eq!(chat.meta().harness, *flavor);
        assert_eq!(prompts(&hub, &chat), said, "onto {flavor}");
    }
    hub.prompt(&chat, text("LAST"), "test", false).await.unwrap();
    let heard = replies(&hub, &chat);
    for words in &said {
        assert!(
            heard.contains(words.as_str()),
            "the last fork's agent never heard {words}: {heard}"
        );
    }
    hub.shutdown_all().await;
}
