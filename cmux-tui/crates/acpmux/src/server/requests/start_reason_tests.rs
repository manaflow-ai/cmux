use super::stamp;
use crate::rpc::RpcError;
use serde_json::json;

fn stamped(error: RpcError) -> serde_json::Value {
    let mut error = error;
    stamp(&mut error);
    error.data.expect("a stamped error has data")
}

/// The notify-banner-click probe's stub agent crashed at import: acpmux's answer had
/// `errorKind: agent.exited` and no reason, so the daemon printed a bare refusal.
#[test]
fn an_agent_that_exits_at_start_is_agent_exited() {
    let data = stamped(RpcError::internal("agent process closed (fake): FileNotFoundError").with_data(
        json!({"errorKind": "agent.exited", "recovery": "Send the message again.", "details": {}}),
    ));
    assert_eq!(data["reason"], "agent.exited");
    assert_eq!(data["recovery"], "Send the message again.");
}

#[test]
fn a_reason_code_stays() {
    let data = stamped(
        RpcError::new(-32000, "held").with_data(json!({"reason": "fleet_hold", "errorKind": "x"})),
    );
    assert_eq!(data["reason"], "fleet_hold");
}

#[test]
fn an_error_with_no_data_is_named_by_its_code() {
    assert_eq!(
        stamped(RpcError::invalid_params("bad cwd"))["reason"],
        "session_new.invalid_params"
    );
    assert_eq!(stamped(RpcError::internal("boom"))["reason"], "session_new.internal");
    assert_eq!(stamped(RpcError::not_found("no harness"))["reason"], "session_new.not_found");
    assert_eq!(stamped(RpcError::new(-32050, "other"))["reason"], "session_new.refused");
}

#[test]
fn free_text_reason_and_odd_data_are_kept() {
    let data = stamped(
        RpcError::internal("x").with_data(json!({"reason": "a long sentence, not a code"})),
    );
    assert_eq!(data["reason"], "session_new.internal");
    assert_eq!(data["reasonText"], "a long sentence, not a code");
    let data = stamped(RpcError::internal("x").with_data(json!("just text")));
    assert_eq!(data["reason"], "session_new.internal");
    assert_eq!(data[crate::recovery::AGENT_DATA], "just text");
}

/// The daemon passes on a reason only when it is a short code; every stamped one is.
#[test]
fn every_stamped_reason_is_a_short_code() {
    for error in [
        RpcError::internal("x").with_data(json!({"errorKind": "has spaces in it"})),
        RpcError::internal("x").with_data(json!({"errorKind": "k".repeat(65)})),
        RpcError::new(-1, "x"),
    ] {
        let reason = stamped(error)["reason"].as_str().unwrap().to_owned();
        assert!(super::is_code(&reason), "{reason}");
    }
}

/// acpmux's own answer for an agent gone before `session/new`: the bare ACP message, typed here.
#[test]
fn a_bare_agent_process_closed_is_agent_exited() {
    let data = stamped(RpcError::internal("agent process closed"));
    assert_eq!(data["reason"], "agent.exited");
    assert_eq!(data["errorKind"], "agent.exited");
}
