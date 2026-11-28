//! Host side of the guest agent: Firecracker's vsock bridge on the VM's `v.sock`, then one framed
//! request and reply (see [`crate::proto`]).

use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

use crate::proto::{GUEST_AGENT_PORT, GuestRequest, GuestResponse, MAX_FRAME};

/// Send `req` to the guest agent behind `vsock_uds` and wait up to `timeout` for its reply.
pub async fn request(
    vsock_uds: &Path,
    req: &GuestRequest,
    timeout: Duration,
) -> Result<GuestResponse> {
    tokio::time::timeout(timeout, request_inner(vsock_uds, req))
        .await
        .context("guest agent did not answer in time")?
}

async fn request_inner(vsock_uds: &Path, req: &GuestRequest) -> Result<GuestResponse> {
    let stream = UnixStream::connect(vsock_uds)
        .await
        .with_context(|| format!("connect {}", vsock_uds.display()))?;
    let mut stream = BufReader::new(stream);
    stream.get_mut().write_all(format!("CONNECT {GUEST_AGENT_PORT}\n").as_bytes()).await?;
    let mut line = String::new();
    stream.read_line(&mut line).await?;
    if !line.starts_with("OK ") {
        bail!("vsock bridge refused: {:?}", line.trim());
    }
    let body = serde_json::to_vec(req)?;
    let len = u32::try_from(body.len()).context("request too large")?;
    stream.get_mut().write_all(&len.to_be_bytes()).await?;
    stream.get_mut().write_all(&body).await?;
    let mut len = [0u8; 4];
    stream.read_exact(&mut len).await?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        bail!("guest reply of {len} bytes is over the frame limit");
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body).await?;
    Ok(serde_json::from_slice(&body)?)
}

/// Step the guest's realtime clock to the host's ([`GuestRequest::SetClock`]); returns how far
/// it moved, in nanoseconds. The host time is read as the request is built, so the guest ends up
/// within one vsock round trip of the host.
pub async fn set_clock(vsock_uds: &Path, timeout: Duration) -> Result<i64> {
    let unix_ns = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .context("host clock before 1970")?
        .as_nanos();
    let unix_ns = u64::try_from(unix_ns).context("host clock past 2554")?;
    match request(vsock_uds, &GuestRequest::SetClock { unix_ns }, timeout).await? {
        GuestResponse::Clock { stepped_ns } => Ok(stepped_ns),
        GuestResponse::Error { message } => bail!("guest: {message}"),
        other => bail!("unexpected set-clock reply: {other:?}"),
    }
}

/// Ping the agent until it answers or `deadline` passes; returns the guest's uptime in ms.
pub async fn wait_ready(vsock_uds: &Path, deadline: Duration) -> Result<u64> {
    let start = Instant::now();
    loop {
        match request(vsock_uds, &GuestRequest::Ping, Duration::from_millis(500)).await {
            Ok(GuestResponse::Pong { uptime_ms }) => return Ok(uptime_ms),
            Ok(other) => bail!("unexpected ping reply: {other:?}"),
            Err(e) if start.elapsed() >= deadline => {
                return Err(e.context(format!("guest agent not ready after {deadline:?}")));
            }
            Err(_) => tokio::time::sleep(Duration::from_millis(5)).await,
        }
    }
}
