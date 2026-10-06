//! The daemon's loopback-forward policy: `server.loopback_forward` from
//! cmux-tui.json, minus the ports the daemon itself listens on.

/// `server.loopback_forward` from cmux-tui.json. An invalid value turns
/// forwarding off instead of widening access.
pub(crate) fn loopback_forward_policy(
    value: Option<&serde_json::Value>,
) -> cmux_tui_core::server::LoopbackForwardPolicy {
    use cmux_tui_core::server::LoopbackForwardPolicy;
    let Some(value) = value else { return LoopbackForwardPolicy::default() };
    match LoopbackForwardPolicy::from_config_value(value) {
        Ok(policy) => policy,
        Err(error) => {
            crate::client_log::stderr_log!(
                "startup",
                "cmux-tui: server.loopback_forward is invalid ({error}); loopback forwarding is off"
            );
            LoopbackForwardPolicy::disabled()
        }
    }
}

/// Denies loopback forwarding to ports this daemon listens on, so a forwarded
/// page can never reach the daemon itself. Port 0 (not yet bound) is skipped.
#[cfg(unix)]
pub(crate) fn deny_daemon_listener_ports<const N: usize>(
    policy: &mut cmux_tui_core::server::LoopbackForwardPolicy,
    addresses: [Option<std::net::SocketAddr>; N],
) {
    for address in addresses.into_iter().flatten().filter(|address| address.port() != 0) {
        policy.deny_port(address.port());
    }
}
