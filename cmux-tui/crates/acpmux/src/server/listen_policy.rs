//! The web + WebSocket listener's address check and its Origin and Host rule.

use super::*;

/// Refuse `addr` before binding it when any address it names is not
/// loopback and the person did not opt in.
pub async fn check_listen_address(addr: &str, allow_network: bool) -> Result<()> {
    if allow_network {
        return Ok(());
    }
    let addrs: Vec<std::net::SocketAddr> = match addr.parse() {
        Ok(one) => vec![one],
        Err(_) => tokio::net::lookup_host(addr).await.map(Iterator::collect).unwrap_or_default(),
    };
    ws_auth::check_listen(addr, &addrs, false)
}

/// The origin of the app's bundled agent pane page (a `cmux-agent` URL
/// scheme handler). A `file://` page would send `Origin: null`, which every
/// localhost listener refuses.
pub const AGENT_PANE_ORIGIN: &str = "cmux-agent://pane";

/// The Origin and Host rule of this listener: its own origin (the
/// dashboard page), the agent pane, and the origins and hosts the config
/// adds (`websocket.allowed_origins`, `websocket.allowed_hosts`). Never
/// `null`. An entry that does not parse is skipped with a warning. The Host
/// rule holds on every bind: a non-loopback `websocket.listen` also accepts
/// IP address literals, and the names clients use must be listed in
/// `websocket.allowed_hosts`.
pub fn listener_policy(
    address: std::net::SocketAddr,
    extra_origins: &[String],
    extra_hosts: &[String],
) -> ListenerPolicy {
    if !address.ip().is_loopback() && extra_hosts.is_empty() {
        tracing::warn!(
            "websocket.listen {address} is not loopback: clients may connect by IP address only; list host names in websocket.allowedHosts"
        );
    }
    for origin in extra_origins {
        if cmux_local_auth::parse_origin(origin).is_none() {
            tracing::warn!(
                "websocket.allowed_origins: ignoring {origin:?} (not scheme://host[:port])"
            );
        }
    }
    policy_with(address, extra_origins, extra_hosts)
}

/// [`listener_policy`] without its warnings: an origin that does not parse is skipped.
fn policy_with(
    address: std::net::SocketAddr,
    extra_origins: &[String],
    extra_hosts: &[String],
) -> ListenerPolicy {
    let mut policy =
        ListenerPolicy::for_bind_keeping_host_rule(address).with_origin(AGENT_PANE_ORIGIN);
    for origin in extra_origins {
        if cmux_local_auth::parse_origin(origin).is_some() {
            policy = policy.with_origin(origin);
        }
    }
    for host in extra_hosts {
        policy = policy.with_host(host);
    }
    policy
}

/// The origins and hosts the config adds to the listener now: `websocket.allowedOrigins` (with
/// this run's `--allow-dev-origin`s) and `websocket.allowedHosts`.
pub(super) async fn configured_extras(hub: &Hub) -> (Vec<String>, Vec<String>) {
    let config = hub.config.read().await;
    let (mut origins, hosts) = config
        .websocket
        .as_ref()
        .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone()))
        .unwrap_or_default();
    origins.extend(config.dev_origins.iter().cloned());
    (origins, hosts)
}

/// [`listener_policy`] as the config has it at this moment, without its start warnings.
pub(super) async fn configured_policy(hub: &Hub, address: std::net::SocketAddr) -> ListenerPolicy {
    let (extra_origins, extra_hosts) = configured_extras(hub).await;
    policy_with(address, &extra_origins, &extra_hosts)
}

/// Validate a `--allow-dev-origin` value: only a loopback `http` origin with
/// an explicit port (a page dev server on this machine). Anything else is an
/// error, so the flag can never admit a web site.
pub fn dev_origin(value: &str) -> Result<String> {
    let origin = cmux_local_auth::parse_origin(value)
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} is not scheme://host:port"))?;
    let rest = origin
        .strip_prefix("http://")
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} must be http"))?;
    let (host, port) = rest
        .rsplit_once(':')
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} needs a port"))?;
    anyhow::ensure!(
        matches!(host, "127.0.0.1" | "localhost" | "[::1]") && port.parse::<u16>().is_ok(),
        "--allow-dev-origin {value:?} must be a loopback host with a port"
    );
    Ok(origin)
}

/// An accepted web socket streams many small ACP deltas: send each at once (no Nagle delay).
pub(super) fn tune_ws_socket(stream: &tokio::net::TcpStream) {
    if let Err(e) = stream.set_nodelay(true) {
        tracing::debug!("ws TCP_NODELAY: {e}");
    }
}
