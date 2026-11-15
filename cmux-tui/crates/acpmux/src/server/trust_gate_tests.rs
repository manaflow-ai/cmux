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
