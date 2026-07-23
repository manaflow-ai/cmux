use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, anyhow};
use cmux_relay::{Relay, RelayCommand, TicketAuthority};
use cmux_remote_protocol::{RelayPermission, RelayRole, RelayTicketClaims};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    match RelayCommand::from_process()? {
        RelayCommand::Help => {
            print!("{}", RelayCommand::help());
            Ok(())
        }
        RelayCommand::Ticket { secret, issuer, permission, slot, lane, generation, ttl } => {
            let authority = TicketAuthority::hmac_with_issuer(secret, issuer.clone())?;
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| anyhow!("system clock is before the Unix epoch"))?
                .as_secs();
            let expires_at_unix = now
                .checked_add(ttl.as_secs())
                .ok_or_else(|| anyhow!("ticket expiry overflowed Unix time"))?;
            let role = match permission {
                RelayPermission::Register => RelayRole::Daemon,
                RelayPermission::Connect => RelayRole::Client,
                RelayPermission::Join => unreachable!("CLI cannot mint join tickets"),
            };
            let claims = RelayTicketClaims {
                version: RelayTicketClaims::VERSION,
                issuer,
                permission,
                role,
                slot,
                circuit: None,
                lane,
                generation,
                expires_at_unix,
            };
            println!("{}", authority.issue(&claims)?);
            Ok(())
        }
        RelayCommand::Serve(config) => {
            let listener = tokio::net::TcpListener::bind(config.bind)
                .await
                .with_context(|| format!("failed to bind relay at {}", config.bind))?;
            let address = listener.local_addr()?;
            let relay = Relay::new(config)?;
            let cleanup = relay.spawn_cleanup();
            let (listener, router) = relay.server_parts(listener);
            eprintln!("cmux-relay listening on {address}");
            let result = axum::serve(listener, router)
                .with_graceful_shutdown(shutdown_signal())
                .await
                .context("relay server failed");
            cleanup.abort();
            result
        }
    }
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("failed to install SIGTERM handler");
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                let _ = result;
            }
            _ = terminate.recv() => {}
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
