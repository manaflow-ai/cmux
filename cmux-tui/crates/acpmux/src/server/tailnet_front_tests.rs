use super::*;
use serde_json::json;

#[test]
fn the_front_is_off_unless_the_setting_is_true() {
    assert!(!enabled_in(&json!({})));
    assert!(!enabled_in(&json!({"tailnet": {"stableNode": {"enabled": "yes"}}})));
    assert!(enabled_in(&json!({"tailnet": {"stableNode": {"enabled": true}}})));
    assert!(enabled_in(&json!({"tailnet.stableNode.enabled": true})));
}

#[tokio::test]
async fn the_front_outlives_a_failed_ingress_and_stops_with_either_signal() {
    let (stop, stopping) = watch::channel(false);
    let (ended, ingress_ended) = watch::channel(false);
    let mut waiting = Box::pin(until_either(stopping, ingress_ended.clone()));
    // A failed ingress sends nothing: the front is still serving a second later.
    assert!(tokio::time::timeout(Duration::from_secs(1), &mut waiting).await.is_err());
    stop.send_replace(true);
    tokio::time::timeout(Duration::from_secs(1), waiting).await.unwrap();
    // A clean ingress end stops it too.
    let (_stop, stopping) = watch::channel(false);
    let waiting = until_either(stopping, ingress_ended);
    ended.send_replace(true);
    tokio::time::timeout(Duration::from_secs(1), waiting).await.unwrap();
}

#[test]
fn the_rpc_method_is_the_fronts_own() {
    assert_eq!(crate::rpc::method::MUX_TAILNET_PLACEMENT, cmux_tailnet_front::PLACEMENT_METHOD);
}

#[test]
fn port_22_reaches_the_default_workspace() {
    let ports = ports();
    assert_eq!(
        ports.route(22).map(|route| route.workspace().to_owned()),
        Some(DEFAULT_WORKSPACE.to_owned())
    );
}
