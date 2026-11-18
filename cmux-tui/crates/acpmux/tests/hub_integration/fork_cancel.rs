//! Fork Conversation's Cancel (`_acpmux/kill` with `cancelFork`, `hub/fork_cancel.rs`) and the
//! fork's quiet copy of its chat's history (`hub/fork.rs`). Leo, 2026-11-06: "forking text is
//! weird + it's so SLOW + i shuold be able to cancel a fork probably".

use super::*;

async fn chat_with_turns(c: &mut TestClient, turns: usize) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
    let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
    for turn in 0..turns {
        let text = if turn == 0 { "first".to_owned() } else { "burst: 40".to_owned() };
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    }
    id
}

/// The `.jsonl` transcripts under the Claude home, by file name.
fn transcripts(claude: &std::path::Path) -> Vec<String> {
    let mut found = Vec::new();
    let mut dirs = vec![claude.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|e| e == "jsonl") {
                found.push(path.file_name().unwrap().to_string_lossy().into_owned());
            }
        }
    }
    found.sort();
    found
}

/// Cancel takes the fork back whole: its chat is gone from the list and its store, and the
/// transcript copy its agent made is removed; the chat it came from keeps its own. Both kinds
/// the pane cancels: a fork of a working chat as it is now (`live`), and an idle chat's fork
/// from a reply (`throughSeq`, App.tsx `chat.fork` and `chat.forkTo`).
#[tokio::test]
async fn a_cancelled_fork_leaves_nothing_behind() {
    for live in [true, false] {
        a_cancelled_fork_leaves_nothing_behind_when(live).await;
    }
}

async fn a_cancelled_fork_leaves_nothing_behind_when(live: bool) {
    let root = std::env::temp_dir().join(format!("acpmux-fork-cancel-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let id = chat_with_turns(&mut c, 2).await;
    let before = transcripts(&claude);
    assert!(!before.is_empty(), "the chat has its transcript");

    let boundary = if live {
        json!({"sessionId": id, "live": true})
    } else {
        let end =
            hub.events(&id, 0, 100_000).unwrap().into_iter().rfind(|e| e.kind == "turn_result");
        json!({"sessionId": id, "throughSeq": end.unwrap().seq})
    };
    let f = c.request(FORK_OP, boundary).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert!(hub.resolve(&fid).unwrap().meta().fork_before.is_none());
    // The fork's agent starts after the answer: wait until it has made its copy.
    let started = std::time::Instant::now();
    while hub.resolve(&fid).unwrap().meta().agent_session_id.is_none()
        && started.elapsed() < Duration::from_secs(10)
    {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let r = c.request(method::MUX_KILL, json!({"sessionId": fid, "cancelFork": true})).await;
    assert_eq!(r.unwrap()["purged"], true);
    assert!(hub.resolve(&fid).is_err(), "the fork's chat is gone");
    assert!(hub.events(&fid, 0, 10).map(|e| e.is_empty()).unwrap_or(true), "its log is gone");
    assert_eq!(transcripts(&claude), before, "only the chat's own transcript is left");
    // The chat it came from goes on.
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "after"}]});
    assert_eq!(c.request(method::SESSION_PROMPT, prompt).await.unwrap()["stopReason"], "end_turn");
    let _ = std::fs::remove_dir_all(&root);
}

/// A fork the person already wrote to is their chat: Cancel refuses it, and a chat that is
/// not a fork is refused too. Both stay.
#[tokio::test]
async fn cancel_refuses_a_used_fork_and_a_chat_that_is_no_fork() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-used-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let id = chat_with_turns(&mut c, 1).await;
    let f = c.request(FORK_OP, json!({"sessionId": id, "live": true})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": fid, "prompt": [{"type": "text", "text": "mine now"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();

    let used = c.request(method::MUX_KILL, json!({"sessionId": fid, "cancelFork": true})).await;
    assert!(used.unwrap_err().contains("delete it instead"));
    assert!(hub.resolve(&fid).is_ok());
    let chat = c.request(method::MUX_KILL, json!({"sessionId": id, "cancelFork": true})).await;
    assert!(chat.unwrap_err().contains("only a fork"));
    assert!(hub.resolve(&id).is_ok());

    // By its token too: a fork used since it was made is refused, not answered as cancelled
    // (review of #36979: the token's Cancel said cancelled and the fork stayed).
    let request = json!({"sessionId": id, "live": true, "cancelToken": "used-1"});
    let f = c.request(FORK_OP, request).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": fid, "prompt": [{"type": "text", "text": "mine too"}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    let by_token = json!({"sessionId": id, "cancelFork": true, "cancelToken": "used-1"});
    let refused = c.request(method::MUX_KILL, by_token).await;
    assert!(refused.unwrap_err().contains("delete it instead"));
    assert!(hub.resolve(&fid).is_ok());
    let _ = std::fs::remove_dir_all(&root);
}

/// The fork's copy of a long chat reaches a watching app as one change, not one notification
/// per copied record: before, each copied turn's records each sent the app a summary.
#[tokio::test]
async fn a_watcher_hears_a_fork_once_not_its_copied_history() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-quiet-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let id = chat_with_turns(&mut c, 30).await;
    let mut app = super::usage_stats::connect(&hub).await;
    app.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();

    let f = c.request(FORK_OP, json!({"sessionId": id, "live": true})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    tokio::time::sleep(Duration::from_millis(300)).await;
    let mut about_fork = 0;
    while let Ok(line) = app.rx.try_recv() {
        let note: Value = serde_json::from_str(&line).unwrap();
        if note.pointer("/params/sessionId").and_then(Value::as_str) == Some(fid.as_str())
            && note["params"]["kind"] != "status"
        {
            about_fork += 1;
        }
    }
    // The fork holds the chat's 30 turns all the same.
    let copied = hub.events(&fid, 0, 100_000).unwrap();
    let turns = copied.iter().filter(|e| e.kind == "turn_result").count();
    assert_eq!(turns, 30, "the fork holds every turn");
    assert!(about_fork <= 3, "the watcher heard {about_fork} changes of the fork, not one or so");
    let _ = std::fs::remove_dir_all(&root);
}

/// Cancel by the token the fork's request named it with, sent once while acpmux makes it (review
/// of #36979: Cancel only hid the line and the copy went on). Whenever it lands (before the
/// request, during admission or the copy, after the fork is made, or after its answer), no fork
/// is left, and the chat goes on.
#[tokio::test]
async fn a_fork_cancelled_while_it_is_made_leaves_nothing() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-stop-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let id = chat_with_turns(&mut c, 30).await;
    let chats = hub.sessions().len();

    let mut forking = super::usage_stats::connect(&hub).await;
    let request = json!({"sessionId": id, "live": true, "cancelToken": "stop-1"});
    let fork = tokio::spawn(async move { forking.request(FORK_OP, request).await });
    let cancel = json!({"sessionId": id, "cancelFork": true, "cancelToken": "stop-1"});
    // Sent once, as the pane does: before the fork's request came, while it is admitted or
    // copied, or after it is made, it stops the fork (review of #36979, round 4: a Cancel while
    // the fork was admitted was lost).
    tokio::task::yield_now().await;
    let r = c.request(method::MUX_KILL, cancel).await.unwrap();
    assert_eq!(r["cancelled"], true, "{r}");
    match fork.await.unwrap() {
        // Stopped while it was made: refused, and discarded whole.
        Err(e) => assert!(format!("{e:?}").contains("fork.cancelled"), "{e:?}"),
        // Made before the cancel came: taken back.
        Ok(made) => {
            let fid = made["sessionId"].as_str().unwrap();
            assert!(hub.resolve(fid).is_err(), "the made fork was not taken back");
        }
    }
    // The discard of a fork stopped before it was published finishes on its own task.
    let started = std::time::Instant::now();
    while hub.sessions().len() != chats && started.elapsed() < Duration::from_secs(10) {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(hub.sessions().len(), chats, "a fork was left");
    // A Cancel that comes before its fork's request (it may come on another connection): the
    // fork is refused when it comes, and nothing is made.
    let early = json!({"sessionId": id, "cancelFork": true, "cancelToken": "early-1"});
    assert_eq!(c.request(method::MUX_KILL, early).await.unwrap()["cancelled"], true);
    let late = json!({"sessionId": id, "live": true, "cancelToken": "early-1"});
    let refused = c.request(FORK_OP, late).await.unwrap_err();
    assert!(format!("{refused:?}").contains("fork.cancelled"), "{refused:?}");
    assert_eq!(hub.sessions().len(), chats, "a fork cancelled first was made");
    // The chat goes on.
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "after"}]});
    assert_eq!(c.request(method::SESSION_PROMPT, prompt).await.unwrap()["stopReason"], "end_turn");
    let _ = std::fs::remove_dir_all(&root);
}

/// A fork of a chat whose tool call runs settles that call and ends the turn in its copy, and no
/// listener of the hub hears any of it: the first record of the fork it carries is `forked`
/// (review of #36979, F1: the fork's cut-off records each woke every connection before it).
#[tokio::test]
async fn nothing_hears_a_running_turn_s_fork_before_it_is_made() {
    let root = std::env::temp_dir().join(format!("acpmux-fork-quiet-cut-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let id = chat_with_turns(&mut c, 1).await;
    let gate = root.join("gate");
    let hold = format!("tool-hold: {}", gate.display());
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": hold}]}),
    )
    .await;
    for _ in 0..500 {
        if hub.events(&id, 0, 10_000).unwrap().iter().any(|e| e.kind == "tool_call") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let mut events = hub.subscribe();

    let f = c.request(FORK_OP, json!({"sessionId": id, "live": true})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let mut heard = Vec::new();
    while let Ok(event) = events.try_recv() {
        if event.session_id == fid {
            heard.push(event.record.kind.clone());
        }
    }
    let fork = hub.events(&fid, 0, 10_000).unwrap();
    assert!(
        fork.iter().any(|e| e.kind == "turn_result" && e.msg["detail"] == "forked"),
        "the fork's copy ends the running turn"
    );
    assert!(
        fork.iter().any(|e| e.kind == "tool_call_update"
            && e.msg.pointer("/params/update/status") == Some(&json!("failed"))),
        "the fork's copy settles the running tool call"
    );
    assert_eq!(
        heard.first().map(String::as_str),
        Some("forked"),
        "heard before the fork was made: {heard:?}"
    );
    std::fs::write(&gate, "").unwrap();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
