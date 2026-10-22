//! `weft-relay`: the WebSocket relay.
//!
//! Environment: `WEFT_TICKET_PUBKEY` (required, the coordinator's ticket
//! authority, standard base64), `FLY_REGION` or `WEFT_REGION`, `PORT`
//! (default 8080).

use anyhow::Context;
use cmux_weft::relay::{RelayConfig, serve_relay};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let public = std::env::var("WEFT_TICKET_PUBKEY").context("WEFT_TICKET_PUBKEY")?;
    let ticket_public_key = cmux_weft::b64::decode_key(public.trim())
        .context("WEFT_TICKET_PUBKEY: 32 bytes, base64")?;
    let region = std::env::var("WEFT_REGION")
        .or_else(|_| std::env::var("FLY_REGION"))
        .unwrap_or_else(|_| "local".into());
    let port: u16 = std::env::var("PORT").ok().and_then(|port| port.parse().ok()).unwrap_or(8080);
    let listener = tokio::net::TcpListener::bind(("::", port)).await?;
    eprintln!("weft-relay {} region {region} on :{port}", env!("CARGO_PKG_VERSION"));
    serve_relay(listener, RelayConfig { ticket_public_key, region }).await
}
