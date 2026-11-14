use std::future::IntoFuture;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, anyhow};
use cmux_relay::{Relay, RelayCommand, TicketAuthority, version_string};
use cmux_remote_protocol::{RelayPermission, RelayRole, RelayTicketClaims};
use tokio::sync::watch;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    match RelayCommand::from_process()? {
        RelayCommand::Help => {
            print!("{}", RelayCommand::help());
            Ok(())
        }
        RelayCommand::Version => {
            println!("cmux-relay {}", version_string());
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
                issued_at_unix: now,
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
            let result = serve_until_shutdown(relay, listener, router).await;
            cleanup.abort();
            // `abort` only requests cancellation. Await the handle so the
            // cleanup task is fully stopped before the runtime begins to
            // tear down, instead of leaving its final poll implicit.
            let _ = cleanup.await;
            result
        }
    }
}

async fn serve_until_shutdown(
    relay: Relay,
    listener: cmux_relay::AdmissionListener,
    router: axum::Router,
) -> anyhow::Result<()> {
    let (shutdown_request_sender, shutdown_request_receiver) = watch::channel(false);
    let (shutdown_complete_sender, shutdown_complete_receiver) = watch::channel(false);
    let signal_relay = relay.clone();
    let signal_task = tokio::spawn(async move {
        shutdown_signal().await;
        // Flip readiness before publishing the shutdown request. This closes
        // the small window where a load-balancer probe could still see 200
        // after SIGTERM arrived, while the drain branch remains idempotent.
        signal_relay.begin_drain().await;
        let _ = shutdown_request_sender.send(true);
    });
    let server_shutdown = async move {
        // Keep Axum serving /readyz while the relay drains. The completion
        // signal is sent only after the admission gate is closed and the
        // established sockets have had their configured drain window.
        let _ = wait_for_shutdown(shutdown_complete_receiver).await;
    };
    let mut server = Box::pin(
        axum::serve(listener, router).with_graceful_shutdown(server_shutdown).into_future(),
    );

    let result = tokio::select! {
        result = &mut server => result.context("relay server failed"),
        changed = wait_for_shutdown(shutdown_request_receiver) => {
            if changed {
                relay.begin_drain().await;
                let drained = relay.wait_for_idle(relay.config().drain_timeout).await;
                if !drained {
                    eprintln!(
                        "cmux-relay drain timeout reached with {} active sockets",
                        relay.active_connections(),
                    );
                }
                let _ = shutdown_complete_sender.send(true);
                match tokio::time::timeout(Duration::from_secs(2), &mut server).await {
                    Ok(result) => result.context("relay server failed during shutdown"),
                    Err(_) => Ok(()),
                }
            } else {
                Ok(())
            }
        }
    };

    signal_task.abort();
    let _ = signal_task.await;
    result
}

async fn wait_for_shutdown(mut receiver: watch::Receiver<bool>) -> bool {
    loop {
        if *receiver.borrow() {
            return true;
        }
        if receiver.changed().await.is_err() {
            return false;
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
