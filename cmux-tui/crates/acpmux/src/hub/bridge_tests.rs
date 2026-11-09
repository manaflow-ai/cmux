use super::*;
use crate::config::{Config, StoreMode};
use crate::store::{MemoryStore, Watching};
use std::io::{BufRead, Write};
use std::path::PathBuf;

#[test]
fn only_an_all_text_prompt_is_carried() {
    let blocks = [
        json!({"type": "text", "text": "one"}),
        json!({"type": "image", "data": "..."}),
        json!({"type": "text", "text": "two"}),
    ];
    assert_eq!(text_of(&blocks), None, "an image would be lost: refused, not cut");
    let texts = [json!({"type": "text", "text": "one"}), json!({"type": "text", "text": "two"})];
    assert_eq!(text_of(&texts).as_deref(), Some("one\n\ntwo"));
    assert_eq!(text_of(&[json!({"type": "text", "text": "  "})]), None);
}

#[test]
fn a_delivery_is_found_by_its_uuid_in_its_own_session_until_answered() {
    let rx = deliveries().claim("u-find".into(), "s1", "p1", "hi", "hi").unwrap();
    let again = deliveries().claim("u-other".into(), "s1", "p1", "hi", "hi");
    assert!(again.is_err(), "one id, one send");
    assert_eq!(delivered("s1", "u-find"), Some(("p1".into(), "hi".into())));
    assert_eq!(delivered("s2", "u-find"), None);
    answered("s1", "p1", "t1");
    assert_eq!(delivered("s1", "u-find"), None, "an answered delivery is shown already");
    assert_eq!(*rx.borrow(), Some(Ok("t1".to_owned())));
    assert!(deliveries().of_prompt("s1", "p1").is_some(), "kept, so a resend finds it");
}

/// A resend waiting on a delivery the inbox refused fails with it, never answers as a turn.
#[tokio::test]
async fn a_resend_of_a_delivery_that_failed_fails_too() {
    let rx = deliveries().claim("u-fail".into(), "s9", "p9", "hi", "hi").unwrap();
    let waiting = tokio::spawn(turn_of(rx));
    let gone = deliveries().by_uuid.remove("u-fail").unwrap();
    gone.turn.send_replace(Some(Err("refused".into())));
    let outcome = waiting.await.unwrap();
    let err = answer("p9", outcome, None).unwrap_err();
    assert!(err.message.contains("bridge.undelivered: refused"), "{}", err.message);
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-bridge-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sessions")).unwrap();
    dir
}

/// A Claude Code stand-in: its registry entry and key, and an inbox that, for each message,
/// appends the lines Claude Code writes for a peer message and its answer to the transcript.
#[cfg(unix)]
fn fake_claude(
    config: &std::path::Path,
    sid: &str,
    transcript: PathBuf,
) -> Arc<std::sync::atomic::AtomicUsize> {
    let count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = count.clone();
    let pid = std::process::id();
    let sock = config.join("inbox.sock");
    let listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
    let entry = json!({"pid": pid, "sessionId": sid, "cwd": "/w", "entrypoint": "claude-desktop", "messagingSocketPath": sock});
    std::fs::write(config.join(format!("sessions/{pid}.json")), entry.to_string()).unwrap();
    let key = crate::claude_peers::key_file(config, pid, &sock);
    std::fs::write(key, json!({"peerToken": "0123456789abcdef0123456789abcdef"}).to_string())
        .unwrap();
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let lines: Vec<Value> = std::io::BufReader::new(conn.unwrap())
                .lines()
                .map_while(Result::ok)
                .filter_map(|l| serde_json::from_str(&l).ok())
                .collect();
            assert_eq!(lines[0]["token"], "0123456789abcdef0123456789abcdef");
            let msg = &lines[1];
            let mut f = std::fs::OpenOptions::new().append(true).open(&transcript).unwrap();
            let user = json!({"type": "user", "uuid": msg["uuid"], "isMeta": true,
                "origin": {"kind": "peer", "from": msg["from"], "verifiedPeerPid": 1},
                "message": {"role": "user", "content": format!("Another Claude session sent a message:\n{}", msg["message"]["content"].as_str().unwrap())}});
            let answer = json!({"type": "assistant", "message": {"role": "assistant",
                "stop_reason": "end_turn", "content": [{"type": "text", "text": "PONG"}]}});
            writeln!(f, "{user}\n{answer}").unwrap();
        }
    });
    count
}

/// The whole loop: a prompt to a watched Claude chat goes into the app's inbox, the app's
/// transcript line shows as that prompt (under its id, with its text, not the app's wrapper),
/// its answer as the turn's answer, and the prompt's call answers when the turn ends.
#[cfg(unix)]
#[tokio::test]
async fn a_prompt_to_a_watched_desktop_chat_is_delivered_and_its_answer_shown() {
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let config = scratch("roundtrip");
    let transcript = config.join("sid-1.jsonl");
    std::fs::write(&transcript, "").unwrap();
    let inbox = fake_claude(&config, "sid-1", transcript.clone());

    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().claude = config.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(config.clone()), ..Default::default() })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("sid-1".into());
        meta.tags.insert(
            "bridge".into(),
            crate::store::Tag { value: "claude".into(), expires_at: None },
        );
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: transcript,
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    hub.save_meta(&session);
    hub.start_watch(&session);

    let accepted = Arc::new(Mutex::new(None));
    let seen = accepted.clone();
    let opts = PromptOptions {
        prompt_id: Some("p-desk".into()),
        on_accepted: Some(Box::new(move |v| *seen.lock().unwrap() = Some(v))),
        ..Default::default()
    };
    let blocks = vec![json!({"type": "text", "text": "ping from acpmux"})];
    let reply = tokio::time::timeout(
        Duration::from_secs(20),
        hub.prompt_with(&session, blocks, "test", false, opts),
    )
    .await
    .expect("answered within 20 s")
    .unwrap();

    assert_eq!(reply["_meta"]["acpmux"]["answered"], true, "{reply}");
    assert_eq!(accepted.lock().unwrap().as_ref().unwrap()["state"], "delivered");
    let events = hub.store.events(&session.id, 0, usize::MAX).unwrap();
    let user = events.iter().find(|e| e.kind == "user_message").expect("the prompt shows");
    assert_eq!(user.msg["promptId"], "p-desk");
    assert_eq!(user.msg["text"], "ping from acpmux");
    assert_eq!(user.msg["client"], "bridge");
    assert!(events.iter().any(|e| e.kind == "bridge_delivered"));
    assert!(
        events.iter().any(|e| e.kind == "agent_message_chunk"
            && e.msg.pointer("/params/update/content/text") == Some(&json!("PONG"))),
        "the answer shows"
    );
    assert!(events.iter().any(|e| e.kind == "turn_result" && e.msg["promptId"] == "p-desk"));

    // The same prompt id again answers with the first turn and is not delivered twice.
    let opts = PromptOptions { prompt_id: Some("p-desk".into()), ..Default::default() };
    let blocks = vec![json!({"type": "text", "text": "ping from acpmux"})];
    let again = hub.prompt_with(&session, blocks, "test", false, opts).await.unwrap();
    assert_eq!(again["_meta"]["acpmux"]["turnId"], reply["_meta"]["acpmux"]["turnId"]);
    assert_eq!(again["_meta"]["acpmux"]["duplicate"], true);
    assert_eq!(inbox.load(std::sync::atomic::Ordering::SeqCst), 1);
}

/// A watched chat whose app is gone is still refused: Take Over runs it here.
#[tokio::test]
async fn a_watched_chat_with_no_live_app_is_still_read_only() {
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let config = scratch("gone");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().claude = config.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(config.clone()), ..Default::default() })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("nobody".into());
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: config.join("x.jsonl"),
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let err = hub.prompt_with(&session, blocks, "test", false, PromptOptions::default()).await;
    assert!(err.unwrap_err().message.contains("watch.read_only"));
}

/// A watched chat the bridge did not list (no `bridge` tag) is refused even while its app is
/// live and delivers: a person watching a terminal session keeps it read-only.
#[cfg(unix)]
#[tokio::test]
async fn a_watched_chat_the_bridge_did_not_list_is_still_read_only() {
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let config = scratch("unlisted");
    let transcript = config.join("sid-u.jsonl");
    std::fs::write(&transcript, "").unwrap();
    let inbox = fake_claude(&config, "sid-u", transcript.clone());
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().claude = config.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(config.clone()), ..Default::default() })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("sid-u".into());
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: transcript,
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let err = hub.prompt_with(&session, blocks, "test", false, PromptOptions::default()).await;
    assert!(err.unwrap_err().message.contains("watch.read_only"));
    assert_eq!(inbox.load(std::sync::atomic::Ordering::SeqCst), 0, "nothing reached the app");
}

#[test]
fn an_agents_message_tells_the_app_how_to_answer_and_the_persons_goes_as_typed() {
    assert_eq!(with_reply_hint("hi", None), "hi");
    assert_eq!(with_reply_hint("hi", Some("  ")), "hi");
    let hinted = with_reply_hint("hi", Some("cosmic-gray/claude-sr2-coord"));
    assert!(hinted.starts_with("hi\n\n[From cosmic-gray/claude-sr2-coord"), "{hinted}");
    assert!(hinted.contains("`acpmux send 'cosmic-gray/claude-sr2-coord' '<your reply>'`"));
    let quoted = with_reply_hint("hi", Some("it's"));
    assert!(quoted.contains(r"`acpmux send 'it'\''s' "), "{quoted}");
}

/// The other direction: a send whose socket peer runs under the desktop app's registered Claude
/// Code process is bound to the chat the bridge made for it; a stamp a client sent is dropped,
/// and a connection that proved its own session keeps that one.
#[cfg(unix)]
#[tokio::test]
async fn a_send_from_the_desktop_apps_process_tree_is_its_bridged_chats() {
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let config = scratch("bind");
    let transcript = config.join("sid-bind.jsonl");
    std::fs::write(&transcript, "").unwrap();
    // This test process stands in for the app's Claude Code: it is its own ancestor.
    let _inbox = fake_claude(&config, "sid-bind", transcript.clone());
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().claude = config.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(config.clone()), ..Default::default() })
        .await
        .unwrap();
    let key = crate::hub::desktop_bridge::BRIDGED_KEY;
    let stamped = |prompt: &Value| prompt["_meta"]["acpmux"][key].as_str().map(str::to_owned);
    let fresh = || json!({"_meta": {"acpmux": {key: "forged"}}});

    // Not a bridged chat yet: nothing is bound, and the forged stamp is gone.
    let mut prompt = fresh();
    hub.stamp_bridged_sender(&mut prompt, Some(std::process::id()), false, false).await;
    assert_eq!(stamped(&prompt), None);

    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("sid-bind".into());
        meta.tags.insert(
            "bridge".into(),
            crate::store::Tag { value: "claude".into(), expires_at: None },
        );
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: transcript,
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    let mut prompt = fresh();
    hub.stamp_bridged_sender(&mut prompt, Some(std::process::id()), false, false).await;
    assert_eq!(stamped(&prompt).as_deref(), Some(session.id.as_str()));

    // No peer pid (a WebSocket, a pipe): nothing.
    let mut prompt = fresh();
    hub.stamp_bridged_sender(&mut prompt, None, false, false).await;
    assert_eq!(stamped(&prompt), None);
    // A connection that proved its own session: its caller token names it, not this.
    let mut prompt = fresh();
    hub.stamp_bridged_sender(&mut prompt, Some(std::process::id()), false, true).await;
    assert_eq!(stamped(&prompt), None);
    // The outbox delivering what it bound on arrival keeps the stamp.
    let mut prompt = json!({"_meta": {"acpmux": {key: session.id}}});
    hub.stamp_bridged_sender(&mut prompt, None, true, false).await;
    assert_eq!(stamped(&prompt).as_deref(), Some(session.id.as_str()));
}

#[test]
fn a_codex_delivery_is_found_by_its_text_once_and_oldest_first() {
    deliveries().claim("u-c1".into(), "sc", "pc1", "hi", "hi\n\n[hint]").unwrap();
    deliveries().claim("u-c2".into(), "sc", "pc2", "hi", "hi\n\n[hint]").unwrap();
    assert_eq!(delivered_text("sc", "hi"), None, "the app got the hinted text");
    assert_eq!(delivered_text("other", "hi\n\n[hint]"), None);
    assert_eq!(delivered_text("sc", " hi\n\n[hint] "), Some(("pc1".into(), "hi".into())));
    assert_eq!(delivered_text("sc", "hi\n\n[hint]"), Some(("pc2".into(), "hi".into())));
    assert_eq!(delivered_text("sc", "hi\n\n[hint]"), None, "each line shows one delivery");
}

/// The Codex loop: a prompt to a watched Codex desktop chat is queued for its thread through
/// the app-server daemon; the rollout's prompt line shows as that prompt (its text, not the
/// reply hint the app got), its answer as the turn's answer, and the call answers at its end.
#[cfg(unix)]
#[tokio::test]
async fn a_prompt_to_a_watched_codex_desktop_chat_is_queued_and_its_answer_shown() {
    use crate::codex_desktop::tests as codex;
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let thread = "01a1bf30-0000-7000-8000-00000000c0de";
    let dir = codex::home();
    let home = dir.path().to_path_buf();
    codex::state_db(&home, &[(thread, "codex_desktop", "/w", false)]);
    let _lock = codex::hold(&home, thread);
    let rollout = home.join("rollout.jsonl");
    std::fs::write(&rollout, "").unwrap();
    let written = rollout.clone();
    let added = codex::fake_daemon(&home, move |params| {
        let text = params["input"][0]["text"].as_str().unwrap();
        let user = json!({"type": "response_item", "payload": {"type": "message", "role": "user",
            "content": [{"type": "input_text", "text": text}],
            "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["user.text"]}}});
        let answer = json!({"type": "response_item", "payload": {"type": "message",
            "role": "assistant", "phase": "final_answer",
            "content": [{"type": "output_text", "text": "PONG"}]}});
        let end = json!({"type": "event_msg", "payload": {"type": "task_complete"}});
        let mut f = std::fs::OpenOptions::new().append(true).open(&written).unwrap();
        writeln!(f, "{user}\n{answer}\n{end}").unwrap();
    });

    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().codex = home.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(home.clone()), ..Default::default() })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some(thread.into());
        meta.tags
            .insert("bridge".into(), crate::store::Tag { value: "codex".into(), expires_at: None });
        meta.watching = Some(Watching {
            family: "codex".into(),
            file: rollout,
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    hub.save_meta(&session);
    hub.start_watch(&session);

    let opts = PromptOptions {
        prompt_id: Some("p-codex".into()),
        agent: Some("desktop cmux".into()),
        ..Default::default()
    };
    let blocks = vec![json!({"type": "text", "text": "ping from claude"})];
    let reply = tokio::time::timeout(
        Duration::from_secs(20),
        hub.prompt_with(&session, blocks, "test", false, opts),
    )
    .await
    .expect("answered within 20 s")
    .unwrap();

    assert_eq!(reply["_meta"]["acpmux"]["answered"], true, "{reply}");
    assert_eq!(reply["_meta"]["acpmux"]["bridged"]["thread"], thread, "{reply}");
    let added = added.lock().unwrap().clone();
    assert_eq!(added.len(), 1);
    assert_eq!(added[0]["threadId"], thread);
    let sent = added[0]["input"][0]["text"].as_str().unwrap();
    assert!(sent.starts_with("ping from claude\n\n[From desktop cmux"), "{sent}");
    let events = hub.store.events(&session.id, 0, usize::MAX).unwrap();
    let user = events.iter().find(|e| e.kind == "user_message").expect("the prompt shows");
    assert_eq!(user.msg["promptId"], "p-codex");
    assert_eq!(user.msg["text"], "ping from claude");
    assert_eq!(user.msg["client"], "bridge");
    assert!(events.iter().any(|e| e.kind == "agent_message_chunk"
        && e.msg.pointer("/params/update/content/text") == Some(&json!("PONG"))));
    assert!(events.iter().any(|e| e.kind == "turn_result" && e.msg["promptId"] == "p-codex"));
}

/// A watched Codex chat whose thread no running Codex holds stays read-only.
#[cfg(unix)]
#[tokio::test]
async fn a_watched_codex_chat_with_no_live_thread_is_still_read_only() {
    use crate::codex_desktop::tests as codex;
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let thread = "01a1bf30-0000-7000-8000-00000000dead";
    let dir = codex::home();
    let home = dir.path().to_path_buf();
    codex::state_db(&home, &[(thread, "codex_desktop", "/w", false)]);
    let added = codex::fake_daemon(&home, |_| {});
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().codex = home.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(home.clone()), ..Default::default() })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some(thread.into());
        meta.tags
            .insert("bridge".into(), crate::store::Tag { value: "codex".into(), expires_at: None });
        meta.watching = Some(Watching {
            family: "codex".into(),
            file: home.join("x.jsonl"),
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let err = hub.prompt_with(&session, blocks, "test", false, PromptOptions::default()).await;
    assert!(err.unwrap_err().message.contains("watch.read_only"));
    assert!(added.lock().unwrap().is_empty(), "nothing reached the app");
}

/// Review of #38393 (F1): a shared chat's guest prompt that waits for the owner's approval never
/// reaches the desktop app's inbox before approval; while the chat is watched it is refused.
#[cfg(unix)]
#[tokio::test]
async fn a_prompt_awaiting_the_owners_approval_never_reaches_the_app() {
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let config = scratch("approval");
    let transcript = config.join("sid-a.jsonl");
    std::fs::write(&transcript, "").unwrap();
    let inbox = fake_claude(&config, "sid-a", transcript.clone());
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().claude = config.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(config.clone()), ..Default::default() })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("sid-a".into());
        meta.tags.insert(
            "bridge".into(),
            crate::store::Tag { value: "claude".into(), expires_at: None },
        );
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: transcript,
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    let guest = json!({"kind": "person_message", "from": "guest:k3x9", "fromName": "Cy",
        "approval": "owner"});
    assert!(crate::author::awaits_owner(Some(&guest)));
    let opts = PromptOptions { provenance: Some(guest), ..Default::default() };
    let blocks = vec![json!({"type": "text", "text": "run this"})];
    let err = hub.prompt_with(&session, blocks, "test", false, opts).await;
    assert!(err.unwrap_err().message.contains("watch.read_only"));
    assert_eq!(inbox.load(std::sync::atomic::Ordering::SeqCst), 0, "nothing reached the app");
}

/// The same for a Codex desktop chat: a guest's prompt that waits for the owner's approval is
/// never queued for the thread.
#[cfg(unix)]
#[tokio::test]
async fn a_prompt_awaiting_the_owners_approval_never_reaches_the_codex_thread() {
    use crate::codex_desktop::tests as codex;
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let thread = "01a1bf30-0000-7000-8000-0000000a99e0";
    let dir = codex::home();
    let home = dir.path().to_path_buf();
    codex::state_db(&home, &[(thread, "codex_desktop", "/w", false)]);
    let _lock = codex::hold(&home, thread);
    let added = codex::fake_daemon(&home, |_| {});
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().codex = home.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(home.clone()), ..Default::default() })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some(thread.into());
        meta.tags
            .insert("bridge".into(), crate::store::Tag { value: "codex".into(), expires_at: None });
        meta.watching = Some(Watching {
            family: "codex".into(),
            file: home.join("rollout.jsonl"),
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    let guest = json!({"kind": "person_message", "from": "guest:k3x9", "fromName": "Cy",
        "approval": "owner"});
    let opts = PromptOptions { provenance: Some(guest), ..Default::default() };
    let blocks = vec![json!({"type": "text", "text": "run this"})];
    let err = hub.prompt_with(&session, blocks, "test", false, opts).await;
    assert!(err.unwrap_err().message.contains("watch.read_only"));
    assert!(added.lock().unwrap().is_empty(), "nothing reached the thread");
}


/// Review of #38393 at e63236a (F1): a bridged prompt passes the dispatch gate every prompt
/// passes (`check_dispatch`): a Web prompt to a chat whose Web control ended since the request's
/// own check is refused and never reaches the app.
#[cfg(unix)]
#[tokio::test]
async fn a_prompt_the_dispatch_gate_refuses_never_reaches_the_app() {
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let config = scratch("dispatch");
    let transcript = config.join("sid-d.jsonl");
    std::fs::write(&transcript, "").unwrap();
    let inbox = fake_claude(&config, "sid-d", transcript.clone());
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().claude = config.clone();
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(config.clone()), ..Default::default() })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some("sid-d".into());
        meta.tags.insert(
            "bridge".into(),
            crate::store::Tag { value: "claude".into(), expires_at: None },
        );
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: transcript,
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    session.web_control_ended.store(true, std::sync::atomic::Ordering::SeqCst);
    let opts = PromptOptions { control: crate::hub::Control::Web, ..Default::default() };
    let blocks = vec![json!({"type": "text", "text": "run this"})];
    let err = hub.prompt_with(&session, blocks, "test", false, opts).await.unwrap_err();
    // Refused by the gate (whichever of its Web rules reads first), not by the watch.
    assert!(!err.message.contains("watch.read_only"), "{}", err.message);
    assert!(!err.message.contains("bridge.undelivered"), "{}", err.message);
    assert_eq!(inbox.load(std::sync::atomic::Ordering::SeqCst), 0, "nothing reached the app");
}
