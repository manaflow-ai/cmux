use std::{net::SocketAddr, time::Duration};

use clap::{Parser, Subcommand};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMode, RelayUrl, SecretKey, TransportAddr,
    endpoint::{Connection, ConnectionError, presets},
};
use n0_error::{Result, StdResultExt, anyerr};
use serde_json::json;

const ALPN: &[u8] = b"dev.cmux.mobile.terminal/0";
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;

#[derive(Debug, Parser)]
#[command(about = "Minimal Iroh byte-transport experiment for cmux mobile")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Start an Iroh echo listener and print a CmxAttachRoute JSON snippet.
    Listen {
        /// Disable default Iroh relays for local-only tests.
        #[arg(long)]
        no_relay: bool,
        /// Exit after the first successful echo request.
        #[arg(long)]
        one_shot: bool,
    },
    /// Dial an Iroh listener and print the echoed response.
    Dial {
        #[arg(long)]
        endpoint_id: EndpointId,
        #[arg(long, value_parser, num_args = 0.., value_delimiter = ' ')]
        direct_addrs: Vec<SocketAddr>,
        #[arg(long)]
        relay_url: Option<RelayUrl>,
        /// Disable default Iroh relays for local-only tests.
        #[arg(long)]
        no_relay: bool,
        #[arg(long, default_value = "ping")]
        message: String,
    },
    /// Run a same-process listener/client smoke test.
    SelfTest {
        #[arg(long, default_value = "ping")]
        message: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();

    match Cli::parse().command {
        Command::Listen { no_relay, one_shot } => listen(!no_relay, one_shot).await,
        Command::Dial {
            endpoint_id,
            direct_addrs,
            relay_url,
            no_relay,
            message,
        } => {
            let response = dial(
                endpoint_id,
                direct_addrs,
                relay_url,
                !no_relay,
                message.as_bytes(),
            )
            .await?;
            println!("{}", String::from_utf8_lossy(&response));
            Ok(())
        }
        Command::SelfTest { message } => self_test(message.as_bytes()).await,
    }
}

async fn listen(relay: bool, one_shot: bool) -> Result<()> {
    let endpoint = bind_endpoint(relay, true).await?;
    if relay {
        endpoint.online().await;
    }
    println!("{}", attach_route_json(&endpoint));

    while let Some(incoming) = endpoint.accept().await {
        let connection = incoming.await.anyerr()?;
        serve_connection(connection).await?;
        if one_shot {
            break;
        }
    }

    endpoint.close().await;
    Ok(())
}

async fn self_test(message: &[u8]) -> Result<()> {
    let server = bind_endpoint(false, true).await?;
    let server_addr = server.addr();
    let server_task = tokio::spawn({
        let server = server.clone();
        async move {
            let incoming = server
                .accept()
                .await
                .ok_or_else(|| anyerr!("server endpoint closed before accepting"))?;
            let connection = incoming.await.anyerr()?;
            serve_connection(connection).await?;
            n0_error::Ok(())
        }
    });

    let client = bind_endpoint(false, false).await?;
    let response = send_request(&client, server_addr, message).await?;
    if response != message {
        return Err(anyerr!(
            "unexpected echo response: expected {:?}, received {:?}",
            message,
            response
        ));
    }

    client.close().await;
    server.close().await;
    server_task.await.anyerr()??;
    println!("iroh self-test ok: {}", String::from_utf8_lossy(&response));
    Ok(())
}

async fn dial(
    endpoint_id: EndpointId,
    direct_addrs: Vec<SocketAddr>,
    relay_url: Option<RelayUrl>,
    relay: bool,
    message: &[u8],
) -> Result<Vec<u8>> {
    let endpoint = bind_endpoint(relay, false).await?;
    if relay {
        endpoint.online().await;
    }

    let addr = if direct_addrs.is_empty() && relay_url.is_none() {
        EndpointAddr::from(endpoint_id)
    } else {
        let addrs = direct_addrs
            .into_iter()
            .map(TransportAddr::Ip)
            .chain(relay_url.into_iter().map(TransportAddr::Relay));
        EndpointAddr::from_parts(endpoint_id, addrs)
    };

    let response = send_request(&endpoint, addr, message).await?;
    endpoint.close().await;
    Ok(response)
}

async fn bind_endpoint(relay: bool, accepts_connections: bool) -> Result<Endpoint> {
    let mut builder = Endpoint::builder(presets::N0)
        .secret_key(SecretKey::generate())
        .relay_mode(if relay {
            RelayMode::Default
        } else {
            RelayMode::Disabled
        });

    if accepts_connections {
        builder = builder.alpns(vec![ALPN.to_vec()]);
    }

    Ok(builder.bind().await?)
}

async fn send_request(
    endpoint: &Endpoint,
    addr: impl Into<EndpointAddr>,
    message: &[u8],
) -> Result<Vec<u8>> {
    let connection = endpoint.connect(addr, ALPN).await?;
    let (mut send, mut recv) = connection.open_bi().await.anyerr()?;
    send.write_all(message).await.anyerr()?;
    send.finish().anyerr()?;
    let response = recv.read_to_end(MAX_MESSAGE_BYTES).await.anyerr()?;
    connection.close(0u32.into(), b"done");
    Ok(response)
}

async fn serve_connection(connection: Connection) -> Result<()> {
    let remote_id = connection.remote_id();
    let (mut send, mut recv) = connection.accept_bi().await.anyerr()?;
    let bytes_sent = tokio::io::copy(&mut recv, &mut send).await.anyerr()?;
    send.finish().anyerr()?;

    let closed = tokio::time::timeout(Duration::from_secs(3), connection.closed()).await;
    if let Ok(closed) = closed
        && !matches!(closed, ConnectionError::ApplicationClosed(_))
    {
        eprintln!("remote {remote_id} closed with {closed:#}");
    }
    eprintln!("echoed {bytes_sent} byte(s) for {remote_id}");
    Ok(())
}

fn attach_route_json(endpoint: &Endpoint) -> String {
    let addr = endpoint.addr();
    let direct_addrs = addr
        .ip_addrs()
        .map(|addr| addr.to_string())
        .collect::<Vec<_>>();
    let relay_url = addr.relay_urls().next().map(|url| url.to_string());
    let route = json!({
        "id": "iroh",
        "kind": "iroh",
        "endpoint": {
            "type": "peer",
            "id": endpoint.id().to_string(),
            "direct_addrs": direct_addrs,
            "relay_url": relay_url,
        },
        "priority": 20,
    });
    serde_json::to_string_pretty(&route).expect("route JSON should encode")
}
