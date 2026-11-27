//! `cmux remote dial-tcp`: one loopback TCP stream on the remote machine,
//! carried on stdin and stdout, so the tunnel can be an ssh `ProxyCommand`.

use std::path::Path;

use anyhow::anyhow;
use cmux_remote::bridge::dial_tcp_route;
use cmux_remote::client::WorkspaceClient;
use cmux_remote_protocol::WorkspaceRequest;

use super::{
    FORWARD_CLEANUP_TIMEOUT, InvitationArg, create_loopback_route, parse_connect_flags,
    start_connected, tokio_runtime,
};
use crate::localization::catalog;

/// The workspace a dial opens when `--workspace-root` is not given. The
/// daemon scopes routes to an open workspace; the stream reads no files, so
/// any directory every Unix machine has will do.
const DIAL_TCP_WORKSPACE_ROOT: &str = "/";

pub(super) fn run_dial_tcp(args: &[String]) -> anyhow::Result<()> {
    let messages = &catalog().remote_client;
    let flags = parse_connect_flags(args)?;
    // stdin is the stream: no other input may read from it.
    if flags.wireguard_hub_token_stdin
        || matches!(&flags.invitation, Some(InvitationArg::File(path)) if path == Path::new("-"))
    {
        return Err(anyhow!(messages.dial_tcp_stdin_taken));
    }
    let workspace_root =
        flags.forward_workspace.clone().unwrap_or_else(|| DIAL_TCP_WORKSPACE_ROOT.into());
    let host = flags.forward_host.clone().unwrap_or_else(|| "127.0.0.1".into());
    let port = flags.forward_port.ok_or_else(|| anyhow!(messages.dial_tcp_port_required))?;
    let connected = start_connected(flags)?;
    let runtime = tokio_runtime()?;
    let result = runtime.block_on(async {
        let multiplexer = connected.runtime.multiplexer();
        let mut finished = connected.runtime.subscribe_finished();
        // Setup waits on the daemon too: a signal or a lost session must end a
        // ProxyCommand whose workspace or route reply never comes.
        let setup = async {
            let client = WorkspaceClient::connect(multiplexer.clone()).await?;
            let route = create_loopback_route(&client, workspace_root, host, port).await?;
            anyhow::Ok((client, route))
        };
        let (client, route) = tokio::select! {
            biased;
            shutdown = crate::wait_for_shutdown_signal_async() => {
                return match shutdown {
                    Ok(()) => Err(anyhow!(messages.dial_tcp_interrupted)),
                    Err(error) => Err(error.into()),
                };
            }
            _ = finished.wait_for(|finished| *finished) => {
                return Err(anyhow!(messages.dial_tcp_session_ended));
            }
            setup = setup => setup?,
        };
        let outcome = if crate::shutdown_requested() {
            Err(anyhow!(messages.dial_tcp_interrupted))
        } else {
            tokio::select! {
                biased;
                shutdown = crate::wait_for_shutdown_signal_async() => match shutdown {
                    Ok(()) => Err(anyhow!(messages.dial_tcp_interrupted)),
                    Err(error) => Err(error.into()),
                },
                _ = finished.wait_for(|finished| *finished) => {
                    Err(anyhow!(messages.dial_tcp_session_ended))
                }
                dialed = dial_tcp_route(
                    multiplexer,
                    route,
                    tokio::io::stdin(),
                    tokio::io::stdout(),
                ) => dialed.map_err(anyhow::Error::from),
            }
        };
        let _ = tokio::time::timeout(
            FORWARD_CLEANUP_TIMEOUT,
            client.request(WorkspaceRequest::CloseRoute { route }),
        )
        .await;
        outcome
    });
    // Tokio reads stdin on a blocking thread that cannot be cancelled; when
    // the remote closes first, that read must not hold the exit.
    runtime.shutdown_background();
    let shutdown = connected.runtime.shutdown();
    result.and(shutdown)
}
