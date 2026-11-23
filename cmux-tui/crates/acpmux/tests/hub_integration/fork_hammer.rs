//! Fork variations (Leo, 2026-11-22: "we ought to really hammer it hard and just test tons of
//! variations of it"). A fork is its own chat: it starts with its chat's model, effort and mode,
//! a fork of that fork does too, and a switch on either side after the fork stays on that side.
//! Mid-turn and mid-tool-call forks are `fork_running.rs`; cross-harness ones `fork_retarget_tests.rs`.

use super::*;

fn picker_env() -> BTreeMap<String, String> {
    BTreeMap::from([
        ("FAKE_PICKER".to_owned(), "1".to_owned()),
        ("FAKE_PICKER_MODES".to_owned(), "claude".to_owned()),
        ("FAKE_FORK_DEFAULTS".to_owned(), "1".to_owned()),
    ])
}

async fn prompt(c: &mut TestClient, id: &str, text: &str) {
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
    )
    .await
    .unwrap();
}

async fn fork(c: &mut TestClient, id: &str) -> String {
    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await.unwrap();
    f["sessionId"].as_str().unwrap().to_owned()
}

fn setup_of(hub: &Arc<Hub>, id: &str) -> (Value, Value) {
    let s = hub.session_summary(&hub.resolve(id).unwrap());
    (s["model"].clone(), s["currentModeId"].clone())
}

async fn picked_chat(c: &mut TestClient, name: &str) -> String {
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_SET_MODEL, json!({"sessionId": id, "modelId": "claude-haiku-5-5"}))
        .await
        .unwrap();
    c.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": "plan"})).await.unwrap();
    prompt(c, &id, "first").await;
    id
}

/// A fork, and a fork of that fork, each start on the chat's model and mode, though the agent
/// answers each `session/fork` with its defaults.
#[tokio::test]
async fn a_fork_of_a_fork_keeps_the_chats_model_and_mode() {
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, picker_env()).await;
    let id = picked_chat(&mut c, "hammer-root").await;
    let want = (json!("claude-haiku-5-5"), json!("plan"));
    let f1 = fork(&mut c, &id).await;
    assert_eq!(setup_of(&hub, &f1), want, "the fork");
    prompt(&mut c, &f1, "in the fork").await;
    let f2 = fork(&mut c, &f1).await;
    assert_eq!(setup_of(&hub, &f2), want, "the fork of the fork");
    assert_eq!(setup_of(&hub, &id), want, "the chat");
    hub.shutdown_all().await;
}

/// A different model and mode picked in the fork stay in the fork, and one picked in the chat
/// after the fork stays in the chat.
#[tokio::test]
async fn a_switch_after_a_fork_stays_on_its_own_side() {
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, picker_env()).await;
    let id = picked_chat(&mut c, "hammer-switch").await;
    let fid = fork(&mut c, &id).await;
    c.request(method::SESSION_SET_MODEL, json!({"sessionId": fid, "modelId": "claude-sonnet-5-5"}))
        .await
        .unwrap();
    c.request(method::SESSION_SET_MODE, json!({"sessionId": fid, "modeId": "acceptEdits"}))
        .await
        .unwrap();
    assert_eq!(
        setup_of(&hub, &fid),
        (json!("claude-sonnet-5-5"), json!("acceptEdits")),
        "the fork switched"
    );
    assert_eq!(setup_of(&hub, &id), (json!("claude-haiku-5-5"), json!("plan")), "the chat did not");
    c.request(method::SESSION_SET_MODE, json!({"sessionId": id, "modeId": "default"}))
        .await
        .unwrap();
    assert_eq!(
        setup_of(&hub, &fid).1,
        json!("acceptEdits"),
        "the chat's later switch leaves the fork"
    );
    prompt(&mut c, &fid, "after the switch").await;
    let f2 = fork(&mut c, &fid).await;
    assert_eq!(
        setup_of(&hub, &f2),
        (json!("claude-sonnet-5-5"), json!("acceptEdits")),
        "a fork of the fork takes its switch"
    );
    hub.shutdown_all().await;
}
