//! cx-13w3.1: the session summary's `lastMessage`, one sidebar line: the last
//! line of words in the agent's reply, else the prompt while the turn has not
//! answered yet; null before the first prompt.

use super::*;

#[tokio::test]
async fn last_message_is_the_reply_last_line() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "reply").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["lastMessage"], Value::Null);
    let text = "looked around\n\n```\n\nAll   tests pass.\n";
    c.request(method::SESSION_PROMPT, prompt(&id, text, None)).await.unwrap();
    assert_eq!(
        hub.session_summary(&session)["lastMessage"],
        json!({"role": "agent", "text": "All tests pass."})
    );
}

#[tokio::test]
async fn last_message_is_the_prompt_until_the_agent_answers() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "asking").await;
    // Fire the prompt without waiting for its response: it waits on a permission.
    c.next += 1;
    let request =
        Message::request(c.next, method::SESSION_PROMPT, prompt(&id, "ask: rm -rf /", None));
    c.tx.send(request.to_line()).await.unwrap();
    c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(
        hub.session_summary(&session)["lastMessage"],
        json!({"role": "user", "text": "ask: rm -rf /"})
    );
}
