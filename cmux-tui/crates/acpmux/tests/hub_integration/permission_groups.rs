//! Fixture-driven grouped permission requests through the real daemon handler.
use super::*;

const GROUPS: &str = "_acpmux/permission_groups";
const RESPOND: &str = "_acpmux/permission_group_respond";
const REVOKE: &str = "_acpmux/permission_chat_revoke";

async fn ready(c: &mut TestClient) -> Value {
    let event = c
        .wait_for(method::MUX_EVENT, |p| {
            p["kind"] == "permission_group" && p["msg"]["group"]["state"] == "pending"
        })
        .await;
    event["msg"]["group"].clone()
}

fn decision(id: &str, g: &Value, key: &str, choice: &str) -> Value {
    json!({"sessionId":id, "groupId":g["groupId"], "revision":g["revision"],
           "decisionKey":key, "decision":choice})
}

#[tokio::test]
async fn permission_groups_fixture_burst_and_retry() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let init = c.request(method::INITIALIZE, json!({"protocolVersion":1})).await.unwrap();
    assert!(init["_meta"]["acpmux"]["operations"].as_array().unwrap().contains(&json!(RESPOND)));
    let id = new_session(&mut c, "batch").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: parallel", None)).await;
    let g = ready(&mut c).await;
    let detail = c.request(method::MUX_INFO, json!({"sessionId":id})).await.unwrap();
    let pending = detail["pending"].as_array().unwrap();
    assert_eq!(pending.len(), 3);
    for item in pending {
        assert_eq!(item["groupId"], g["groupId"]);
        assert_eq!(item["turnId"], g["turnId"]);
    }
    assert_eq!(g["items"].as_array().unwrap().len(), 3);
    assert!(g["turnId"].is_string());
    let body = decision(&id, &g, "first", "allow_once");
    // Answer from a second connection, so the first retains its turn response.
    let mut responder = connect(&hub).await;
    let first = responder.request(RESPOND, body.clone()).await.unwrap();
    assert_eq!(first["replayed"], false);
    let again = responder.request(RESPOND, body.clone()).await.unwrap();
    assert_eq!(again["replayed"], true);
    assert_eq!(again["group"], first["group"]);
    let mut changed = body;
    changed["decision"] = json!("deny");
    assert!(responder.request(RESPOND, changed).await.unwrap_err().contains("key_conflict"));
    assert!(c.response(rid).await.0.is_ok());
    let events = hub.events(&id, 0, 1000).unwrap();
    assert_eq!(find(&events, "permission_decision").len(), 3);
}

#[tokio::test]
async fn permission_groups_fixture_late_requests_are_not_approved() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "late").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: followup", None)).await;
    let first = ready(&mut c).await;
    let mut r = connect(&hub).await;
    r.request(RESPOND, decision(&id, &first, "one", "allow_once")).await.unwrap();
    let later = ready(&mut c).await;
    assert_ne!(first["groupId"], later["groupId"]);
    assert_eq!(first["turnId"], later["turnId"]);
    r.request(RESPOND, decision(&id, &later, "two", "deny")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
}

#[tokio::test]
async fn permission_groups_fixture_chat_allowance_and_revoke() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "chat").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: followup", None)).await;
    let g = ready(&mut c).await;
    let mut r = connect(&hub).await;
    r.request(RESPOND, decision(&id, &g, "chat", "allow_chat")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
    let state = r.request(GROUPS, json!({"sessionId":id})).await.unwrap();
    assert_eq!(state["chatAllowance"]["active"], true);
    assert_eq!(state["coverage"]["label"], "acp_requests_only");
    assert_eq!(r.request(REVOKE, json!({"sessionId":id})).await.unwrap()["active"], false);
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: single", None)).await;
    let g = ready(&mut c).await;
    r.request(RESPOND, decision(&id, &g, "after-revoke", "deny")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
}

#[tokio::test]
async fn permission_groups_fixture_legacy_resolution_invalidates_revision() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "legacy").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: parallel", None)).await;
    let g = ready(&mut c).await;
    let mut r = connect(&hub).await;
    r.request(method::MUX_PERMISSION_RESPOND, json!({"sessionId":id,
        "permissionId":g["items"][0]["permissionId"], "optionId":g["items"][0]["request"]["options"][0]["optionId"]})).await.unwrap();
    assert!(
        r.request(RESPOND, decision(&id, &g, "stale", "allow_once"))
            .await
            .unwrap_err()
            .contains("stale_revision")
    );
    let current = r.request(GROUPS, json!({"sessionId":id,"groupId":g["groupId"]})).await.unwrap();
    r.request(RESPOND, decision(&id, &current["groups"][0], "fresh", "deny")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
}

#[tokio::test]
async fn permission_groups_fixture_missing_once_option_cannot_widen() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "safe-options").await;
    let rid =
        c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: unsafe-option", None)).await;
    let g = ready(&mut c).await;
    assert_eq!(g["decisions"], json!(["deny"]));
    let mut r = connect(&hub).await;
    assert!(r.request(RESPOND, decision(&id, &g, "unsafe", "allow_chat")).await.is_err());
    r.request(RESPOND, decision(&id, &g, "deny", "deny")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
}

#[tokio::test]
async fn permission_groups_fixture_disconnect_and_cancel() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "reconnect").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: single", None)).await;
    let g = ready(&mut c).await;
    drop(c);
    let mut r = connect(&hub).await;
    let state = r.request(GROUPS, json!({"sessionId":id})).await.unwrap();
    assert_eq!(state["groups"][0]["groupId"], g["groupId"]);
    r.request(method::SESSION_CANCEL, json!({"sessionId":id})).await.unwrap();
    let state = r.request(GROUPS, json!({"sessionId":id})).await.unwrap();
    assert_eq!(state["groups"][0]["state"], "cancelled");
    assert!(r.request(RESPOND, decision(&id, &g, "late", "allow_once")).await.is_err());
}

#[tokio::test]
async fn permission_groups_fixture_chat_isolation_policy_and_stop() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "grant").await;
    let other = new_session(&mut c, "other-chat").await;
    let mut r = connect(&hub).await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: single", None)).await;
    let g = ready(&mut c).await;
    r.request(RESPOND, decision(&id, &g, "grant", "allow_chat")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
    assert_eq!(
        r.request(GROUPS, json!({"sessionId":other})).await.unwrap()["chatAllowance"]["active"],
        false
    );
    // Changing rules revokes the grant and explicit deny still wins.
    r.request(method::MUX_SET_RULES, json!({"sessionId":id,"rules":{"autoDeny":["edit"]}}))
        .await
        .unwrap();
    assert_eq!(
        r.request(GROUPS, json!({"sessionId":id})).await.unwrap()["chatAllowance"]["active"],
        false
    );
    c.request(method::SESSION_PROMPT, prompt(&id, "permission-batch: single", None)).await.unwrap();
    let events = hub.events(&id, 0, 1000).unwrap();
    assert!(
        find(&events, "permission_auto").last().unwrap().msg["optionId"]
            .as_str()
            .unwrap()
            .starts_with("no-")
    );
    r.request(method::MUX_SET_RULES, json!({"sessionId":id,"rules":null})).await.unwrap();
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: single", None)).await;
    let g = ready(&mut c).await;
    r.request(RESPOND, decision(&id, &g, "second-grant", "allow_chat")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
    r.request(method::MUX_KILL, json!({"sessionId":id})).await.unwrap();
    assert_eq!(
        r.request(GROUPS, json!({"sessionId":id})).await.unwrap()["chatAllowance"]["active"],
        false
    );
}

#[tokio::test]
async fn permission_groups_fixture_interactive_and_unknown_remain_individual() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "individual").await;
    let mut r = connect(&hub).await;
    // Start with a chat allowance to prove these requests do not inherit it.
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: single", None)).await;
    let g = ready(&mut c).await;
    r.request(RESPOND, decision(&id, &g, "grant", "allow_chat")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
    for fixture in ["interactive", "unknown"] {
        let rid = c
            .send(
                method::SESSION_PROMPT,
                prompt(&id, &format!("permission-batch: {fixture}"), None),
            )
            .await;
        let p = c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
        assert!(p["groupId"].is_null());
        r.request(method::MUX_PERMISSION_RESPOND,json!({"sessionId":id,"permissionId":p["permissionId"],"optionId":p["request"]["options"][1]["optionId"]})).await.unwrap();
        assert!(c.response(rid).await.0.is_ok());
    }
}

#[tokio::test]
async fn permission_groups_fixture_only_one_responder_wins() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "race").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: parallel", None)).await;
    let g = ready(&mut c).await;
    let mut a = connect(&hub).await;
    let mut b = connect(&hub).await;
    let (one, two) = tokio::join!(
        a.request(RESPOND, decision(&id, &g, "a", "allow_once")),
        b.request(RESPOND, decision(&id, &g, "b", "deny"))
    );
    assert_ne!(one.is_ok(), two.is_ok());
    assert!(c.response(rid).await.0.is_ok());
    assert_eq!(find(&hub.events(&id, 0, 1000).unwrap(), "permission_decision").len(), 3);
}

#[tokio::test]
async fn permission_groups_fixture_policy_edit_cannot_be_bypassed_by_legacy() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "policy-change").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: single", None)).await;
    let g = ready(&mut c).await;
    let mut r = connect(&hub).await;
    r.request(method::MUX_SET_POLICY, json!({"sessionId":id,"policy":"deny-all"})).await.unwrap();
    assert!(
        r.request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId":id,
        "permissionId":g["items"][0]["permissionId"],
        "optionId":g["items"][0]["request"]["options"][0]["optionId"]})
        )
        .await
        .unwrap_err()
        .contains("policy_changed")
    );
    let state = r.request(GROUPS, json!({"sessionId":id,"groupId":g["groupId"]})).await.unwrap();
    let current = &state["groups"][0];
    assert!(
        r.request(RESPOND, decision(&id, current, "blocked", "allow_once"))
            .await
            .unwrap_err()
            .contains("policy_changed")
    );
    r.request(RESPOND, decision(&id, current, "deny", "deny")).await.unwrap();
    assert!(c.response(rid).await.0.is_ok());
}

#[tokio::test]
async fn permission_groups_fixture_deny_without_option_records_cancellation() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "cancel-option").await;
    let rid =
        c.send(method::SESSION_PROMPT, prompt(&id, "permission-batch: no-reject", None)).await;
    let g = ready(&mut c).await;
    let mut r = connect(&hub).await;
    let result = r.request(RESPOND, decision(&id, &g, "deny", "deny")).await.unwrap();
    assert_eq!(result["group"]["items"][0]["state"], "cancelled");
    assert_eq!(result["group"]["decision"], "deny");
    assert!(c.response(rid).await.0.is_ok());
    assert_eq!(
        find(&hub.events(&id, 0, 1000).unwrap(), "permission_decision")[0].msg["outcome"]["outcome"],
        "cancelled"
    );
}
