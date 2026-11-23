use super::*;

#[test]
fn local_inline_btw_app_marker_is_trust_gated() {
    let params = serde_json::json!({"_meta": {"acpmux": {"via": "app"}}});
    assert!(gated(Origin::Local, &params));
    assert!(!gated(Origin::Local, &serde_json::json!({})));
    assert!(gated(Origin::LocalApp, &serde_json::json!({})));
}

/// The cmux-tui mobile relay reaches acpmux over the local socket: a phone's
/// prompt there is folder-trust gated, on Web decisions only, and the queued
/// prompt keeps that gate (`PromptRun::trust_gate` comes from `gated`).
#[test]
fn local_cloud_mobile_marker_is_trust_gated_for_the_web() {
    let phone = serde_json::json!({"_meta": {"acpmux": {"via": "cloud-mobile"}}});
    assert!(gated(Origin::Local, &phone));
    assert!(for_web(Origin::Local, &phone));
    assert!(!for_web(Origin::Local, &serde_json::json!({"_meta": {"acpmux": {"via": "app"}}})));
    assert!(!for_web(Origin::LocalApp, &phone));
}

fn refusal(reason: &str) -> Result<(), RpcError> {
    Err(RpcError::invalid_params(reason).with_data(json!({"reason": reason, "cwd": "/x"})))
}

/// Don't trust is what a restricted chat is for; an open question still waits, and any
/// other refusal stands.
#[test]
fn a_restricted_chat_passes_only_dont_trust() {
    assert!(restricted_passes(refusal("trust.untrusted")).is_ok());
    assert!(restricted_passes(Ok(())).is_ok());
    let pending = restricted_passes(refusal("trust.pending")).unwrap_err();
    assert!(is_pending(&pending));
    assert!(restricted_passes(refusal("trust.peer_unsupported")).is_err());
}
