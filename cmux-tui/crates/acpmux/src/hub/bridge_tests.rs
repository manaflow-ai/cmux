use super::*;
use crate::config::{Config, StoreMode};
use crate::store::{MemoryStore, Watching};
use std::io::{BufRead, Write};
use std::path::PathBuf;

#[test]
fn only_text_blocks_are_carried() {
    let blocks = [
        json!({"type": "text", "text": "one"}),
        json!({"type": "image", "data": "..."}),
        json!({"type": "text", "text": "two"}),
    ];
    assert_eq!(text_of(&blocks), "one\n\ntwo");
}

#[test]
fn a_delivery_is_found_by_its_uuid_in_its_own_session_only() {
    pending().insert(
        "u-find".into(),
        Pending { session_id: "s1".into(), prompt_id: "p1".into(), text: "hi".into(), done: None },
    );
    assert_eq!(delivered("s1", "u-find"), Some(("p1".into(), "hi".into())));
    assert_eq!(delivered("s2", "u-find"), None);
    answered("s1", "p1", "t1");
    assert_eq!(delivered("s1", "u-find"), None, "an answered delivery is done");
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
fn fake_claude(config: &std::path::Path, sid: &str, transcript: PathBuf) {
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
    fake_claude(&config, "sid-1", transcript.clone());

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
    assert_eq!(user.data["promptId"], "p-desk");
    assert_eq!(user.data["text"], "ping from acpmux");
    assert_eq!(user.data["client"], "bridge");
    assert!(events.iter().any(|e| e.kind == "bridge_delivered"));
    assert!(
        events.iter().any(|e| e.kind == "agent_message_chunk"
            && e.data.pointer("/params/update/content/text") == Some(&json!("PONG"))),
        "the answer shows"
    );
    assert!(events.iter().any(|e| e.kind == "turn_result" && e.data["promptId"] == "p-desk"));
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
