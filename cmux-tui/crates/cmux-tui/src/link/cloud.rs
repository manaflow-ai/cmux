//! `link.dial` to a Cloud host id (cloud-client-contract.md 1.7, decisions
//! LINK-RESOLVE and LINK-TOKEN-OP): the link resolves
//! `cloud.machine.connect_info` itself (cached), configures the VM endpoint
//! as a mesh peer, opens its link port, then mints a fresh
//! `cloud.machine.link_token` for that attempt's one hello.

use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Instant;

use cmux_link::LINK_PORT;
use cmux_link::connect_info::{
    ConnectInfo, ConnectInfoCache, ConnectInfoError, LinkTokenGrant, is_cloud_host,
};
use cmux_link::dial::{
    CloudEvent, CloudEventRequest, DialError, DialReply, DialRequest, Service, ServiceHello, line,
};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};

use super::dial::{DIAL_TIMEOUT, Overlay, reply};
use super::locked;

/// Where connect_info and link tokens come from: the host credential relay
/// in the product, a fake in tests.
pub(super) trait ConnectInfoSource: Send + Sync + 'static {
    /// `cloud.machine.connect_info {host}` (a read; no token in it).
    fn fetch(
        &self,
        host: &str,
    ) -> impl Future<Output = Result<ConnectInfo, ConnectInfoError>> + Send;
    /// `cloud.machine.link_token {host, services}`: every call mints a fresh
    /// token for one hello.
    fn mint_token(
        &self,
        host: &str,
        services: &[Service],
    ) -> impl Future<Output = Result<LinkTokenGrant, ConnectInfoError>> + Send;
}

/// The dedicated link credential relay. The socket is owned by the signed-in
/// Mac app and admits only the link process it launched; the install token
/// never crosses this boundary. A missing socket remains an unavailable
/// source, so a signed-out or old build fails closed.
#[derive(Clone, Debug, Default)]
pub(super) struct RelaySource(Option<PathBuf>);

impl RelaySource {
    pub(super) fn unavailable() -> Self {
        Self(None)
    }
    pub(super) fn socket(path: PathBuf) -> Self {
        Self(Some(path))
    }
    async fn request(
        &self,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, ConnectInfoError> {
        let Some(path) = &self.0 else { return Err(relay_unavailable()) };
        let mut stream = tokio::time::timeout(DIAL_TIMEOUT, tokio::net::UnixStream::connect(path))
            .await
            .map_err(|_| relay_unavailable())?
            .map_err(|_| relay_unavailable())?;
        let mut line = serde_json::to_vec(&body).map_err(|_| relay_unavailable())?;
        line.push(b'\n');
        tokio::time::timeout(DIAL_TIMEOUT, stream.write_all(&line))
            .await
            .map_err(|_| relay_unavailable())?
            .map_err(|_| relay_unavailable())?;
        let mut answer = String::new();
        let bytes = tokio::time::timeout(
            DIAL_TIMEOUT,
            BufReader::new(stream).take(64 * 1024).read_line(&mut answer),
        )
        .await
        .map_err(|_| relay_unavailable())?
        .map_err(|_| relay_unavailable())?;
        if bytes == 0 || !answer.ends_with('\n') || answer.len() > 64 * 1024 {
            return Err(ConnectInfoError::Unavailable(
                "the link credential relay sent a truncated response".into(),
            ));
        }
        let value: serde_json::Value = serde_json::from_str(answer.trim()).map_err(|_| {
            ConnectInfoError::Unavailable("the link credential relay sent invalid JSON".into())
        })?;
        if value.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
            return Ok(value.get("value").cloned().unwrap_or(serde_json::Value::Null));
        }
        let error = value.get("error");
        let field =
            |name: &str| error.and_then(|e| e.get(name)).and_then(serde_json::Value::as_str);
        let code = field("code").unwrap_or("owner.unreachable");
        let message = field("message").unwrap_or("the link credential relay refused");
        Err(ConnectInfoError::from_code(code, message))
    }
}

impl ConnectInfoSource for RelaySource {
    async fn fetch(&self, host: &str) -> Result<ConnectInfo, ConnectInfoError> {
        let value = self.request(serde_json::json!({"op":"connect_info","host":host})).await?;
        serde_json::from_value(value).map_err(|_| {
            ConnectInfoError::Unavailable(
                "the link credential relay sent an invalid connect_info".into(),
            )
        })
    }

    async fn mint_token(
        &self,
        host: &str,
        services: &[Service],
    ) -> Result<LinkTokenGrant, ConnectInfoError> {
        let value = self
            .request(serde_json::json!({"op":"link_token","host":host,"services":services}))
            .await?;
        serde_json::from_value(value).map_err(|_| {
            ConnectInfoError::Unavailable(
                "the link credential relay sent an invalid link_token".into(),
            )
        })
    }
}

fn relay_unavailable() -> ConnectInfoError {
    ConnectInfoError::Unavailable("the cmux credential relay is not available yet".into())
}

/// connect_info with the contract's cache rules.
pub(super) struct CloudResolver<S> {
    source: S,
    cache: Mutex<ConnectInfoCache>,
}

/// One checked record and the WireGuard key it names.
pub(super) struct Resolved {
    pub info: ConnectInfo,
    pub key: [u8; 32],
}

impl<S: ConnectInfoSource> CloudResolver<S> {
    pub(super) fn new(source: S) -> Self {
        Self { source, cache: Mutex::new(ConnectInfoCache::default()) }
    }

    /// The record of `host`: the cached one while it is fresh, else a new
    /// fetch. `refresh` always fetches (rule 3, after a failed handshake).
    pub(super) async fn resolve(
        &self,
        host: &str,
        refresh: bool,
    ) -> Result<Resolved, ConnectInfoError> {
        let cached =
            (!refresh).then(|| locked(&self.cache).get(host, Instant::now()).cloned()).flatten();
        let info = match cached {
            Some(info) => info,
            None => {
                let fetched = within(self.source.fetch(host)).await?;
                // Only a real fetch refreshes the entry (the 300 s limit).
                locked(&self.cache).insert(fetched, Instant::now())
            }
        };
        let key = info.validate(host).map_err(ConnectInfoError::Invalid)?;
        Ok(Resolved { info, key })
    }

    /// A fresh token for one hello to `host` for `service`.
    pub(super) async fn token(
        &self,
        host: &str,
        service: Service,
    ) -> Result<LinkTokenGrant, ConnectInfoError> {
        let grant = within(self.source.mint_token(host, &[service])).await?;
        if !grant.covers(host, service) {
            return Err(ConnectInfoError::Forbidden);
        }
        Ok(grant)
    }

    /// `cloud.machine.removed`: drop the record at once.
    pub(super) fn forget(&self, host: &str) -> bool {
        locked(&self.cache).remove(host)
    }

    /// `cloud.machine.upsert` with `revision`: drop an older record.
    pub(super) fn observe_revision(&self, host: &str, revision: u64) -> bool {
        locked(&self.cache).observe_revision(host, revision)
    }
}

/// A relay call that does not answer within the dial deadline is
/// `Unavailable`, so a hung relay never hangs the caller.
async fn within<T>(
    call: impl Future<Output = Result<T, ConnectInfoError>>,
) -> Result<T, ConnectInfoError> {
    tokio::time::timeout(DIAL_TIMEOUT, call)
        .await
        .unwrap_or_else(|_| Err(ConnectInfoError::Unavailable("the relay did not answer".into())))
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

/// Serve one `link.dial` for a Cloud host id: the record (cached), the
/// handshake, then a freshly minted token for this attempt's one hello.
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
    let mut refresh = false;
    let (resolved, mut stream) = loop {
        let resolved = match resolver.resolve(host, refresh).await {
            Ok(resolved) => resolved,
            Err(error) => return reply(&mut caller, DialReply::failed(error.dial_error())).await,
        };
        if !resolved.info.allows(request.service) {
            return reply(&mut caller, DialReply::failed(DialError::NotAuthorized)).await;
        }
        let remote = SocketAddr::new(IpAddr::V6(resolved.info.peer.overlay_address), LINK_PORT);
        // Peer setup is not cut by the connect deadline, so a half-applied
        // change cannot be left behind (it bounds its own tunnel start).
        let configured = overlay.set_cloud_peer(host, resolved.key, &resolved.info).await;
        if configured.is_ok()
            && let Ok(Ok(stream)) =
                tokio::time::timeout(DIAL_TIMEOUT, overlay.connect(remote)).await
        {
            break (resolved, stream);
        }
        // Rule 3: a handshake failure fetches once more before it reports.
        if refresh {
            let error = if resolved.info.is_paused() {
                DialError::HostPaused
            } else {
                DialError::Unreachable
            };
            return reply(&mut caller, DialReply::failed(error)).await;
        }
        refresh = true;
    };
    // One fresh token per attempt, used once, never kept.
    let grant = match resolver.token(host, request.service).await {
        Ok(grant) => grant,
        Err(error) => return reply(&mut caller, DialReply::failed(error.dial_error())).await,
    };
    let hello = ServiceHello {
        service: request.service,
        link_token: Some(grant.token),
        epoch: Some(grant.epoch),
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
