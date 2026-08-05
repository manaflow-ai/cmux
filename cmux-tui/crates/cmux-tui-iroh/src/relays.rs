//! The verified managed relay catalog.
//!
//! The runtime reads the crate-local `relay-catalog.json` via `include_str!`;
//! it is a compiled-in copy of the committed server-owned source of truth at
//! `config/iroh/managed-relay-catalog.json`, and the golden test below fails
//! when the copy drifts from that canonical file. Per the transport
//! architecture, relay URLs never come from the environment and the n0
//! defaults are never used.

use std::sync::Arc;

use anyhow::Context;
use iroh::{RelayConfig, RelayMap, RelayUrl, TransportAddr};
use serde::Deserialize;

pub const RELAY_CATALOG_JSON: &str = include_str!("../relay-catalog.json");

#[derive(Debug, Deserialize)]
struct Catalog {
    relays: Vec<CatalogEntry>,
}

#[derive(Debug, Deserialize)]
struct CatalogEntry {
    id: String,
    url: String,
}

/// Managed relay URLs in catalog order.
pub fn relay_urls() -> anyhow::Result<Vec<RelayUrl>> {
    let catalog: Catalog =
        serde_json::from_str(RELAY_CATALOG_JSON).context("parsing embedded relay catalog")?;
    let mut urls = Vec::with_capacity(catalog.relays.len());
    for entry in catalog.relays {
        let url = entry
            .url
            .parse::<RelayUrl>()
            .with_context(|| format!("relay {} has an invalid url", entry.id))?;
        urls.push(url);
    }
    anyhow::ensure!(!urls.is_empty(), "embedded relay catalog is empty");
    Ok(urls)
}

/// Builds the relay map with the endpoint-bound fleet credential attached to
/// every relay. The fleet rejects unauthenticated websocket upgrades.
pub fn relay_map(auth_token: &str) -> anyhow::Result<RelayMap> {
    let configs = relay_urls()?
        .into_iter()
        .map(|url| Arc::new(RelayConfig::from(url).with_auth_token(auth_token)));
    Ok(RelayMap::from_iter(configs))
}

/// Every catalog relay as a candidate transport address. Combined with an
/// EndpointID from the account registry this is the complete dial address:
/// the dialer needs no knowledge of the peer's home relay.
pub fn catalog_transport_addrs() -> anyhow::Result<Vec<TransportAddr>> {
    Ok(relay_urls()?.into_iter().map(TransportAddr::Relay).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_catalog_parses_with_relays() {
        let urls = relay_urls().unwrap();
        assert!(!urls.is_empty());
        for url in &urls {
            assert!(url.to_string().starts_with("https://"));
        }
    }

    /// The embedded copy must match the committed catalog when building
    /// inside the cmux repo. Standalone source archives lack the canonical
    /// file; the test skips there instead of failing packaging builds.
    #[test]
    fn embedded_catalog_matches_committed_source_of_truth() {
        // CARGO_MANIFEST_DIR = <repo>/cmux-tui/crates/cmux-tui-iroh; the
        // canonical catalog lives at <repo>/config/iroh/.
        let canonical = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../config/iroh/managed-relay-catalog.json");
        let Ok(canonical_contents) = std::fs::read_to_string(&canonical) else {
            eprintln!("skipping: canonical catalog not present at {}", canonical.display());
            return;
        };
        let canonical_json: serde_json::Value = serde_json::from_str(&canonical_contents).unwrap();
        let embedded_json: serde_json::Value = serde_json::from_str(RELAY_CATALOG_JSON).unwrap();
        assert_eq!(
            embedded_json, canonical_json,
            "crates/cmux-tui-iroh/relay-catalog.json is out of sync with \
             config/iroh/managed-relay-catalog.json; copy the canonical file over it"
        );
    }
}
