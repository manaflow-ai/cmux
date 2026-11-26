//! The chat's log goes to the Cloud with its secrets masked (security review of cmux#52931,
//! item 4): a token the person pasted or a tool printed never leaves the laptop as plain text,
//! not to the store and not to the Auto machine that reads it.

use super::*;

const TOKEN: &str = "4f3c2a1b9e8d7c6b5a4f3c2a1b9e8d7c6b5a4f3c2a1b9e8d7c6b5a4f3c2a1b9e";

#[tokio::test]
async fn a_token_in_the_chat_reaches_the_cloud_masked() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = rig.auto_chat().await;
    rig.prompt(&id, &format!("call it with Authorization: Bearer {TOKEN} please")).await;
    let deadline = Instant::now() + Duration::from_secs(60);
    let page = loop {
        let page = rig.store.events(&id, 0, None).await.unwrap();
        if page.events.iter().any(|event| event.record["kind"] == "turn_result") {
            break page;
        }
        assert!(Instant::now() < deadline, "the turn's end never reached the Cloud: {page:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let sent =
        serde_json::to_string(&page.events.iter().map(|e| &e.record).collect::<Vec<_>>()).unwrap();
    assert!(sent.contains("call it with Authorization: Bearer"), "the prompt went: {sent}");
    assert!(!sent.contains(TOKEN), "the token went as plain text: {sent}");
}
