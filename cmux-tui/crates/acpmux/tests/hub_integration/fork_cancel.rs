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
            hub.events(&id, 0, 100_000).unwrap().into_iter().filter(|e| e.kind == "turn_result");
        json!({"sessionId": id, "throughSeq": end.last().unwrap().seq})
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

/// Cancel by the token the fork's request named it with, sent while acpmux makes it (review of
/// #36979: Cancel only hid the line and the copy went on). Whenever it lands (during the copy,
/// after the fork is made, or after its answer), no fork is left, and the chat goes on.
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
    let started = std::time::Instant::now();
    loop {
        let r = c.request(method::MUX_KILL, cancel.clone()).await.unwrap();
        if r["cancelled"] == true {
            break;
        }
        // The fork's request has not named it yet.
        assert!(started.elapsed() < Duration::from_secs(10), "no fork took the token");
        tokio::task::yield_now().await;
    }
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
    // A token whose fork is gone names nothing to stop, and the chat goes on.
    let r = c.request(
        method::MUX_KILL,
        json!({"sessionId": id, "cancelFork": true, "cancelToken": "other"}),
    );
    assert_eq!(r.await.unwrap()["cancelled"], false);
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "after"}]});
    assert_eq!(c.request(method::SESSION_PROMPT, prompt).await.unwrap()["stopReason"], "end_turn");
    let _ = std::fs::remove_dir_all(&root);
}
