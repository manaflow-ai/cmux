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
use cmux_link::connect_info::{ConnectInfo, is_cloud_host};
use cmux_link::dial::{DialError, DialReply, PathState, Service, ServiceHello, line, parse_request};
use cmux_link::pairing::Pairings;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

#[cfg(test)]
use super::lines::read_line;
use super::cloud::{CloudResolver, ConnectInfoSource, serve_cloud_dial};

/// How long an overlay connect may take before the dial reports
/// `unreachable` (direct path only: a peer on the same network answers in
/// milliseconds).
pub(super) const DIAL_TIMEOUT: Duration = Duration::from_secs(5);

/// The overlay as the link sees it: outbound streams and the peer set.
pub(super) trait Overlay: Send + Sync + 'static {
    type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static;
    fn connect(&self, remote: SocketAddr) -> impl Future<Output = io::Result<Self::Stream>> + Send;
    /// Make the overlay's paired peers exactly `pairings` (Cloud peers stay).
    fn sync_peers(&self, pairings: &Pairings) -> impl Future<Output = io::Result<()>> + Send;
    /// Make Cloud host `host`'s VM endpoint a peer with `key` and the routes
    /// its connect_info offers (replacing an older key for that host).
    fn set_cloud_peer(
        &self,
        host: &str,
        key: [u8; 32],
        info: &ConnectInfo,
    ) -> impl Future<Output = io::Result<()>> + Send;
    /// Remove Cloud host `host`'s peer; its open streams end.
    fn forget_cloud_peer(&self, host: &str) -> impl Future<Output = io::Result<()>> + Send;
    /// How the peer with `key` is reached now.
    fn path_state(&self, key: &[u8; 32]) -> impl Future<Output = PathState> + Send;
}

/// Serve one `link.dial` on `caller` (already verified as this user and
/// cmux), with no Cloud hosts.
#[cfg(test)]
pub(super) async fn serve_dial<C, O>(mut caller: C, overlay: &O, pairings: &Pairings)
where
    C: AsyncRead + AsyncWrite + Unpin,
    O: Overlay,
{
    let Ok(request) = read_line(&mut caller, MAX_LINE_BYTES).await else { return };
    let resolver = CloudResolver::new(super::cloud::RelaySource);
    serve_dial_line(caller, &request, overlay, pairings, &resolver).await;
}

/// [`serve_dial`] after the caller's request line was read: a paired
/// install, or a Cloud host id resolved through connect_info.
pub(super) async fn serve_dial_line<C, O, S>(
    mut caller: C,
    request: &str,
    overlay: &O,
    pairings: &Pairings,
    resolver: &CloudResolver<S>,
) where
    C: AsyncRead + AsyncWrite + Unpin,
    O: Overlay,
    S: ConnectInfoSource,
{
    let request = match parse_request(request) {
        Ok(request) => request,
        Err(error) => return reply(&mut caller, DialReply::failed(error)).await,
    };
    let Some(record) = pairings.by_install(&request.host) else {
        if is_cloud_host(&request.host) {
            return serve_cloud_dial(caller, &request, overlay, resolver).await;
        }
        return reply(&mut caller, DialReply::failed(DialError::UnknownHost)).await;
    };
    // A paired peer serves only its daemon entry; ssh is a Cloud service.
    if request.service != Service::Daemon {
        return reply(&mut caller, DialReply::failed(DialError::NotAuthorized)).await;
    }
    let remote = SocketAddr::new(IpAddr::V6(record.overlay_address()), LINK_PORT);
    let connected = tokio::time::timeout(DIAL_TIMEOUT, overlay.connect(remote)).await;
    let Ok(Ok(mut stream)) = connected else {
        return reply(&mut caller, DialReply::failed(DialError::Unreachable)).await;
    };
    let hello = line(&ServiceHello::paired(request.service));
    if stream.write_all(hello.as_bytes()).await.is_err() {
        return reply(&mut caller, DialReply::failed(DialError::Unreachable)).await;
    }
    if caller.write_all(line(&DialReply::connected(PathState::Direct)).as_bytes()).await.is_err() {
        return;
    }
    let _ = tokio::io::copy_bidirectional(&mut caller, &mut stream).await;
}

pub(super) async fn reply<C: AsyncWrite + Unpin>(caller: &mut C, reply: DialReply) {
    let _ = caller.write_all(line(&reply).as_bytes()).await;
    let _ = caller.shutdown().await;
}
