//! `_acpmux/ask`: a side question about a chat (`hub/aside.rs`). It is
//! answered from the chat's finished turns and leaves no trace in the chat,
//! in the session list or in Claude's own store.

use super::*;

const ASK: &str = "_acpmux/ask";

fn prompt(id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]})
}

fn ask(id: &str, text: &str) -> Value {
    json!({"sessionId": id, "text": text})
}

/// The Claude conversations in fake_claude.py's store.
fn transcripts(claude: &std::path::Path) -> usize {
    std::fs::read_dir(claude.join("projects").join("p")).unwrap().count()
}

async fn new_chat(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn a_side_question_about_a_claude_chat_sees_its_turns_and_leaves_no_trace() {
    let root = std::env::temp_dir().join(format!("acpmux-aside-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let id = new_chat(&mut c).await;
    for text in ["first", "second"] {
        c.request(method::SESSION_PROMPT, prompt(&id, text)).await.unwrap();
    }
    let stored = transcripts(&claude);

    let answer = c.request(ASK, ask(&id, "history-probe")).await.unwrap();
    assert_eq!(answer["sessionId"], id.as_str());
    let seen: Value = serde_json::from_str(answer["text"].as_str().unwrap()).unwrap();
    assert_eq!(seen["prompts"], json!(["first", "second"]), "{answer}");

    assert_eq!(user_messages(&hub, &id), 2, "the question is not in the chat");
    assert_eq!(hub.resolve(&id).unwrap().meta().turn_count, 2);
    let ids: Vec<String> = hub.sessions().iter().map(|s| s.id.clone()).collect();
    assert_eq!(ids, vec![id.clone()], "the question's fork is gone");
    assert_eq!(transcripts(&claude), stored, "Claude's store keeps no copy");
    let own = claude_history(&hub, &mut c, &id).await;
    assert_eq!(own["prompts"], json!(["first", "second"]), "the chat's conversation never saw it");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_side_question_while_a_claude_turn_runs_sees_the_finished_turns() {
    let root = std::env::temp_dir().join(format!("acpmux-aside-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let id = new_chat(&mut c).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "first")).await.unwrap();
    let gate = root.join("gate");
    c.send(method::SESSION_PROMPT, prompt(&id, &format!("hold: {}", gate.display()))).await;
    for _ in 0..250 {
        if user_messages(&hub, &id) == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(user_messages(&hub, &id), 2, "the second turn started");

    let answer = c.request(ASK, ask(&id, "history-probe")).await.unwrap();
    let seen: Value = serde_json::from_str(answer["text"].as_str().unwrap()).unwrap();
    assert_eq!(seen["prompts"], json!(["first"]), "{answer}");

    std::fs::write(&gate, "").unwrap();
    let ended =
        || hub.events(&id, 0, 10_000).unwrap().iter().filter(|e| e.kind == "turn_result").count();
    for _ in 0..250 {
        if ended() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(ended(), 2, "the running turn ends as it would have");
    assert_eq!(user_messages(&hub, &id), 2, "the question is not in the chat");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_side_question_waits_for_another_agents_turn_to_end() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_chat(&mut c).await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello")).await.unwrap();

    let answer = c.request(ASK, ask(&id, "what was that?")).await.unwrap();
    assert_eq!(answer["text"], "echo: what was that?", "{answer}");
    assert_eq!(answer["stopReason"], "end_turn");
    assert_eq!(user_messages(&hub, &id), 1, "the question is not in the chat");
    assert_eq!(hub.sessions().len(), 1, "the question's fork is gone");

    let blank = c.request(ASK, ask(&id, "  ")).await.unwrap_err();
    assert!(blank.contains("text is required"), "{blank}");

    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let working = c.request(ASK, ask(&id, "now?")).await.unwrap_err();
    assert!(working.contains("ask when the turn ends"), "{working}");
    assert_eq!(hub.sessions().len(), 1, "a refused question forks nothing");
    hub.shutdown_all().await;
}
