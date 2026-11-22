//! A chat's task list (`hub/task_list.rs`): what is done and what is next, kept on the chat
//! across its turns, not only while a turn runs (David Beyer, Nov 20 call: a task list that
//! tracks long agent chats). The harness's own plan (Claude's TodoWrite, Codex's update_plan, an
//! ACP `plan` update) keeps it; a harness with none lets the Chief (or the chat's own agent) keep
//! it with `_acpmux/task_list/set`. The session summary's `taskList` carries it to every client.

use super::*;

const SET: &str = "_acpmux/task_list/set";
const GET: &str = "_acpmux/task_list/get";

fn plan(entries: Value) -> String {
    format!("plan-json: {entries}")
}

#[tokio::test]
async fn the_harness_plan_stays_on_the_chat_after_its_turn_ends() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "planner").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["taskList"], Value::Null);
    let entries = json!([
        {"content": "Read the brief", "status": "completed", "priority": "high"},
        {"content": "Fix the queue", "status": "in_progress", "priority": "high"},
        {"content": "Land on feat-cmux-next", "status": "pending", "priority": "medium"},
    ]);
    c.request(method::SESSION_PROMPT, prompt(&id, &plan(entries), None)).await.unwrap();

    // The turn ended: its planStep went with it, the chat's list did not.
    let summary = hub.session_summary(&session);
    assert_eq!(summary["turn"], Value::Null, "{summary:#}");
    let list = &summary["taskList"];
    assert_eq!(list["source"], "harness", "{list:#}");
    assert_eq!(list["done"], 1);
    assert_eq!(list["total"], 3);
    assert_eq!(list["current"], "Fix the queue");
    assert_eq!(list["next"], "Land on feat-cmux-next");
    assert_eq!(
        list["items"],
        json!([
            {"content": "Read the brief", "status": "completed"},
            {"content": "Fix the queue", "status": "in_progress"},
            {"content": "Land on feat-cmux-next", "status": "pending"},
        ])
    );
    assert!(list["updatedAt"].as_u64().is_some_and(|at| at > 0), "{list:#}");
    // The session list carries it too: the sidebar reads that one.
    let rows = c.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    let row = rows["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == id).unwrap();
    let row = row.pointer("/_meta/acpmux").unwrap_or(row);
    assert_eq!(row["taskList"]["done"], 1, "{row:#}");
    // And the next turn, which writes no plan, keeps it.
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert_eq!(hub.session_summary(&session)["taskList"]["total"], 3);
}

#[tokio::test]
async fn a_newer_harness_plan_replaces_the_list_and_an_empty_one_clears_it() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "replanner").await;
    let session = hub.resolve(&id).unwrap();
    let first =
        json!([{"content": "A", "status": "in_progress"}, {"content": "B", "status": "pending"}]);
    c.request(method::SESSION_PROMPT, prompt(&id, &plan(first), None)).await.unwrap();
    let done =
        json!([{"content": "A", "status": "completed"}, {"content": "B", "status": "completed"}]);
    c.request(method::SESSION_PROMPT, prompt(&id, &plan(done), None)).await.unwrap();
    let list = hub.session_summary(&session)["taskList"].clone();
    assert_eq!((list["done"].as_u64(), list["total"].as_u64()), (Some(2), Some(2)), "{list:#}");
    assert_eq!(list["current"], Value::Null);
    assert_eq!(list["next"], Value::Null);
    c.request(method::SESSION_PROMPT, prompt(&id, &plan(json!([])), None)).await.unwrap();
    assert_eq!(hub.session_summary(&session)["taskList"], Value::Null);
}

#[tokio::test]
async fn the_chief_keeps_the_list_of_a_chat_whose_harness_writes_none() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "no-plan-tool").await;
    let session = hub.resolve(&id).unwrap();
    let set = c
        .request(
            SET,
            json!({"sessionId": id, "items": [
                {"content": "Repro the passkey bug", "status": "completed"},
                {"content": "Red test", "status": "in_progress"},
                {"content": "Fix and land", "status": "pending"},
                {"content": "Shots", "status": "pending"},
            ]}),
        )
        .await
        .unwrap();
    assert_eq!(set["source"], "chief", "{set:#}");
    assert_eq!(set["done"], 1);
    assert_eq!(set["total"], 4);
    let list = hub.session_summary(&session)["taskList"].clone();
    assert_eq!(list["current"], "Red test", "{list:#}");
    assert_eq!(list["next"], "Fix and land");
    assert_eq!(c.request(GET, json!({"sessionId": id})).await.unwrap()["total"], 4);

    // A harness's empty plan does not clear a list the Chief keeps; a real plan replaces it.
    c.request(method::SESSION_PROMPT, prompt(&id, &plan(json!([])), None)).await.unwrap();
    assert_eq!(hub.session_summary(&session)["taskList"]["source"], "chief");
    let own = json!([{"content": "Own step", "status": "in_progress"}]);
    c.request(method::SESSION_PROMPT, prompt(&id, &plan(own), None)).await.unwrap();
    let list = hub.session_summary(&session)["taskList"].clone();
    assert_eq!((list["source"].as_str(), list["total"].as_u64()), (Some("harness"), Some(1)));

    // Clearing: an empty list from the Chief.
    let cleared = c.request(SET, json!({"sessionId": id, "items": []})).await.unwrap();
    assert_eq!(cleared, Value::Null);
    assert_eq!(hub.session_summary(&session)["taskList"], Value::Null);
}

#[tokio::test]
async fn a_bad_task_list_is_refused_and_a_secret_in_a_step_is_masked() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "careful").await;
    let bad = c
        .request(SET, json!({"sessionId": id, "items": [{"content": "x", "status": "sideways"}]}))
        .await
        .unwrap_err();
    assert!(bad.contains("status"), "{bad}");
    let empty = c
        .request(SET, json!({"sessionId": id, "items": [{"content": "  ", "status": "pending"}]}))
        .await
        .unwrap_err();
    assert!(empty.contains("content"), "{empty}");
    let token = "ghp_0123456789abcdefghijABCDEFGHIJ012345";
    c.request(
        SET,
        json!({"sessionId": id, "items": [{"content": format!("push with {token}"), "status": "pending"}]}),
    )
    .await
    .unwrap();
    let list = hub.session_summary(&hub.resolve(&id).unwrap())["taskList"].clone();
    assert!(!list.to_string().contains(token), "{list:#}");
}

/// A connection that proved it runs in chat `id` (`hub/person.rs` (a)): its agent's tools.
async fn agent_of(hub: &Arc<Hub>, id: &str) -> TestClient {
    let (tx, in_rx) = tokio::sync::mpsc::channel(64);
    let (out_tx, rx) = tokio::sync::mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx, rx, next: 0 };
    let token = acpmux::hub::person::caller_token(id);
    let caller = json!({"callerSession": {"sessionId": id, "token": token}});
    c.request("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}}))
        .await
        .unwrap();
    c
}

#[tokio::test]
async fn a_chat_keeps_its_own_list_and_never_another_chats() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let mine = new_session(&mut c, "mine").await;
    let other = new_session(&mut c, "other").await;
    let mut agent = agent_of(&hub, &mine).await;
    let items = json!([{"content": "Step", "status": "in_progress"}]);
    let own = agent.request(SET, json!({"sessionId": mine, "items": items})).await.unwrap();
    assert_eq!(own["source"], "agent", "{own:#}");
    let refused =
        agent.request(SET, json!({"sessionId": other, "items": items})).await.unwrap_err();
    assert!(refused.contains("task list"), "{refused}");
    assert_eq!(hub.session_summary(&hub.resolve(&other).unwrap())["taskList"], Value::Null);
}
