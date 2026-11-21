//! A Codex chat forked while its turn runs (https://github.com/manaflow-ai/cmux/issues/44987):
//! the fork is its own Codex thread holding the chat's conversation, and it carries no
//! "cannot fork a chat mid-turn" note.

use super::*;

/// The `forked` record's note on the fork `fid`, if it has one.
fn fork_note(hub: &Arc<Hub>, fid: &str) -> Option<String> {
    hub.events(fid, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "forked")
        .find_map(|e| e.msg["note"].as_str().map(str::to_owned))
}

/// Whether the fork `fid` started a fresh agent session fed acpmux's transcript.
fn rehydrated(hub: &Arc<Hub>, fid: &str) -> bool {
    hub.events(fid, 0, 10_000)
        .unwrap()
        .iter()
        .any(|e| e.dir == "mux" && e.kind == "resumed" && e.msg["level"] == "rehydrate")
}

/// A new Codex chat in `c` with its `hold` turn running ("hold" or "hold-unstored"); returns its
/// id.
async fn holding_chat(c: &mut TestClient, first: Option<&str>, hold: &str) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    if let Some(text) = first {
        let r = c
            .request(
                method::SESSION_PROMPT,
                json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
            )
            .await
            .unwrap();
        assert_eq!(r["stopReason"], "end_turn", "{r}");
    }
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": hold}]}),
    )
    .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "holding").await;
    id
}

/// Codex compresses a thread's rollout (`local_thread_store_compression`) minutes after it is
/// written, so a chat's rollout is often `rollout-…-<thread>.jsonl.zst`. A fork mid-turn found no
/// `.jsonl`, fell back to a fresh agent fed acpmux's transcript and said "codex cannot fork a chat
/// mid-turn". Now it copies the compressed rollout: its own thread, loaded exactly, holding the
/// chat's turns, and no note.
#[tokio::test]
async fn a_working_codex_chat_whose_rollout_codex_compressed_forks_its_own_thread() {
    let root = std::env::temp_dir().join(format!("acpmux-codex-fork-zst-{}", uuid::Uuid::now_v7()));
    let codex = root.join("codex");
    std::fs::create_dir_all(&codex).unwrap();
    let (hub, mut c) = codex_setup(&codex).await;
    let id = holding_chat(&mut c, Some("first"), "hold").await;
    let parent_thread = hub.resolve(&id).unwrap().meta().agent_session_id.unwrap();

    // Codex's compression: the rollout becomes `.jsonl.zst` and the plain file goes.
    let plain = codex_rollouts(&codex, &format!("-{parent_thread}.jsonl"));
    assert_eq!(plain.len(), 1, "{plain:?}");
    let bytes = std::fs::read(&plain[0]).unwrap();
    let packed = zstd::stream::encode_all(&bytes[..], 3).unwrap();
    std::fs::write(plain[0].with_extension("jsonl.zst"), packed).unwrap();
    std::fs::remove_file(&plain[0]).unwrap();

    let f = c
        .request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()}))
        .await
        .unwrap_or_else(|e| panic!("a working Codex chat forks: {e}"));
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(fork_note(&hub, &fid), None, "a real fork says nothing about a transcript");
    let thread = hub.resolve(&fid).unwrap().meta().agent_session_id.unwrap();
    assert_ne!(thread, parent_thread, "the fork is its own thread");
    assert_eq!(codex_rollouts(&codex, &format!("-{thread}.jsonl")).len(), 1, "{thread}");

    let fork = claude_history(&hub, &mut c, &fid).await;
    assert_eq!(
        fork["prompts"],
        json!(["first", "hold"]),
        "the fork holds the chat's turns: {fork}"
    );
    assert_eq!(fork["sessions"], json!([thread]), "{fork}");
    assert!(!rehydrated(&hub, &fid), "the fork fell back to acpmux's transcript");
    assert_eq!(
        hub.resolve(&id).unwrap().meta().status,
        acpmux::store::SessionStatus::Running,
        "the chat's turn goes on"
    );
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A chat forked in the first moments of its first turn, before Codex wrote any of it (the
/// issue's second case): acpmux's transcript is the whole chat, so the fork starts from it and
/// carries no "cannot fork mid-turn" note. Before, it said Codex cannot fork mid-turn.
#[tokio::test]
async fn a_codex_chat_forked_in_its_first_turn_carries_no_mid_turn_note() {
    let root =
        std::env::temp_dir().join(format!("acpmux-codex-fork-first-{}", uuid::Uuid::now_v7()));
    let codex = root.join("codex");
    std::fs::create_dir_all(&codex).unwrap();
    let (hub, mut c) = codex_setup(&codex).await;
    let id = holding_chat(&mut c, None, "hold-unstored").await;
    let f = c
        .request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()}))
        .await
        .unwrap_or_else(|e| panic!("a Codex chat forks in its first turn: {e}"));
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(fork_note(&hub, &fid), None, "nothing was lost, so nothing is said");
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let _ = std::fs::remove_dir_all(&root);
}
