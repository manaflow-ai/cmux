//! The stable tailnet node's front, served on this daemon's embedded node (setting
//! `tailnet.stableNode.enabled`, off by default).
//!
//! Leo, 2026-11-24: "perhaps we moreso have a single stable one or a few per user, idk, and the
//! rest underlying shifts beneath their feet with none the wiser". While the embedded node runs,
//! its port 22 forwards to wherever the `default` workspace runs now (the hub's placement table,
//! which `_acpmux/tailnet/placement` updates). A connection keeps the target it was accepted
//! with; a move sends only new connections to the new place. `cmux_tailnet_front` holds the
//! table, the messages and the forwarder; this file only starts and stops them with the node.

use std::sync::Arc;
use std::time::Duration;

use cmux_tailnet::Node;
use cmux_tailnet_front::tsnet::TailnetListener;
use cmux_tailnet_front::{Front, PortMap, TcpDialer};
use tokio::sync::watch;

use crate::hub::Hub;

/// The settings key that turns the front on.
pub const SETTING_ENABLED: &str = "tailnet.stableNode.enabled";
/// The workspace port 22 reaches until the app names others.
pub const DEFAULT_WORKSPACE: &str = "default";
/// How long closing the front's listeners and open connections may take.
const CLOSE_BOUND: Duration = Duration::from_secs(2);

/// Whether the setting is on. Off when the settings file is missing or unreadable.
pub fn enabled() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => enabled_in(&doc),
        _ => false,
    }
}

fn enabled_in(doc: &serde_json::Value) -> bool {
    crate::user_settings::value(doc, SETTING_ENABLED).and_then(|v| v.as_bool()).unwrap_or(false)
}

/// The ports the front serves.
fn ports() -> PortMap {
    PortMap::ssh_layout(DEFAULT_WORKSPACE, &[])
}

/// Serve the front on `node` until `stop` or `ingress_ended` turns true (or a sender is gone).
/// Does nothing when the setting is off. A port that cannot be opened is logged and skipped; the
/// node's other listeners are not affected.
pub async fn serve(
    hub: Arc<Hub>,
    node: Arc<Node>,
    stop: watch::Receiver<bool>,
    ingress_ended: watch::Receiver<bool>,
) {
    if !enabled() {
        tracing::info!("tailnet front: off ({SETTING_ENABLED} is not true)");
        return;
    }
    let front = Front::new(Arc::clone(&hub.tailnet_placements), TcpDialer);
    let mut serving = Vec::new();
    for (port, route) in ports().0 {
        match TailnetListener::bind(Arc::clone(&node), port).await {
            Ok(listener) => {
                front.spawn_serve(listener, route);
                serving.push(port);
            }
            Err(error) => tracing::warn!("tailnet front: port {port} not served: {error}"),
        }
    }
    tracing::info!("tailnet front: serving {serving:?}");
    until_either(stop, ingress_ended).await;
    let report = front.close(CLOSE_BOUND).await;
    tracing::info!("tailnet front: closed ({report:?})");
    // The listeners held clones of the node; the service releases its own off the runtime.
    crate::tailnet::embedded::release_node(node);
}

/// Until either signal turns true or its sender is gone.
async fn until_either(mut a: watch::Receiver<bool>, mut b: watch::Receiver<bool>) {
    tokio::select! {
        _ = a.wait_for(|stopped| *stopped) => {}
        _ = b.wait_for(|stopped| *stopped) => {}
    }
}

#[cfg(test)]
mod tests {
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
}
