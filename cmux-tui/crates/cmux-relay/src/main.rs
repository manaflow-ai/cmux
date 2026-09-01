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
    let (shutdown_sender, shutdown_receiver) = watch::channel(false);
    let signal_relay = relay.clone();
    let signal_task = tokio::spawn(async move {
        shutdown_signal().await;
        // Flip readiness before notifying the HTTP server. This closes the
        // handoff race where a quiet server could finish graceful shutdown
        // before the load balancer observes /readyz as draining.
        signal_relay.begin_drain();
        let _ = shutdown_sender.send(true);
    });
    let server_shutdown = wait_for_shutdown(shutdown_receiver.clone());
    let mut server =
        Box::pin(axum::serve(listener, router).with_graceful_shutdown(server_shutdown));

    let result = tokio::select! {
        result = &mut server => result.context("relay server failed"),
        changed = wait_for_shutdown(shutdown_receiver) => {
            if changed {
                // The signal task performs the transition before publishing
                // this notification. Keep this idempotent guard for future
                // shutdown sources that may send the watch signal directly.
                relay.begin_drain();
                let drained = relay.wait_for_idle(relay.config().drain_timeout).await;
                if !drained {
                    eprintln!(
                        "cmux-relay drain timeout reached with {} active sockets",
                        relay.active_connections(),
                    );
                }
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
