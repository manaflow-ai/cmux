//! Real protocol caller binding; all identifiers and credentials are synthetic.
use super::*;
use acpmux::server::{Origin, serve_connection_with};

async fn caller(hub: &Arc<Hub>, session: Option<&str>, origin: Origin) -> TestClient {
    let (tx, rx) = mpsc::channel(64);
    let (out, input) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), rx, out, origin));
    let mut c = TestClient { tx, rx: input, next: 0 };
    let mut init = json!({"protocolVersion": 1});
    if let Some(id) = session {
        init["_meta"] = json!({"acpmux":{"callerSession":{
            "sessionId": id, "token": acpmux::hub::person::caller_token(id)}}});
    }
    c.request("initialize", init).await.unwrap();
    c
}

#[tokio::test]
async fn turn_attestation_requires_own_authenticated_local_session() {
    let (hub, mut person) = setup(PermissionPolicy::ApproveAll).await;
    let own = new_session(&mut person, "attest-own").await;
    let other = new_session(&mut person, "attest-other").await;
    let mut agent = caller(&hub, Some(&own), Origin::Local).await;
    let mut anonymous = caller(&hub, None, Origin::Local).await;
    // The old draft accepted these on a live turn. Keep identity arguments to
    // prove they never establish authority, even on clients predating this fix.
    let ask = json!({"sessionId":other,"teamInstall":"inst-forged"});
    for c in [&mut anonymous, &mut agent] {
        let error = c.request("_acpmux/turn_attestation", ask.clone()).await.unwrap_err();
        assert_eq!(error, "turn attestation refused");
    }
    // A forged cloud identity is not accepted even by an authenticated caller.
    let error = agent
        .request("_acpmux/turn_attestation", json!({"sessionId":own,"teamInstall":"inst-forged"}))
        .await
        .unwrap_err();
    assert_eq!(error, "turn attestation refused");
}
