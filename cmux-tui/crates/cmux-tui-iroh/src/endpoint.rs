//! Iroh endpoint construction and relay-credential maintenance.
//!
//! Every endpoint starts from the `Minimal` preset with only the verified
//! managed fleet as `RelayMode::Custom`; no discovery service, no n0 preset,
//! no environment-derived relay URLs.

use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use iroh::endpoint::{Connection, RelayMode, presets};
use iroh::{Endpoint, EndpointAddr, EndpointId, Watcher as _};

use crate::broker::{BrokerClient, RelayToken};
use crate::grant::TUI_ALPN;
use crate::identity::{Identity, load_broker_cache, save_broker_cache};
use crate::relays;

/// Binds a Minimal-preset endpoint on the managed fleet.
///
/// `accept_tui` controls whether the endpoint advertises the cmux-tui ALPN
/// (the listener does; the dialing client does not accept inbound protocols).
pub async fn bind_endpoint(
    identity: &Identity,
    relay_token: &RelayToken,
    accept_tui: bool,
) -> anyhow::Result<Endpoint> {
    let relay_map = relays::relay_map(&relay_token.token)?;
    let mut builder = Endpoint::builder(presets::Minimal)
        .secret_key(identity.secret_key()?)
        .relay_mode(RelayMode::Custom(relay_map));
    if accept_tui {
        builder = builder.alpns(vec![TUI_ALPN.to_vec()]);
    }
    builder.bind().await.context("binding iroh endpoint")
}

/// Fetches a relay token, reusing the persisted cache when it still has
/// comfortable life, and persists the result for the next process.
pub async fn fresh_relay_token(
    broker: &BrokerClient,
    identity: &Identity,
    state_root: &std::path::Path,
) -> anyhow::Result<RelayToken> {
    let cache = load_broker_cache(state_root)?;
    let cached = match (cache.relay_token.clone(), cache.relay_token_expires_at) {
        (Some(token), Some(expires_at_unix)) => Some(RelayToken { token, expires_at_unix }),
        _ => None,
    };
    let endpoint_id = identity.endpoint_id_hex()?;
    let token = broker.relay_token(&endpoint_id, cached).await?;
    let mut updated = cache;
    updated.relay_token = Some(token.token.clone());
    updated.relay_token_expires_at = Some(token.expires_at_unix);
    save_broker_cache(state_root, &updated)?;
    Ok(token)
}

/// Lazy relay-credential rotation, ported from the proven testbed daemon:
/// fleet tokens live 300 s but an established relay websocket is never
/// re-authenticated, and a live relay actor never picks up a new token, so
/// rotation = `remove_relay` + `insert_relay` and only after the relay has
/// been observed down twice (~30 s). Mints are quota-bound (3/10 min).
pub fn spawn_relay_maintenance(
    endpoint: Endpoint,
    broker: Arc<BrokerClient>,
    identity: Identity,
    state_root: std::path::PathBuf,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut down_checks = 0u32;
        loop {
            tokio::time::sleep(Duration::from_secs(15)).await;
            let mut status = endpoint.home_relay_status();
            let connected = status.get().iter().any(|st| st.is_connected());
            if connected {
                down_checks = 0;
                continue;
            }
            down_checks += 1;
            if down_checks < 2 {
                continue;
            }
            down_checks = 0;
            eprintln!("cmux-tui-iroh: relay disconnected; rotating fleet credential");
            let token = match fresh_relay_token(&broker, &identity, &state_root).await {
                Ok(token) => token,
                Err(error) => {
                    eprintln!("cmux-tui-iroh: relay credential rotation failed: {error:#}");
                    continue;
                }
            };
            match relays::relay_urls() {
                Ok(urls) => {
                    for url in urls {
                        let config = iroh::RelayConfig::from(url.clone())
                            .with_auth_token(token.token.clone());
                        endpoint.remove_relay(&url).await;
                        endpoint.insert_relay(url, Arc::new(config)).await;
                    }
                    eprintln!("cmux-tui-iroh: relay credential rotated");
                }
                Err(error) => eprintln!("cmux-tui-iroh: relay catalog reload failed: {error:#}"),
            }
        }
    })
}

/// Dials a peer by EndpointID alone: the dial address is the id plus every
/// verified fleet relay, so no home-relay knowledge is required.
pub async fn dial_by_endpoint_id(
    endpoint: &Endpoint,
    endpoint_id_hex: &str,
    timeout: Duration,
) -> anyhow::Result<Connection> {
    let id = EndpointId::from_str(endpoint_id_hex).context("parsing target EndpointID")?;
    let addr = EndpointAddr::from_parts(id, relays::catalog_transport_addrs()?);
    let connection = tokio::time::timeout(timeout, endpoint.connect(addr, TUI_ALPN))
        .await
        .context("dial timed out")?
        .context("dial failed")?;
    Ok(connection)
}

/// Short keyed prefix for logs; full EndpointIDs never enter logs.
pub fn log_id(endpoint_id_hex: &str) -> String {
    endpoint_id_hex.chars().take(8).collect()
}
