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

/// Direct Cloud API credentials for headless Linux links. This source is
/// enabled only when the caller explicitly supplies both an API origin and an
/// install token (the token is never included in debug output or errors).
#[derive(Clone)]
pub(super) struct DirectSource {
    api: String,
    token: String,
    token_file: Option<PathBuf>,
    client: reqwest::Client,
}

impl std::fmt::Debug for DirectSource {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("DirectSource").field("api", &self.api).finish_non_exhaustive()
    }
}

impl DirectSource {
    pub(super) fn new(api: String, token: String) -> Result<Self, ConnectInfoError> {
        Self::build(api, token, None)
    }

    pub(super) fn with_token_file(
        api: String,
        token: String,
        token_file: PathBuf,
    ) -> Result<Self, ConnectInfoError> {
        Self::build(api, token, Some(token_file))
    }

    fn build(
        api: String,
        token: String,
        token_file: Option<PathBuf>,
    ) -> Result<Self, ConnectInfoError> {
        let api = secure_origin(&api)?;
        if token.trim().is_empty() {
            return Err(ConnectInfoError::Unavailable("the Cloud install token is empty".into()));
        }
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(DIAL_TIMEOUT)
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|_| {
                ConnectInfoError::Unavailable("the Cloud HTTP client is unavailable".into())
            })?;
        Ok(Self { api, token: token.trim().to_owned(), token_file, client })
    }

    fn current_token(&self) -> Result<String, ConnectInfoError> {
        let Some(path) = &self.token_file else { return Ok(self.token.clone()) };
        super::read_cloud_token_file(path).map_err(|_| {
            ConnectInfoError::Unavailable("the Cloud install token file is unavailable".into())
        })
    }

    async fn request(
        &self,
        path: &str,
        body: serde_json::Value,
        read_envelope: bool,
    ) -> Result<serde_json::Value, ConnectInfoError> {
        let token = self.current_token()?;
        let response = self
            .client
            .post(format!("{}{}", self.api, path))
            .bearer_auth(token)
            .json(&body)
            .send()
            .await
            .map_err(|_| ConnectInfoError::Unavailable("the Cloud API did not answer".into()))?;
        let status = response.status();
        let value: serde_json::Value = response
            .json()
            .await
            .map_err(|_| ConnectInfoError::Unavailable("the Cloud API sent invalid JSON".into()))?;
        if read_envelope && status.is_success() && value.get("value").is_some() {
            return Ok(value.get("value").cloned().unwrap_or(serde_json::Value::Null));
        }
        if !read_envelope && value.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
            return Ok(value.get("value").cloned().unwrap_or(serde_json::Value::Null));
        }
        let error = value.get("error").or_else(|| status.is_client_error().then_some(&value));
        let field =
            |name: &str| error.and_then(|e| e.get(name)).and_then(serde_json::Value::as_str);
        Err(ConnectInfoError::from_code(
            field("code").unwrap_or("owner.unreachable"),
            field("message").unwrap_or("the Cloud API refused"),
        ))
    }
}

impl ConnectInfoSource for DirectSource {
    async fn fetch(&self, host: &str) -> Result<ConnectInfo, ConnectInfoError> {
        if !is_cloud_host(host) || !cmux_link::stamp::valid_id(host) {
            return Err(ConnectInfoError::NotFound);
        }
        let value = self
            .request(
                "/v1/read",
                serde_json::json!({
                    "op":"cloud.machine.connect_info", "params":{"host":host}
                }),
                true,
            )
            .await?;
        serde_json::from_value(value).map_err(|_| {
            ConnectInfoError::Unavailable("the Cloud API sent invalid connect_info".into())
        })
    }

    async fn mint_token(
        &self,
        host: &str,
        services: &[Service],
    ) -> Result<LinkTokenGrant, ConnectInfoError> {
        if !is_cloud_host(host) || !cmux_link::stamp::valid_id(host) {
            return Err(ConnectInfoError::NotFound);
        }
        let value = self
            .request(
                "/v1/ops",
                serde_json::json!({
                    "op":"cloud.machine.link_token", "params":{"host":host,"services":services}
                }),
                false,
            )
            .await?;
        serde_json::from_value(value).map_err(|_| {
            ConnectInfoError::Unavailable("the Cloud API sent invalid link_token".into())
        })
    }
}

fn secure_origin(raw: &str) -> Result<String, ConnectInfoError> {
    let url = reqwest::Url::parse(raw.trim())
        .map_err(|_| ConnectInfoError::Unavailable("the Cloud API URL is invalid".into()))?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "::1"));
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
        || (url.scheme() != "https" && !(url.scheme() == "http" && local))
    {
        return Err(ConnectInfoError::Unavailable(
            "the Cloud API URL must be a secure bare origin".into(),
        ));
    }
    Ok(url.origin().ascii_serialization())
}

#[cfg(test)]
mod direct_tests {
    use super::*;

    #[test]
    fn direct_source_redacts_install_token() {
        let source =
            DirectSource::new("http://127.0.0.1:8787".into(), "secret-install-token".into())
                .expect("local origins are allowed for tests");
        let debug = format!("{source:?}");
        assert!(!debug.contains("secret-install-token"));
        assert_eq!(source.api, "http://127.0.0.1:8787");
    }

    #[test]
    fn direct_source_rejects_insecure_remote_origin() {
        let error = DirectSource::new("http://cloud.example".into(), "token".into()).unwrap_err();
        assert!(
            matches!(error, ConnectInfoError::Unavailable(message) if message.contains("secure"))
        );
    }

    #[cfg(unix)]
    #[test]
    fn direct_source_reloads_a_rotated_token_file() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().expect("temporary token directory");
        let path = directory.path().join("install-token");
        std::fs::write(&path, "first-token\n").expect("write first token");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .expect("protect token file");
        let source = DirectSource::with_token_file(
            "http://127.0.0.1:8787".into(),
            "first-token".into(),
            path.clone(),
        )
        .expect("local origins are allowed for tests");
        assert_eq!(source.current_token().expect("first token"), "first-token");
        std::fs::write(&path, "rotated-token\n").expect("rotate token");
        assert_eq!(source.current_token().expect("rotated token"), "rotated-token");
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

/// Cloud authority may come from the app-owned relay for the legacy link or
/// from the explicitly inherited broker used by the Native link. The Native
/// child never opens a path or receives an install credential itself.
pub(super) enum CloudSource {
    Relay(RelaySource),
    Broker(super::cloud_broker::BrokerSource),
    Direct(DirectSource),
}

impl ConnectInfoSource for CloudSource {
    async fn fetch(&self, host: &str) -> Result<ConnectInfo, ConnectInfoError> {
        match self {
            Self::Relay(source) => source.fetch(host).await,
            Self::Broker(source) => source.fetch(host).await,
            Self::Direct(source) => source.fetch(host).await,
        }
    }

    async fn mint_token(
        &self,
        host: &str,
        services: &[Service],
    ) -> Result<LinkTokenGrant, ConnectInfoError> {
        match self {
            Self::Relay(source) => source.mint_token(host, services).await,
            Self::Broker(source) => source.mint_token(host, services).await,
            Self::Direct(source) => source.mint_token(host, services).await,
        }
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

/// A refused Cloud dial: the typed code, and what failed in `error_detail`
/// and on this link's stderr (the app keeps it in the link's `link.log`).
/// Both get the same clipped, one-line detail (`failed_because`), never the
/// raw text.
async fn refuse<C: AsyncWrite + Unpin>(
    caller: &mut C,
    host: &str,
    service: Service,
    error: DialError,
    detail: &str,
) {
    let refused = DialReply::failed_because(error, detail);
    eprintln!(
        "cmux link: dial {host} {service:?} refused ({error:?}): {}",
        refused.error_detail.as_deref().unwrap_or("")
    );
    reply(caller, refused).await;
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
    let service = request.service;
    let mut refresh = false;
    let (resolved, mut stream) = loop {
        let resolved = match resolver.resolve(host, refresh).await {
            Ok(resolved) => resolved,
            Err(error) => {
                let detail = format!("connect_info: {}", error.detail());
                return refuse(&mut caller, host, service, error.dial_error(), &detail).await;
            }
        };
        if !resolved.info.allows(service) {
            let detail = format!("the machine's connect_info does not allow {service:?}");
            return refuse(&mut caller, host, service, DialError::NotAuthorized, &detail).await;
        }
        let remote = SocketAddr::new(IpAddr::V6(resolved.info.peer.overlay_address), LINK_PORT);
        // Peer setup is not cut by the connect deadline, so a half-applied
        // change cannot be left behind (it bounds its own tunnel start).
        let failed = match overlay.set_cloud_peer(host, resolved.key, &resolved.info).await {
            Err(error) => format!("the tunnel peer setup failed: {error}"),
            Ok(_) => match tokio::time::timeout(DIAL_TIMEOUT, overlay.connect(remote)).await {
                Ok(Ok(stream)) => break (resolved, stream),
                Ok(Err(error)) => format!("connect to {remote}: {error}"),
                Err(_) => format!("no handshake with {remote} within {} s", DIAL_TIMEOUT.as_secs()),
            },
        };
        // Rule 3: a handshake failure fetches once more before it reports.
        if refresh {
            let error = if resolved.info.is_paused() {
                DialError::HostPaused
            } else {
                DialError::Unreachable
            };
            let detail =
                format!("{failed} (after a fresh connect_info, state {})", resolved.info.state);
            return refuse(&mut caller, host, service, error, &detail).await;
        }
        refresh = true;
    };
    // One fresh token per attempt, used once, never kept.
    let grant = match resolver.token(host, service).await {
        Ok(grant) => grant,
        Err(error) => {
            let detail = format!("link_token: {}", error.detail());
            return refuse(&mut caller, host, service, error.dial_error(), &detail).await;
        }
    };
    let hello = ServiceHello {
        service: request.service,
        link_token: Some(grant.token),
        epoch: Some(grant.epoch),
    };
    if let Err(error) = stream.write_all(line(&hello).as_bytes()).await {
        let detail = format!("the service hello to the machine failed: {error}");
        return refuse(&mut caller, host, service, DialError::Unreachable, &detail).await;
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
