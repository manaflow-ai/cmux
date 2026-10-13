//! An agent offers the person a parallel chat (cx-807da, `hub/offers.rs`):
//! its `offer_session` tool records the offer and returns at once, the chat
//! shows it as a chip, and only the person accepts it (naming the chat it
//! started, which takes the offering chat as its parent) or dismisses it.

use super::*;
use acpmux::server::{Origin, serve_connection_with};

/// The agent's tool on the unix socket: a connection that never proved the
/// person key.
async fn agent(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "agent"}}))
        .await
        .unwrap();
    client
}

async fn new_chat(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

fn offer(id: &str, title: &str) -> Value {
    json!({
        "sessionId": id,
        "title": title,
        "prompt": "The upload test fails one run in five: find why and fix it.",
        "worktree": true,
        "harness": "codex",
    })
}

#[tokio::test]
async fn an_offered_chat_is_a_chip_only_the_person_starts_and_it_reports_its_parent() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = new_chat(&mut person).await;
    let mut agent = agent(&hub).await;

    // The tool returns at once; the chat records the chip with what the agent
    // gave and this chat's folder, and keeps its status.
    let offered = agent
        .request("_acpmux/offer_session", offer(&id, "Fix the flaky upload test"))
        .await
        .unwrap();
    assert_eq!(offered["outcome"], "offered", "{offered}");
    let offer_id = offered["offerId"].as_str().unwrap().to_owned();
    let chip = person.wait_for(method::MUX_EVENT, |p| p["kind"] == "session_offer").await;
    assert_eq!(chip["msg"]["offerId"], offer_id.as_str());
    assert_eq!(chip["msg"]["title"], "Fix the flaky upload test");
    assert_eq!(chip["msg"]["worktree"], true);
    assert_eq!(chip["msg"]["harness"], "codex");
    let session = hub.resolve(&id).unwrap();
    assert_eq!(chip["msg"]["cwd"], json!(session.meta().cwd));
    assert_eq!(hub.session_summary(&session)["status"], "idle");

    // A page reading the chat's history gets the chip with the transcript.
    let page = person
        .request("_acpmux/events", json!({"sessionId": id, "kinds": "transcript"}))
        .await
        .unwrap();
    assert!(
        page.to_string().contains("session_offer"),
        "the chip is not in the transcript: {page}"
    );

    // The agent cannot accept its own offer.
    let child = new_chat(&mut person).await;
    let accept = json!({"sessionId": id, "offerId": offer_id, "outcome": "accepted", "childSessionId": child});
    let forged = agent.request("_acpmux/offer_respond", accept.clone()).await;
    assert!(forged.is_err(), "the agent accepted its own offer: {forged:?}");

    // The person accepts it with the chat they started: that chat's parent is
    // this one, and it is not a fork.
    let decided = person.request("_acpmux/offer_respond", accept.clone()).await.unwrap();
    assert_eq!(decided["childSessionId"], child.as_str(), "{decided}");
    let started = hub.resolve(&child).unwrap();
    let summary = hub.session_summary(&started);
    assert_eq!(summary["parentId"], id.as_str(), "{summary}");
    assert!(summary["forkSeq"].is_null(), "an offered chat is not a fork: {summary}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(
        events.iter().any(|e| e.kind == "session_offer_decision" && e.msg["outcome"] == "accepted")
    );

    // An answered offer takes no second answer.
    let again = person.request("_acpmux/offer_respond", accept).await;
    assert!(again.is_err(), "an offer was answered twice: {again:?}");

    // Another offer is dismissed: no chat starts.
    let second = agent
        .request("_acpmux/offer_session", offer(&id, "Rename the cache module"))
        .await
        .unwrap();
    let dismiss = json!({"sessionId": id, "offerId": second["offerId"], "outcome": "dismissed"});
    let dismissed = person.request("_acpmux/offer_respond", dismiss).await.unwrap();
    assert_eq!(dismissed["outcome"], "dismissed");
    assert!(dismissed.get("childSessionId").is_none(), "{dismissed}");
}

#[tokio::test]
async fn an_offer_needs_a_title_and_a_prompt_and_a_chat_holds_a_few() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = new_chat(&mut person).await;
    let mut agent = agent(&hub).await;

    let untitled = agent.request("_acpmux/offer_session", offer(&id, "  ")).await;
    assert!(untitled.is_err(), "an untitled offer was recorded: {untitled:?}");
    let mut no_prompt = offer(&id, "Fix it");
    no_prompt["prompt"] = json!("");
    assert!(agent.request("_acpmux/offer_session", no_prompt).await.is_err());
    let mut elsewhere = offer(&id, "Fix it");
    elsewhere["cwd"] = json!("relative/folder");
    assert!(agent.request("_acpmux/offer_session", elsewhere).await.is_err());

    // Eight open offers at most: the ninth waits for an answer.
    for n in 0..8 {
        agent.request("_acpmux/offer_session", offer(&id, &format!("Task {n}"))).await.unwrap();
    }
    let ninth = agent.request("_acpmux/offer_session", offer(&id, "Task 8")).await;
    assert!(ninth.is_err(), "a ninth open offer was recorded: {ninth:?}");
}
