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
    assert_eq!(delivered("s1", "u-find"), Some(("u-find".into(), "p1".into(), "hi".into())));
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
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
    let entry = json!({"pid": pid, "sessionId": sid, "cwd": "/w", "entrypoint": "claude-desktop",
        "messagingSocketPath": sock, "startedAt": u64::try_from(now.as_millis()).unwrap()});
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
            ..Default::default()
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

/// A peer's outbox sends an open delivery again under its own prompt id on every link of the
/// peer (`open_delivery.rs`) and relies on the target to answer a resend with the first outcome.
/// A daemon that restarted since the delivery (or kept so many newer ones that it let it go) has
/// no memory of it: its session's log still says it went, so it is not delivered again
/// (cmuxterm-hq#10904: lane reports reached their coordinator three and four times, the same
/// prompt id under a new uuid each time, after the coordinator's daemon restarted).
#[cfg(unix)]
#[tokio::test]
async fn a_resend_after_the_daemon_forgot_the_delivery_is_not_delivered_again() {
    crate::claude_peers::TEST_ENABLED.store(true, std::sync::atomic::Ordering::SeqCst);
    let config = scratch("restart");
    let transcript = config.join("sid-r.jsonl");
    std::fs::write(&transcript, "").unwrap();
    let inbox = fake_claude(&config, "sid-r", transcript.clone());

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
        meta.agent_session_id = Some("sid-r".into());
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
            ..Default::default()
        });
    }
    hub.save_meta(&session);
    hub.start_watch(&session);

    let send = |hub: Arc<Hub>, session: Arc<Session>| async move {
        let opts = PromptOptions { prompt_id: Some("p-report".into()), ..Default::default() };
        let blocks = vec![json!({"type": "text", "text": "lane report"})];
        tokio::time::timeout(
            Duration::from_secs(20),
            hub.prompt_with(&session, blocks, "outbox", false, opts),
        )
        .await
        .expect("answered within 20 s")
        .unwrap()
    };
    let first = send(hub.clone(), session.clone()).await;
    assert_eq!(first["_meta"]["acpmux"]["answered"], true, "{first}");
    assert_eq!(inbox.load(std::sync::atomic::Ordering::SeqCst), 1);

    // What a daemon restart forgets: every delivery this process kept for the session.
    deliveries().by_uuid.retain(|_, p| p.session_id != session.id);
    forget_delivered_ids(&session.id);

    let again = send(hub.clone(), session.clone()).await;
    assert_eq!(again["_meta"]["acpmux"]["duplicate"], true, "{again}");
    assert_eq!(
        inbox.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "the same prompt id reached the app twice"
    );
    let events = hub.store.events(&session.id, 0, usize::MAX).unwrap();
    let delivered = events.iter().filter(|e| e.kind == "bridge_delivered").count();
    assert_eq!(delivered, 1, "one delivery is logged");
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
            ..Default::default()
        });
    }
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let err = hub.prompt_with(&session, blocks, "test", false, PromptOptions::default()).await;
    assert!(err.unwrap_err().message.contains("watch.read_only"));
}

/// A chat its session registered keeps its name while its app is not running: the prompt is
/// refused as retryable, so the outbox keeps it queued and tries again.
#[tokio::test]
async fn a_registered_chat_whose_app_is_not_running_waits_instead_of_failing() {
    let config = scratch("registered-gone");
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
        meta.agent_session_id = Some("closed-desktop".into());
        for (k, v) in [("bridge", "claude"), (crate::hub::register::REGISTERED_TAG, "true")] {
            meta.tags.insert(k.into(), crate::store::Tag { value: v.into(), expires_at: None });
        }
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: config.join("x.jsonl"),
            offset: 0,
            codex_items: false,
            open: None,
            ..Default::default()
        });
    }
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    // The tag alone (any client may set tags) registers nothing.
    let err = hub
        .prompt_with(&session, blocks.clone(), "acpmux-outbox#0", false, PromptOptions::default())
        .await
        .unwrap_err();
    assert!(err.message.contains("watch.read_only"), "tag only: {}", err.message);
    crate::hub::register::mark_registered_for_test(&session.id);
    let err = hub
        .prompt_with(&session, blocks.clone(), "test", false, PromptOptions::default())
        .await
        .unwrap_err();
    assert!(err.message.contains("watch.read_only"), "a person's prompt: {}", err.message);
    let err = hub
        .prompt_with(&session, blocks, "acpmux-outbox#1", false, PromptOptions::default())
        .await
        .unwrap_err();
    assert!(err.message.contains("bridge.not_running"), "{}", err.message);
    let data = err.data.unwrap();
    assert_eq!(data["reason"], "bridge.not_running");
    assert_eq!(data["retryable"], true, "the outbox tries it again");
    // Repro: a client removes the tag (any client may edit tags). The daemon's record still
    // says registered, so the chat stays on the registered path (it waits for its own
    // registered process) and never falls back to entrypoint listing.
    session.meta.lock().unwrap().tags.remove(crate::hub::register::REGISTERED_TAG);
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let err = hub
        .prompt_with(&session, blocks, "acpmux-outbox#3", false, PromptOptions::default())
        .await
        .unwrap_err();
    assert!(err.message.contains("bridge.not_running"), "tag removed: {}", err.message);
}

/// A registered chat whose live process handed over no token (a restarted session that has not
/// registered again) waits instead of opening with the undocumented peer key.
#[cfg(unix)]
#[tokio::test]
async fn a_registered_chat_with_no_token_from_its_process_waits_for_register() {
    let config = scratch("registered-no-token");
    let transcript = config.join("sid-r.jsonl");
    std::fs::write(&transcript, "").unwrap();
    let inbox = fake_claude(&config, "sid-r", transcript.clone());
    // A terminal session: an entrypoint no bridge setting lists, so only register reaches it.
    let entry = config.join(format!("sessions/{}.json", std::process::id()));
    let mut doc: Value = serde_json::from_slice(&std::fs::read(&entry).unwrap()).unwrap();
    doc["entrypoint"] = json!("cli");
    std::fs::write(&entry, doc.to_string()).unwrap();
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
        meta.agent_session_id = Some("sid-r".into());
        for (k, v) in [("bridge", "claude"), (crate::hub::register::REGISTERED_TAG, "true")] {
            meta.tags.insert(k.into(), crate::store::Tag { value: v.into(), expires_at: None });
        }
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: transcript,
            offset: 0,
            codex_items: false,
            open: None,
            ..Default::default()
        });
    }
    crate::hub::register::mark_registered_for_test(&session.id);
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let err = hub
        .prompt_with(&session, blocks, "acpmux-outbox#2", false, PromptOptions::default())
        .await
        .unwrap_err();
    assert!(err.message.contains("bridge.not_running"), "{}", err.message);
    assert_eq!(inbox.load(std::sync::atomic::Ordering::SeqCst), 0, "nothing opened its inbox");
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
            ..Default::default()
        });
    }
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let err = hub.prompt_with(&session, blocks, "test", false, PromptOptions::default()).await;
    assert!(err.unwrap_err().message.contains("watch.read_only"));
    assert_eq!(inbox.load(std::sync::atomic::Ordering::SeqCst), 0, "nothing reached the app");
}

#[test]
fn an_agents_message_tells_the_app_how_to_answer_and_the_persons_goes_as_typed() {
    assert_eq!(with_reply_hint("hi", None, None, false, false), "hi");
    assert_eq!(with_reply_hint("hi", Some("  "), None, false, true), "hi");
    let hinted = with_reply_hint("hi", Some("cosmic-gray/claude-sr2-coord"), None, false, false);
    assert!(
        hinted.starts_with(
            "From another agent (cosmic-gray/claude-sr2-coord), not the person:\nhi\n\n"
        ),
        "{hinted}"
    );
    let named = with_reply_hint("hi", Some("desktop-zoe"), Some("claude"), false, false);
    assert!(named.starts_with("From another agent (desktop-zoe, claude), not the person:\nhi"));
    let claimed = with_reply_hint("hi", Some("bot"), None, true, false);
    assert!(claimed.starts_with("From a program that calls itself bot, not the person:\nhi"));
    assert!(hinted.contains("`acpmux send 'cosmic-gray/claude-sr2-coord' '<your reply>'`"));
    let quoted = with_reply_hint("hi", Some("it's"), None, false, false);
    assert!(quoted.contains(r"`acpmux send 'it'\''s' "), "{quoted}");
}

/// Claude Code wraps every peer message in its own "Another Claude session sent a message:" and
/// a paragraph saying a peer is not the user (ask-c810e83a38): acpmux's part is one line, the
/// sender and how to answer, then the text, with nothing after it.
#[test]
fn a_claude_code_session_gets_the_sender_and_the_answer_in_one_line() {
    let named = with_reply_hint("PR is green", Some("gcp/lane-12"), Some("codex"), false, true);
    assert_eq!(
        named,
        "From another agent (gcp/lane-12, codex), not the person. Answer with `acpmux send 'gcp/lane-12' '<your reply>'`, not SendMessage:\nPR is green"
    );
    assert!(!named.contains("cannot reach it"), "{named}");
    // A program acpmux could not verify says so too.
    let claimed = with_reply_hint("hi", Some("bot"), None, true, true);
    assert_eq!(
        claimed,
        "From a program that calls itself bot, not the person. Answer with `acpmux send 'bot' '<your reply>'`, not SendMessage:\nhi"
    );
    let quoted = with_reply_hint("hi", Some("it's"), None, false, true);
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
            ..Default::default()
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
    assert_eq!(
        delivered_text("sc", " hi\n\n[hint] "),
        Some(("u-c1".into(), "pc1".into(), "hi".into()))
    );
    assert_eq!(
        delivered_text("sc", "hi\n\n[hint]"),
        Some(("u-c2".into(), "pc2".into(), "hi".into()))
    );
    assert_eq!(delivered_text("sc", "hi\n\n[hint]"), None, "each line shows one delivery");
}

/// A queue line may be a delivery's only by its exact text (review P1-F1, P2-F3): one that merely
/// contains a delivery's text is the terminal's own.
#[test]
fn a_queue_line_may_be_a_deliverys_only_by_exact_text() {
    deliveries().claim("u-q1".into(), "sq", "pq1", "test", "test").unwrap();
    assert!(!may_be_delivery("sq", "please test the migration"), "containment is not it");
    assert!(!may_be_delivery("other", "test"));
    assert!(may_be_delivery("sq", " test "));
    // Taken in by a turn as not the person's, with no uuid acpmux sent: shown once, under its id.
    assert_eq!(delivered_queued("sq", "test"), Some(("u-q1".into(), "pq1".into(), "test".into())));
    assert_eq!(delivered_queued("sq", "test"), None);
    assert!(!may_be_delivery("sq", "test"), "shown: any later line is typed");
}

/// A delivery taken back in the terminal before it ran ends with why at once (review P2-F2).
#[test]
fn a_delivery_taken_back_in_the_terminal_ends_with_why() {
    let rx = deliveries().claim("u-t1".into(), "st", "pt1", "later", "later").unwrap();
    assert!(!taken_back("st", "other text"));
    assert!(taken_back("st", "later"));
    assert!(matches!(&*rx.borrow(), Some(Err(why)) if why.contains("taken back")));
    assert!(!taken_back("st", "later"), "once");
}

/// A batch the journal refused gives back what it claimed, so the batch read again shows the
/// delivery (review P1-F2).
#[test]
fn a_refused_batch_gives_its_claims_back() {
    deliveries().claim("u-r1".into(), "sr", "pr1", "hi", "hi").unwrap();
    let shown = delivered("sr", "u-r1").unwrap();
    assert!(delivered("sr", "u-r1").is_none());
    unclaim(&[Claim::Shown(shown.0)]);
    assert!(delivered("sr", "u-r1").is_some(), "given back: it shows by its line");
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
            ..Default::default()
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
    assert!(
        sent.starts_with("From another agent (desktop cmux), not the person:\nping from claude\n\n[Answer desktop cmux"),
        "{sent}"
    );
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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

/// The app answers the chat a verified session message came from, by its name, not the label
/// the sender gave (a bridged desktop chat's label names no session).
#[test]
fn the_reply_goes_to_the_verified_senders_chat_by_name() {
    let label = "Claude Code desktop on host \u{b7} 75d05154";
    let bound = crate::prompt_provenance::session_message("chat-1", "work-f5", "chat-2");
    let agent = Some(label.to_owned());
    let opts = PromptOptions { agent, provenance: Some(bound), ..Default::default() };
    assert_eq!(reply_name(&opts).as_deref(), Some("work-f5"));
    let declared = PromptOptions { agent: Some(label.into()), ..Default::default() };
    assert_eq!(reply_name(&declared).as_deref(), Some(label));
    let unverified = json!({"kind": "session_message", "from": "x", "fromName": "forged"});
    let agent = Some(label.to_owned());
    let opts = PromptOptions { agent, provenance: Some(unverified), ..Default::default() };
    assert_eq!(reply_name(&opts).as_deref(), Some(label));
}

/// A Codex chat handed to a cmux terminal (`release_to_watch.rs`): the terminal's `codex resume`
/// (originator `codex-tui`, which no listing names) holds the thread, and the chat's prompt goes
/// into its queue (`thread/queue/add`), which a terminal Codex runs after its turn (measured with
/// Codex 0.164 on 2026-11-14), with no bridge setting and no tag. Once that terminal's process is
/// gone the chat is a watch as any other.
#[cfg(unix)]
#[tokio::test]
async fn a_codex_chat_its_terminal_drives_takes_prompts_into_that_terminals_queue() {
    use crate::codex_desktop::tests as codex;
    let thread = "01a1bf30-0000-7000-8000-00000000fe11";
    let dir = codex::home();
    let home = dir.path().to_path_buf();
    codex::state_db(&home, &[(thread, "codex-tui", "/w", false)]);
    let _lock = codex::hold(&home, thread);
    let rollout = home.join("rollout.jsonl");
    std::fs::write(&rollout, "").unwrap();
    let written = rollout.clone();
    let added = codex::fake_daemon(&home, move |params| {
        let text = params["input"][0]["text"].as_str().unwrap();
        let user =
            json!({"type": "event_msg", "payload": {"type": "user_message", "message": text}});
        let answer =
            json!({"type": "event_msg", "payload": {"type": "agent_message", "message": "OK"}});
        let end = json!({"type": "event_msg", "payload": {"type": "task_complete"}});
        let mut f = std::fs::OpenOptions::new().append(true).open(&written).unwrap();
        writeln!(f, "{user}\n{answer}\n{end}").unwrap();
    });
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.set_terminal_chat_writable(true).await;
    let session = hub
        .new_session(crate::hub::NewRequest { cwd: Some(home.clone()), ..Default::default() })
        .await
        .unwrap();
    let pid = std::process::id();
    let terminal = crate::store::TerminalDriver {
        pid,
        started: crate::adopt_live::pid_start_ms(pid),
        store: home.clone(),
    };
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some(thread.into());
        meta.watching = Some(Watching {
            family: "codex".into(),
            file: rollout,
            terminal: Some(terminal.clone()),
            ..Default::default()
        });
    }
    hub.save_meta(&session);
    hub.start_watch(&session);
    let opts = PromptOptions { prompt_id: Some("p-term".into()), ..Default::default() };
    let blocks = vec![json!({"type": "text", "text": "from the chat"})];
    let reply = tokio::time::timeout(
        Duration::from_secs(20),
        hub.prompt_with(&session, blocks, "test", false, opts),
    )
    .await
    .expect("answered within 20 s")
    .unwrap();
    assert_eq!(reply["_meta"]["acpmux"]["answered"], true, "{reply}");
    let sent = added.lock().unwrap().clone();
    assert_eq!(sent.len(), 1, "queued once");
    assert_eq!(sent[0]["threadId"], thread);
    assert_eq!(sent[0]["input"][0]["text"], "from the chat", "as typed: no reply hint");
    let events = hub.store.events(&session.id, 0, usize::MAX).unwrap();
    let users: Vec<_> = events.iter().filter(|e| e.kind == "user_message").collect();
    assert_eq!(users.len(), 1, "shown once");
    assert_eq!(users[0].msg["promptId"], "p-term");

    // A paired device never sends into the terminal: its agent asks for permission there, outside
    // the remote floor, whatever mode the chat had.
    let web = PromptOptions { control: crate::hub::Control::Web, ..Default::default() };
    let blocks = vec![json!({"type": "text", "text": "from a phone"})];
    let refused = hub.prompt_with(&session, blocks, "test", false, web).await.unwrap_err();
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "remote.terminal_session", "{refused:?}");
    assert_eq!(added.lock().unwrap().len(), 1, "nothing from the phone reached the terminal");

    // A later process under the terminal's pid is not it: the binding's start time says so.
    {
        let mut meta = session.meta.lock().unwrap();
        let w = meta.watching.as_mut().unwrap();
        w.terminal = Some(crate::store::TerminalDriver {
            started: terminal.started.map(|s| s.saturating_sub(60_000)),
            ..terminal
        });
    }
    let blocks = vec![json!({"type": "text", "text": "late"})];
    let err = hub.prompt_with(&session, blocks, "test", false, PromptOptions::default()).await;
    assert!(err.unwrap_err().message.contains("watch.read_only"));
    assert_eq!(added.lock().unwrap().len(), 1, "nothing more reached the terminal");
}
