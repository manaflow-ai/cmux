//! A Claude turn that ends with a steer unread (`claude_stdio/carry.rs`): the host reads
//! nothing more of Claude Code's output until the next turn's prompt comes, so what Claude says
//! in that turn is logged in it, never in the turn that ended (Leo, 2026-10-29: "you clearly
//! just ended some fucking turns, and it still fucking shows this.").

use super::*;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

fn claude_spec(dir: &Path, session: &str) -> SpawnSpec {
    let mut spec = spec(dir, session);
    spec.args = vec![FAKE_CLAUDE.into()];
    spec.env.push(("CLAUDE_CONFIG_DIR".into(), dir.join("claude").to_string_lossy().into_owned()));
    spec.translator = Some(agent_host::TranslatorSpec {
        acp_session_id: "acp-1".into(),
        mode: "default".into(),
        model: "haiku".into(),
        effort: "default".into(),
        fast: false,
        claude_session_id: None,
    });
    spec
}

fn prompt(text: &str, meta: Value) -> Value {
    json!({"sessionId": "acp-1", "prompt": [{"type": "text", "text": text}], "_meta": meta})
}

fn written(e: &Entry, text: &str) -> bool {
    matches!(e, Entry::Tap { dir: TapDir::Out, msg } if msg.to_string().contains(text))
}

#[tokio::test]
async fn claude_output_after_a_carry_waits_for_the_next_turns_prompt() {
    let dir = scratch("carry");
    let record = link::spawn(&launcher(), &claude_spec(&dir, "s-carry")).await.expect("spawn");
    let lock = live_lock(&dir, &record);
    let (owner, _) = connected(&record, 0).await;
    let mut logged = 0;
    let gate = dir.join("gate");
    request(&owner, 1, "session/prompt", prompt(&format!("gated: {}", gate.display()), json!({})))
        .await;
    read_until(&owner, &mut logged, |e| chunk_text(e).as_deref() == Some("gated turn 1")).await;
    let steer = json!({"steer": true, "promptId": "p-late"});
    request(&owner, 2, "session/prompt", prompt("LATE-1", steer)).await;
    read_until(&owner, &mut logged, |e| written(e, "LATE-1")).await;
    std::fs::write(format!("{}.1", gate.display()), "end").unwrap();
    let ended = read_until(&owner, &mut logged, |e| is_response(e, 1)).await;
    let Entry::In { msg } = &ended.last().unwrap().1 else { unreachable!() };
    let carry = msg["result"]["_meta"]["claude"]["carried"].clone();
    assert_eq!(carry["promptIds"], json!(["p-late"]), "{msg}");
    // Claude Code runs the steer now, but its output waits for the next turn's prompt.
    {
        let mut rx = owner.entries.lock().await;
        let early = tokio::time::timeout(Duration::from_millis(800), rx.recv()).await;
        assert!(early.is_err(), "read before the next turn's prompt: {early:?}");
    }
    let carried = json!({"sessionId": "acp-1", "prompt": [], "_meta": {"carried": true}});
    request(&owner, 3, "session/prompt", carried).await;
    let read =
        read_until(&owner, &mut logged, |e| chunk_text(e).as_deref() == Some("read: LATE-1")).await;
    let steered = read.iter().find(|(_, e)| is_response(e, 2));
    if let Some((_, Entry::In { msg })) = steered {
        assert_eq!(msg["result"]["_meta"]["claude"]["carried"], carry["seq"], "{msg}");
    } else {
        panic!("the steer was not answered at its echo: {read:?}");
    }
    std::fs::write(format!("{}.2", gate.display()), "read").unwrap();
    let rest = read_until(&owner, &mut logged, |e| is_response(e, 3)).await;
    let Entry::In { msg } = &rest.last().unwrap().1 else { unreachable!() };
    assert_eq!(msg["result"]["stopReason"], "end_turn", "{msg}");
    owner.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&owner, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A second carry while the first one's prompt is still to come, its hold's bound passed: its
/// output waits for its prompt too, with a hold of its own.
#[tokio::test]
async fn a_second_carry_holds_claude_output_again() {
    let dir = scratch("carry-twice");
    let record = link::spawn(&launcher(), &claude_spec(&dir, "s-carry-2")).await.expect("spawn");
    let lock = live_lock(&dir, &record);
    let (owner, _) = connected(&record, 0).await;
    let mut logged = 0;
    let gate = dir.join("gate");
    request(&owner, 1, "session/prompt", prompt(&format!("gated: {}", gate.display()), json!({})))
        .await;
    read_until(&owner, &mut logged, |e| chunk_text(e).as_deref() == Some("gated turn 1")).await;
    request(
        &owner,
        2,
        "session/prompt",
        prompt("LATE-1", json!({"steer": true, "promptId": "p-1"})),
    )
    .await;
    read_until(&owner, &mut logged, |e| written(e, "LATE-1")).await;
    std::fs::write(format!("{}.1", gate.display()), "end").unwrap();
    read_until(&owner, &mut logged, |e| is_response(e, 1)).await;
    // No carried prompt comes: past the hold's bound, the output is read.
    read_until(&owner, &mut logged, |e| chunk_text(e).as_deref() == Some("read: LATE-1")).await;
    request(
        &owner,
        3,
        "session/prompt",
        prompt("LATE-2", json!({"steer": true, "promptId": "p-2"})),
    )
    .await;
    read_until(&owner, &mut logged, |e| written(e, "LATE-2")).await;
    std::fs::write(format!("{}.2", gate.display()), "end").unwrap();
    // Claude Code runs LATE-2 as its next turn, but its words wait for that turn's prompt.
    {
        let mut rx = owner.entries.lock().await;
        let deadline = tokio::time::Instant::now() + Duration::from_millis(1_500);
        while let Ok(Some((h, e))) = tokio::time::timeout_at(deadline, rx.recv()).await {
            logged = h;
            assert_ne!(
                chunk_text(&e).as_deref(),
                Some("read: LATE-2"),
                "the second carry held nothing"
            );
        }
    }
    let carried = json!({"sessionId": "acp-1", "prompt": [], "_meta": {"carried": true}});
    request(&owner, 4, "session/prompt", carried.clone()).await;
    request(&owner, 5, "session/prompt", carried).await;
    read_until(&owner, &mut logged, |e| chunk_text(e).as_deref() == Some("read: LATE-2")).await;
    std::fs::write(format!("{}.3", gate.display()), "read").unwrap();
    read_until(&owner, &mut logged, |e| is_response(e, 5)).await;
    owner.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&owner, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}
