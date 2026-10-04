//! `link.dial` to a Cloud host id (cloud-client-contract.md 1.7, decision
//! LINK-RESOLVE): the link resolves `cloud.machine.connect_info` itself,
//! configures the VM endpoint as a mesh peer, opens its link port, and
//! sends the hello with the record's single-use token.

use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;
use std::time::Instant;

use cmux_link::LINK_PORT;
use cmux_link::connect_info::{
    ConnectInfo, ConnectInfoCache, ConnectInfoError, LinkToken, is_cloud_host,
};
use cmux_link::dial::{
    CloudEvent, CloudEventRequest, DialError, DialReply, DialRequest, ServiceHello, line,
};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

use super::dial::{DIAL_TIMEOUT, Overlay, reply};

/// Where connect_info comes from: the host credential relay in the product,
/// a fake in tests.
pub(super) trait ConnectInfoSource: Send + Sync + 'static {
    fn fetch(&self, host: &str)
    -> impl Future<Output = Result<ConnectInfo, ConnectInfoError>> + Send;
}

/// The host credential relay (`cmux.credential.relay`, owned by the apps
/// lanes). It is not served yet, so every fetch answers `Unavailable` and a
/// Cloud dial reports `unreachable`. Gated off until the relay ships.
pub(super) struct RelaySource;

impl ConnectInfoSource for RelaySource {
    async fn fetch(&self, _host: &str) -> Result<ConnectInfo, ConnectInfoError> {
        Err(ConnectInfoError::Unavailable("the cmux credential relay is not available yet".into()))
    }
}

/// connect_info with the contract's cache rules.
pub(super) struct CloudResolver<S> {
    source: S,
    cache: Mutex<ConnectInfoCache>,
}

/// One fetched record, checked, with its token taken out of it.
pub(super) struct Resolved {
    pub info: ConnectInfo,
    pub key: [u8; 32],
    pub token: Option<LinkToken>,
}

impl<S: ConnectInfoSource> CloudResolver<S> {
    pub(super) fn new(source: S) -> Self {
        Self { source, cache: Mutex::new(ConnectInfoCache::default()) }
    }

    /// Fetch `host` (every dial needs a fresh single-use token), check the
    /// record, cache it without the token.
    pub(super) async fn resolve(&self, host: &str) -> Result<Resolved, ConnectInfoError> {
        let info = self.source.fetch(host).await?;
        let key = info.validate(host).map_err(ConnectInfoError::Invalid)?;
        let token = self.cache.lock().unwrap().insert(info.clone(), Instant::now());
        let mut info = info;
        info.link_token = None;
        Ok(Resolved { info, key, token })
    }

    /// `cloud.machine.removed`: drop the record at once.
    pub(super) fn forget(&self, host: &str) -> bool {
        self.cache.lock().unwrap().remove(host)
    }

    /// `cloud.machine.upsert` with `revision`: drop an older record.
    pub(super) fn observe_revision(&self, host: &str, revision: u64) -> bool {
        self.cache.lock().unwrap().observe_revision(host, revision)
    }
}

/// Apply one forwarded Cloud machine event; true when it was understood.
pub(super) async fn apply_cloud_event<O: Overlay, S: ConnectInfoSource>(
    event: &CloudEventRequest,
    overlay: &O,
    resolver: &CloudResolver<S>,
) -> bool {
    if !is_cloud_host(&event.host) {
        return false;
    }
    match (event.event, event.revision) {
        (CloudEvent::Removed, _) => {
            resolver.forget(&event.host);
            overlay.forget_cloud_peer(&event.host).await.is_ok()
        }
        (CloudEvent::Upsert, Some(revision)) => {
            resolver.observe_revision(&event.host, revision);
            true
        }
        (CloudEvent::Upsert, None) => false,
    }
}

/// Serve one `link.dial` for a Cloud host id.
pub(super) async fn serve_cloud_dial<C, O, S>(
    mut caller: C,
    request: &DialRequest,
    overlay: &O,
    resolver: &CloudResolver<S>,
) where
    C: AsyncRead + AsyncWrite + Unpin,
    O: Overlay,
    S: ConnectInfoSource,
{
    let host = request.host.as_str();
    let mut resolved = match resolver.resolve(host).await {
        Ok(resolved) => resolved,
        Err(error) => return reply(&mut caller, DialReply::failed(error.dial_error())).await,
    };
    let remote = SocketAddr::new(IpAddr::V6(resolved.info.peer.overlay_address), LINK_PORT);
    let mut refetched = false;
    let mut stream = loop {
        if !resolved.info.allows(request.service) {
            return reply(&mut caller, DialReply::failed(DialError::NotAuthorized)).await;
        }
        let attempt = async {
            overlay.set_cloud_peer(host, resolved.key, &resolved.info).await?;
            overlay.connect(remote).await
        };
        if let Ok(Ok(stream)) = tokio::time::timeout(DIAL_TIMEOUT, attempt).await {
            break stream;
        }
        // Rule 3: a handshake failure fetches once more before it reports.
        if refetched {
            let error =
                if resolved.info.is_paused() { DialError::HostPaused } else { DialError::Unreachable };
            return reply(&mut caller, DialReply::failed(error)).await;
        }
        refetched = true;
        resolved = match resolver.resolve(host).await {
            Ok(resolved) => resolved,
            Err(error) => return reply(&mut caller, DialReply::failed(error.dial_error())).await,
        };
    };
    let Some(token) = resolved.token.take() else {
        return reply(&mut caller, DialReply::failed(DialError::NotAuthorized)).await;
    };
    let hello = ServiceHello {
        service: request.service,
        link_token: Some(token.token),
        epoch: Some(resolved.info.epoch),
    };
    if stream.write_all(line(&hello).as_bytes()).await.is_err() {
        return reply(&mut caller, DialReply::failed(DialError::Unreachable)).await;
    }
    let path_state = overlay.path_state(&resolved.key).await;
    if caller.write_all(line(&DialReply::connected(path_state)).as_bytes()).await.is_err() {
        return;
    }
    let _ = tokio::io::copy_bidirectional(&mut caller, &mut stream).await;
}

#[cfg(test)]
#[path = "cloud_tests.rs"]
mod tests;
