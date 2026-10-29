//! `weft-coord`: the coordination and ACL service.
//!
//! Environment:
//! - `WEFT_ADMIN_TOKEN` (required, 24+ characters)
//! - `WEFT_TICKET_SEED` (required): Ed25519 seed, standard base64, 32 bytes
//! - `WEFT_RELAYS` (required): `region=wss://host/v1/relay,region=...`
//! - `WEFT_DB` (default `/data/weft.sqlite`), `PORT` (default 8080)

use anyhow::{Context, bail};
use cmux_weft::coord::{CoordConfig, serve_coord};
use cmux_weft::keys::SigningKey;
use cmux_weft::types::RelayInfo;

fn parse_relays(text: &str) -> anyhow::Result<Vec<RelayInfo>> {
    let mut relays = Vec::new();
    for entry in text.split(',').map(str::trim).filter(|entry| !entry.is_empty()) {
        let (region, url) =
            entry.split_once('=').context("WEFT_RELAYS entry must be region=url")?;
        if !(url.starts_with("wss://") || url.starts_with("ws://")) {
            bail!("relay url must be ws:// or wss://: {url}");
        }
        relays.push(RelayInfo { region: region.to_owned(), url: url.to_owned() });
    }
    Ok(relays)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let admin_token = std::env::var("WEFT_ADMIN_TOKEN").context("WEFT_ADMIN_TOKEN")?;
    let seed = std::env::var("WEFT_TICKET_SEED").context("WEFT_TICKET_SEED")?;
    let seed =
        cmux_weft::b64::decode_key(seed.trim()).context("WEFT_TICKET_SEED: 32 bytes, base64")?;
    let relays = parse_relays(&std::env::var("WEFT_RELAYS").context("WEFT_RELAYS")?)?;
    let database = std::env::var("WEFT_DB").unwrap_or_else(|_| "/data/weft.sqlite".into());
    let port: u16 = std::env::var("PORT").ok().and_then(|port| port.parse().ok()).unwrap_or(8080);
    let listener = tokio::net::TcpListener::bind(("::", port)).await?;
    let ticket_key = SigningKey::from_seed(seed);
    eprintln!(
        "weft-coord {} on :{port}, {} relays, ticket authority {}",
        env!("CARGO_PKG_VERSION"),
        relays.len(),
        cmux_weft::b64::encode_key(&ticket_key.public())
    );
    serve_coord(
        listener,
        CoordConfig { database: database.into(), admin_token, ticket_key, relays },
    )
    .await
}
