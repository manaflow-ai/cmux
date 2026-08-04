use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, bail, ensure};
use cmux_remote::provider::{IrohAdmission, IrohListenerLimits};
use tokio::net::UnixStream;
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

use crate::CMUX_TUI_ALPN;
use crate::broker::unix_time;
use crate::grant::{verify_server_admission, verify_server_preflight};
use crate::transport::{
    DISCOVERY_MAX_AGE, EndpointRuntime, acknowledge_admission, bridge_unix_and_iroh,
    receive_admission,
};

pub async fn serve(
    runtime: Arc<EndpointRuntime>,
    session_socket: PathBuf,
    shutdown: CancellationToken,
) -> Result<()> {
    ensure!(
        runtime.binding.platform == crate::broker::Platform::Linux,
        "server binding is not Linux"
    );
    ensure!(runtime.binding.pairing_enabled, "server binding does not permit pairing");
    let limits = IrohListenerLimits::default()
        .validate()
        .map_err(|error| anyhow::anyhow!(error.to_string()))?;
    let admission = Arc::new(IrohAdmission::new(limits));
    let mut connections = JoinSet::new();
    let refresh_shutdown = shutdown.child_token();
    let refresh_runtime = Arc::clone(&runtime);
    let mut refresh =
        tokio::spawn(
            async move { refresh_runtime.refresh_until_cancelled(refresh_shutdown).await },
        );
    let mut refresh_finished = false;
    let mut serve_result = Ok(());

    loop {
        tokio::select! {
            _ = shutdown.cancelled() => break,
            result = &mut refresh => {
                refresh_finished = true;
                serve_result = match result {
                    Ok(result) => result,
                    Err(error) => Err(anyhow::anyhow!("relay refresh task failed: {error}")),
                };
                break;
            }
            completed = connections.join_next(), if !connections.is_empty() => {
                match completed {
                    Some(Ok(Err(_))) => eprintln!("cmux-tui-iroh: connection denied or closed"),
                    Some(Err(error)) => eprintln!("cmux-tui-iroh: connection task failed: {error}"),
                    _ => {}
                }
            }
            incoming = runtime.endpoint.accept() => {
                let Some(incoming) = incoming else { break };
                let Some(connection_reservation) = admission.try_reserve_connection() else {
                    incoming.refuse();
                    continue;
                };
                let runtime = Arc::clone(&runtime);
                let session_socket = session_socket.clone();
                let admission = Arc::clone(&admission);
                let shutdown = shutdown.child_token();
                connections.spawn(async move {
                    let limits = admission.limits();
                    let connection = tokio::time::timeout(
                        limits.connection_handshake_timeout,
                        incoming,
                    )
                    .await
                    .context("iroh TLS handshake timed out")?
                    .context("iroh TLS handshake failed")?;
                    let connection_permit = tokio::time::timeout(
                        limits.first_stream_timeout,
                        admission.acquire_connection(connection_reservation),
                    )
                    .await
                    .context("iroh connection admission timed out")?;
                    let result = serve_connection(
                        runtime,
                        session_socket,
                        admission,
                        connection.clone(),
                        shutdown,
                    )
                    .await;
                    drop(connection_permit);
                    if result.is_err() {
                        connection.close(7_u8.into(), b"cmux TUI admission failed");
                    } else {
                        connection.close(0_u8.into(), b"cmux TUI stream closed");
                    }
                    result
                });
            }
        }
    }

    shutdown.cancel();
    connections.shutdown().await;
    if !refresh_finished {
        let _ = refresh.await;
    }
    runtime.close().await;
    serve_result
}

async fn serve_connection(
    runtime: Arc<EndpointRuntime>,
    session_socket: PathBuf,
    admission: Arc<IrohAdmission>,
    connection: iroh::endpoint::Connection,
    shutdown: CancellationToken,
) -> Result<()> {
    ensure!(connection.alpn() == CMUX_TUI_ALPN, "unexpected iroh ALPN");
    let tls_initiator = connection.remote_id().to_string();
    let limits = admission.limits();
    let (mut sender, mut receiver) =
        tokio::time::timeout(limits.first_stream_timeout, connection.accept_bi())
            .await
            .context("first iroh stream timed out")?
            .context("first iroh stream failed")?;
    let stream_reservation =
        admission.try_reserve_pending_stream().context("pre-auth stream capacity exhausted")?;
    let stream_permit = tokio::time::timeout(
        limits.pre_auth_timeout,
        admission.acquire_pending_stream(stream_reservation),
    )
    .await
    .context("pre-auth stream admission timed out")?;
    let request = receive_admission(&mut receiver).await?;
    let preflight_now = unix_time()? as i64;
    let grant_keys = runtime.grant_verification_keys().await;
    let preflight = verify_server_preflight(
        &request.grant,
        &tls_initiator,
        &runtime.binding,
        &grant_keys,
        preflight_now,
    )?;
    ensure!(preflight.expires_at() > preflight_now, "pair grant expired");

    let lease = runtime.fresh_discovery_with_fleet().await?;
    let now = unix_time()? as i64;
    let claims = verify_server_admission(
        &request.grant,
        &tls_initiator,
        &runtime.binding,
        &lease.snapshot,
        &lease.relay_urls,
        now,
    )?;
    ensure!(claims.expires_at() > now, "pair grant expired");

    let local = UnixStream::connect(&session_socket).await.with_context(|| {
        format!("cannot connect admitted stream to {}", session_socket.display())
    })?;
    acknowledge_admission(&mut sender).await?;
    eprintln!(
        "cmux-tui-iroh: admitted peer={} binding={} path=relay",
        connection.remote_id().fmt_short(),
        claims.initiator.binding_id,
    );

    let admitted = CancellationToken::new();
    let revalidation_cancel = admitted.clone();
    let revalidation_runtime = Arc::clone(&runtime);
    let revalidation_grant = request.grant;
    let revalidation_tls = tls_initiator;
    let revalidation = tokio::spawn(async move {
        let revalidation_deadline = tokio::time::sleep_until(lease.fetched_at + DISCOVERY_MAX_AGE);
        let expiry_deadline = tokio::time::sleep(Duration::from_secs(
            u64::try_from(claims.expires_at().saturating_sub(now)).unwrap_or(0),
        ));
        tokio::pin!(revalidation_deadline);
        tokio::pin!(expiry_deadline);
        loop {
            tokio::select! {
                _ = revalidation_cancel.cancelled() => return Ok::<(), anyhow::Error>(()),
                _ = &mut expiry_deadline => bail!("pair grant expired"),
                _ = &mut revalidation_deadline => {
                    let now = unix_time()? as i64;
                    ensure!(now < claims.expires_at(), "pair grant expired");
                    let lease = revalidation_runtime.fresh_discovery_with_fleet().await?;
                    verify_server_admission(
                        &revalidation_grant,
                        &revalidation_tls,
                        &revalidation_runtime.binding,
                        &lease.snapshot,
                        &lease.relay_urls,
                        now,
                    )?;
                    revalidation_deadline
                        .as_mut()
                        .reset(lease.fetched_at + DISCOVERY_MAX_AGE);
                }
            }
        }
    });

    let bridge_cancel = admitted.clone();
    let result = tokio::select! {
        result = bridge_unix_and_iroh(local, sender, receiver, bridge_cancel) => result,
        _ = shutdown.cancelled() => Ok(()),
        result = revalidation => {
            match result {
                Ok(Ok(())) => Ok(()),
                Ok(Err(error)) => Err(error.context("admitted stream revalidation failed")),
                Err(error) => Err(anyhow::anyhow!("revalidation task failed: {error}")),
            }
        }
    };
    admitted.cancel();
    drop(stream_permit);
    result
}
