//! A chat's place and move epoch, as Home follows a Chief's agent across machines
//! (`plans/cmux-next/home-agent-pills-DESIGN.md`, Identity): the session id never changes on a
//! move, each move publishes the new place and a higher epoch in one event, and the turns from
//! before the move read on the machine it went to.

use super::transfer::{move_whole, prompt, records, texts, wait_status};
use super::*;

/// The move epoch a session's info says, 0 when it never moved (absent from an older acpmux).
async fn epoch(c: &mut TestClient, id: &str) -> u64 {
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    info["moveEpoch"].as_u64().unwrap_or(0)
}

#[tokio::test]
async fn each_move_keeps_the_session_id_and_publishes_its_new_place_with_a_higher_epoch() {
    let (_a, mut a) = setup(PermissionPolicy::ApproveAll).await;
    let (_b, mut b) = setup(PermissionPolicy::ApproveAll).await;
    let (_c, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = a.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    a.request(method::SESSION_PROMPT, prompt(&id, "p-hi", "hi")).await.unwrap();
    a.request(method::MUX_KILL, json!({"sessionId": id, "purge": false})).await.unwrap();
    wait_status(&mut a, &id, "closed").await;
    assert_eq!(epoch(&mut a, &id).await, 0, "a chat that never moved");

    // First move: the source's one `transferred` record names the new place and the epoch.
    let to_b = json!({"host": "mini-3", "sessionId": id});
    move_whole(&mut a, &mut b, &id, to_b.clone()).await;
    let left = records(&mut a, &id, "transferred").await;
    assert_eq!(left.len(), 1, "{left:?}");
    assert_eq!(left[0]["to"], to_b, "{left:?}");
    assert_eq!(left[0]["moveEpoch"], 1, "the place and the epoch in one event: {left:?}");
    let source = a.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(source["movedTo"], to_b, "{source}");
    assert_eq!(source["moveEpoch"], 1, "{source}");
    let there = b.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(there["sessionId"], id.as_str(), "the session id survives the move: {there}");
    assert_eq!(there["moveEpoch"], 1, "{there}");
    let arrived = records(&mut b, &id, "imported").await;
    assert_eq!(arrived.last().map(|r| r["moveEpoch"].clone()), Some(json!(1)), "{arrived:?}");

    // Second move: one higher, on both ends.
    let to_c = json!({"host": "cloud-vm", "sessionId": id});
    move_whole(&mut b, &mut c, &id, to_c.clone()).await;
    let left = records(&mut b, &id, "transferred").await;
    assert_eq!(left.last().map(|r| r["to"].clone()), Some(to_c), "{left:?}");
    assert_eq!(left.last().map(|r| r["moveEpoch"].clone()), Some(json!(2)), "{left:?}");
    assert_eq!(epoch(&mut b, &id).await, 2);
    assert_eq!(epoch(&mut c, &id).await, 2);
    let there = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(there["sessionId"], id.as_str(), "{there}");
    // The turns from before both moves read where it is now.
    assert_eq!(texts(&mut c, &id, "user_message").await, ["hi"], "its history moved");
}
