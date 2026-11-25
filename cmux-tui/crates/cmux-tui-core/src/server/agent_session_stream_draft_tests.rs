use super::*;

#[test]
fn a_teammate_page_keeps_every_record_but_drafts() {
    let page = json!({"events": [{"seq": 1, "kind": "user_message"},
        {"seq": 2, "kind": "composer", "msg": {"text": "secret"}}, {"seq": 3, "kind": "queued"}]});
    let kept = without_drafts(page);
    let seqs: Vec<u64> =
        kept["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    assert_eq!(seqs, vec![1, 3]);
    assert!(is_draft(&json!({"kind": "composer"})));
    let page = json!({"events": [], "session": {"sessionId": "s", "name": "chat",
        "status": "running", "cwd": "/Users/owner/secret", "parentId": "p", "startedBy": "p",
        "spawnedBy": "p", "children": 2, "tags": {"lane": "x"}, "tools": [{"name": "Bash"}],
        "rules": true, "mcpServers": [], "pullRequests": ["https://example.com/1"],
        "agentSessionId": "thread", "peer": "other", "turn": {"turnId": "t"}}});
    let session = &without_drafts(page)["session"];
    assert_eq!(
        session,
        &json!({"sessionId": "s", "name": "chat", "status": "running", "turn": {"turnId": "t"}})
    );
    assert!(!is_draft(&json!({"kind": "user_message"})));
    let page = json!({"events": [], "presence": {"sessionId": "s", "participants": [
        {"id": "tailnet:other@example.com", "name": "Other"}]}});
    assert_eq!(without_drafts(page), json!({"events": []}), "no one's presence");
}
