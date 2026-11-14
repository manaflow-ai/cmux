use super::*;

/// "No such session" from the target's machine is final; a peer that is down is not.
#[test]
fn a_no_session_answer_is_final_and_an_unreachable_peer_is_not() {
    let e = RpcError::not_found("no session matches \"host/proc-title\"");
    assert_eq!(next(&e), Next::NoSession);
    let flagged =
        RpcError::invalid_params("no session: x").with_data(json!({"reason": "no_session"}));
    assert_eq!(next(&flagged), Next::NoSession);
    let down = RpcError::internal("down").with_data(json!({"reason": "peer_unreachable"}));
    assert_eq!(next(&down), Next::Unsent);
    assert_eq!(next(&RpcError::internal("connection reset")), Next::Retry);
}
