//! `acp.session.fork` (the pane's "Fork from Here"): a fork through the
//! latest completed turn, advertised in `initialize`; an earlier turn is
//! refused with a clear error.

use super::*;

const FORK_OP: &str = "acp.session.fork";

#[tokio::test]
async fn initialize_advertises_the_fork_operation() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let init = c
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    let ops = init["_meta"]["acpmux"]["operations"].as_array().cloned().unwrap_or_default();
    assert!(ops.iter().any(|op| op == FORK_OP), "{ops:?}");
}

#[tokio::test]
async fn a_fork_through_the_latest_turn_opens_a_new_session_and_an_earlier_turn_is_refused() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "src"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for text in ["first", "second"] {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    let results: Vec<u64> = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "turn_result")
        .map(|e| e.seq)
        .collect();
    assert_eq!(results.len(), 2, "{results:?}");

    let earlier =
        c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[0]})).await.unwrap_err();
    assert!(earlier.contains("latest"), "{earlier}");
    let missing = c.request(FORK_OP, json!({"sessionId": id})).await.unwrap_err();
    assert!(missing.contains("throughSeq"), "{missing}");

    let f = c.request(FORK_OP, json!({"sessionId": id, "throughSeq": results[1]})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    assert_ne!(fid, id);
    let forked = hub.resolve(&fid).unwrap();
    assert_eq!(forked.meta().parent_id.as_deref(), Some(id.as_str()));
    let prompts =
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == "user_message").count();
    assert_eq!(prompts, 2, "the fork holds both turns");
    // Each copied turn ends in the fork too, or the pane shows its last
    // reply as still streaming and the chat as working.
    let ended =
        hub.events(&fid, 0, 1000).unwrap().into_iter().filter(|e| e.kind == "turn_result").count();
    assert_eq!(ended, 2, "the fork holds both turn ends");
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": fid, "prompt": [{"type": "text", "text": "third"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
}
