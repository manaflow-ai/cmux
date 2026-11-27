//! cx-n8ou: acpmux owns what the person has seen. A client says whether it
//! shows a chat (`_acpmux/attach` with `visible: false`, then `_acpmux/view`);
//! a turn that ends while no attached client shows the chat leaves it
//! `unread`, and showing it is seeing it. A client that never says counts
//! as showing every chat it attaches (the TUI, `acpmux attach`).

use super::*;

/// The chat's `unread` once its turn has settled (the prompt's answer can
/// come before the turn records its end).
async fn unread(hub: &Hub, id: &str) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let summary = hub.session_summary(&hub.resolve(id).unwrap());
        if summary["status"] != "running" {
            return summary["unread"].clone();
        }
        assert!(tokio::time::Instant::now() < deadline, "never settled: {summary}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn a_turn_ending_in_a_hidden_tab_stays_unread_until_shown() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "background").await;
    c.request("_acpmux/view", json!({"sessionId": id, "visible": false})).await.unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert_eq!(unread(&hub, &id).await, true);
    c.request("_acpmux/view", json!({"sessionId": id, "visible": true})).await.unwrap();
    assert_eq!(unread(&hub, &id).await, false);
    // Shown while it ends: seen.
    c.request(method::SESSION_PROMPT, prompt(&id, "again", None)).await.unwrap();
    assert_eq!(unread(&hub, &id).await, false);
}

#[tokio::test]
async fn a_hidden_attach_does_not_mark_a_chat_seen() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "unseen").await;
    c.request("_acpmux/view", json!({"sessionId": id, "visible": false})).await.unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    assert_eq!(unread(&hub, &id).await, true);
    let mut tab = connect(&hub).await;
    tab.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0, "visible": false}))
        .await
        .unwrap();
    assert_eq!(unread(&hub, &id).await, true);
    assert_eq!(hub.session_summary(&hub.resolve(&id).unwrap())["attached"], 1);
    tab.request("_acpmux/view", json!({"sessionId": id, "visible": true})).await.unwrap();
    assert_eq!(unread(&hub, &id).await, false);
}

#[tokio::test]
async fn one_client_showing_a_chat_is_enough() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "shared").await;
    let mut tab = connect(&hub).await;
    tab.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0, "visible": false}))
        .await
        .unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert_eq!(unread(&hub, &id).await, false);
    // The showing client hides it: the next turn's end is unseen.
    c.request("_acpmux/view", json!({"sessionId": id, "visible": false})).await.unwrap();
    c.request(method::SESSION_PROMPT, prompt(&id, "again", None)).await.unwrap();
    assert_eq!(unread(&hub, &id).await, true);
}

/// Mark Unread (cx-ncc.78, the Codex app's Mark unread): the person marks a chat they have seen;
/// it stays unread while a client still shows it, and showing it again after hiding it is seeing it.
#[tokio::test]
async fn a_chat_marked_unread_stays_unread_until_shown_again() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "read").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    assert_eq!(unread(&hub, &id).await, false);
    c.request("_acpmux/markUnread", json!({"sessionId": id})).await.unwrap();
    assert_eq!(unread(&hub, &id).await, true);
    c.request("_acpmux/view", json!({"sessionId": id, "visible": true})).await.unwrap();
    assert_eq!(unread(&hub, &id).await, true);
    c.request("_acpmux/view", json!({"sessionId": id, "visible": false})).await.unwrap();
    c.request("_acpmux/view", json!({"sessionId": id, "visible": true})).await.unwrap();
    assert_eq!(unread(&hub, &id).await, false);
    assert!(c.request("_acpmux/markUnread", json!({"sessionId": "no-such-chat"})).await.is_err());
}
