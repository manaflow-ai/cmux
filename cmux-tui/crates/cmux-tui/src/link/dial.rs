//! `link.dial` from a local caller: find the paired host, open an overlay
//! stream to its link, send the service hello, answer the caller, then
//! carry bytes both ways on the caller's connection.

use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use cmux_link::LINK_PORT;
#[cfg(test)]
use cmux_link::dial::MAX_LINE_BYTES;
use cmux_link::dial::{DialError, DialReply, PathState, ServiceHello, line, parse_request};
use cmux_link::pairing::Pairings;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

#[cfg(test)]
use super::lines::read_line;

/// How long an overlay connect may take before the dial reports
/// `unreachable` (direct path only: a peer on the same network answers in
/// milliseconds).
pub(super) const DIAL_TIMEOUT: Duration = Duration::from_secs(5);

/// The overlay as the link sees it: outbound streams and the peer set.
pub(super) trait Overlay: Send + Sync + 'static {
    type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static;
    fn connect(&self, remote: SocketAddr) -> impl Future<Output = io::Result<Self::Stream>> + Send;
    /// Make the overlay's peers exactly the paired peers.
    fn sync_peers(&self, pairings: &Pairings) -> impl Future<Output = io::Result<()>> + Send;
}

/// Serve one `link.dial` on `caller` (already verified as this user and cmux).
#[cfg(test)]
pub(super) async fn serve_dial<C, O>(mut caller: C, overlay: &O, pairings: &Pairings)
where
    C: AsyncRead + AsyncWrite + Unpin,
    O: Overlay,
{
    let Ok(request) = read_line(&mut caller, MAX_LINE_BYTES).await else { return };
    serve_dial_line(caller, &request, overlay, pairings).await;
}

/// [`serve_dial`] after the caller's request line was read.
pub(super) async fn serve_dial_line<C, O>(
    mut caller: C,
    request: &str,
    overlay: &O,
    pairings: &Pairings,
) where
    C: AsyncRead + AsyncWrite + Unpin,
    O: Overlay,
{
    let request = match parse_request(request) {
        Ok(request) => request,
        Err(error) => return reply(&mut caller, DialReply::failed(error)).await,
    };
    let Some(record) = pairings.by_install(&request.host) else {
        return reply(&mut caller, DialReply::failed(DialError::UnknownHost)).await;
    };
    let remote = SocketAddr::new(IpAddr::V6(record.overlay_address()), LINK_PORT);
    let connected = tokio::time::timeout(DIAL_TIMEOUT, overlay.connect(remote)).await;
    let Ok(Ok(mut stream)) = connected else {
        return reply(&mut caller, DialReply::failed(DialError::Unreachable)).await;
    };
    let hello = line(&ServiceHello { service: request.service });
    if stream.write_all(hello.as_bytes()).await.is_err() {
        return reply(&mut caller, DialReply::failed(DialError::Unreachable)).await;
    }
    if caller.write_all(line(&DialReply::connected(PathState::Direct)).as_bytes()).await.is_err() {
        return;
    }
    let _ = tokio::io::copy_bidirectional(&mut caller, &mut stream).await;
}

async fn reply<C: AsyncWrite + Unpin>(caller: &mut C, reply: DialReply) {
    let _ = caller.write_all(line(&reply).as_bytes()).await;
    let _ = caller.shutdown().await;
}
