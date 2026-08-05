use std::collections::HashSet;
use std::path::Path;
use std::str::FromStr as _;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use cmux_remote::provider::{
    IrohPathMode, IrohProviderConfig, bind_iroh_endpoint, connect_iroh_endpoint,
};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayConfig, RelayMap, RelayMode, RelayUrl, TransportAddr,
    Watcher as _,
};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncWriteExt as _};
use tokio::sync::{Mutex, RwLock};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::CMUX_TUI_ALPN;
use crate::broker::{
    Binding, BrokerClient, DiscoverySnapshot, GrantVerificationKeySet, Platform,
    RelayAccessResponse, same_relay_fleet, unix_time,
};
use crate::identity::{BrokerCredential, IdentityStore};
use crate::policy::{RelayEnvironment, RelayPolicyVerifier, VerifiedRelayPolicy};

pub const ADMISSION_FRAME_BYTES: usize = 16 * 1024;
pub const ADMISSION_TIMEOUT: Duration = Duration::from_secs(5);
const ENDPOINT_ONLINE_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_TRANSPORT_FRAME_BYTES: usize = 64 * 1024 * 1024;
const RELAY_REFRESH_RETRY_MAX: Duration = Duration::from_secs(30);
pub const DISCOVERY_MAX_AGE: Duration = Duration::from_secs(30);

#[derive(Debug, Clone)]
struct RelayGeneration {
    runtime_generation: u64,
    policy: VerifiedRelayPolicy,
    refresh_after: i64,
    expires_at: i64,
}

pub struct DiscoveryLease {
    pub snapshot: DiscoverySnapshot,
    pub relay_urls: Vec<String>,
    pub fetched_at: Instant,
}

pub struct EndpointRuntime {
    pub identity: Arc<IdentityStore>,
    pub broker: BrokerClient,
    pub credential: Arc<BrokerCredential>,
    pub binding: Binding,
    pub endpoint: Endpoint,
    verifier: RelayPolicyVerifier,
    relay: RwLock<RelayGeneration>,
    grant_keys: RwLock<GrantVerificationKeySet>,
    discovery_guard: Mutex<()>,
}

impl std::fmt::Debug for EndpointRuntime {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EndpointRuntime")
            .field("endpoint", &self.endpoint.id().fmt_short().to_string())
            .field("binding_id", &self.binding.binding_id)
            .field("platform", &self.binding.platform)
            .finish_non_exhaustive()
    }
}

impl EndpointRuntime {
    pub async fn start(config: EndpointRuntimeConfig<'_>) -> Result<Self> {
        let identity = Arc::new(IdentityStore::open(config.state_root, config.identity_name)?);
        let credential = Arc::new(identity.load_credential()?);
        let broker = BrokerClient::new(config.broker_url.clone())?;
        let verifier = RelayPolicyVerifier::new(config.relay_environment, identity.directory())?;
        let endpoint_id = identity.endpoint_id().to_string();

        let bootstrap = broker.relay_access(&credential, &endpoint_id).await?;
        ensure!(bootstrap.endpoint_id == endpoint_id, "relay bootstrap changed EndpointID");
        let now = unix_time()? as i64;
        let bootstrap_policy = verifier.verify(&bootstrap.policy, now)?;
        ensure!(
            !bootstrap_policy.relays.is_empty(),
            "broker returned an empty verified relay policy"
        );

        let binding = broker
            .register_endpoint(
                &credential,
                identity.secret_key(),
                identity.metadata(),
                config.platform,
                config.display_name,
                config.pairing_enabled,
            )
            .await?;
        let access = broker.relay_access(&credential, &endpoint_id).await?;
        ensure!(access.endpoint_id == endpoint_id, "relay credential changed EndpointID");
        let now = unix_time()? as i64;
        let policy = verifier.verify(&access.policy, now)?;
        ensure!(
            policy.sequence >= bootstrap_policy.sequence,
            "bound relay policy rolled back bootstrap policy"
        );
        let validated = validate_relay_access(&policy, &access, now)?;
        let endpoint_config = IrohProviderConfig {
            secret_key: Some(identity.secret_key().clone()),
            relay_mode: validated.relay_mode(),
            path_mode: IrohPathMode::RelayOnly,
            discovery_n0: false,
            alpn: CMUX_TUI_ALPN.to_vec(),
            maximum_frame_bytes: MAX_TRANSPORT_FRAME_BYTES,
        };
        let endpoint = bind_iroh_endpoint(&endpoint_config)
            .await
            .map_err(|error| anyhow::anyhow!(error.to_string()))?;
        tokio::time::timeout(ENDPOINT_ONLINE_TIMEOUT, endpoint.online())
            .await
            .context("iroh endpoint did not reach a verified relay")?;

        let snapshot = broker.discover(&credential).await?;
        validate_discovery(&snapshot, &binding, &policy.relay_urls())?;
        verifier.record(&policy)?;

        let grant_keys = snapshot.grant_verification_keys;
        Ok(Self {
            identity,
            broker,
            credential,
            binding,
            endpoint,
            verifier,
            relay: RwLock::new(RelayGeneration {
                runtime_generation: 1,
                policy,
                refresh_after: validated.refresh_after,
                expires_at: validated.expires_at,
            }),
            grant_keys: RwLock::new(grant_keys),
            discovery_guard: Mutex::new(()),
        })
    }

    pub fn endpoint_id(&self) -> EndpointId {
        self.endpoint.id()
    }

    pub async fn relay_urls(&self) -> Vec<String> {
        self.relay.read().await.policy.relay_urls()
    }

    pub async fn relay_count(&self) -> usize {
        self.relay.read().await.policy.relays.len()
    }

    pub async fn relay_sequence(&self) -> u64 {
        self.relay.read().await.policy.sequence
    }

    pub async fn fresh_discovery(&self) -> Result<DiscoverySnapshot> {
        self.fresh_discovery_with_fleet().await.map(|lease| lease.snapshot)
    }

    pub async fn fresh_discovery_with_fleet(&self) -> Result<DiscoveryLease> {
        let generation = self.active_relay_generation().await?;
        let relay_urls = generation.policy.relay_urls();
        let _discovery_guard = self.discovery_guard.lock().await;
        let snapshot = self.broker.discover(&self.credential).await?;
        validate_discovery(&snapshot, &self.binding, &relay_urls)?;
        let fetched_at = Instant::now();
        *self.grant_keys.write().await = snapshot.grant_verification_keys.clone();
        Ok(DiscoveryLease { snapshot, relay_urls, fetched_at })
    }

    pub async fn grant_verification_keys(&self) -> GrantVerificationKeySet {
        self.grant_keys.read().await.clone()
    }

    pub async fn dial(&self, remote_endpoint: &str) -> Result<iroh::endpoint::Connection> {
        let generation = self.active_relay_generation().await?;
        let endpoint_id =
            EndpointId::from_str(remote_endpoint).context("remote EndpointID is invalid")?;
        let addresses = generation
            .policy
            .relays
            .iter()
            .map(|relay| {
                relay
                    .url
                    .parse::<RelayUrl>()
                    .map(TransportAddr::Relay)
                    .context("verified relay URL is not accepted by iroh")
            })
            .collect::<Result<Vec<_>>>()?;
        let address = EndpointAddr::from_parts(endpoint_id, addresses);
        connect_iroh_endpoint(&self.endpoint, &address, CMUX_TUI_ALPN)
            .await
            .map_err(|error| anyhow::anyhow!(error.to_string()))
    }

    pub async fn refresh_until_cancelled(&self, shutdown: CancellationToken) -> Result<()> {
        loop {
            let current = self.active_relay_generation().await?;
            let now = unix_time()? as i64;
            let wait = duration_until(current.refresh_after, now);
            tokio::select! {
                _ = shutdown.cancelled() => return Ok(()),
                _ = tokio::time::sleep(wait) => {}
            }

            let mut retry = Duration::from_secs(1);
            loop {
                match self.refresh_once().await {
                    Ok(generation) => {
                        eprintln!(
                            "cmux-tui-iroh: relay credentials refreshed sequence={} generation={}",
                            generation.policy.sequence, generation.runtime_generation,
                        );
                        break;
                    }
                    Err(_) => {
                        let current = self.relay.read().await.clone();
                        let now = unix_time()? as i64;
                        ensure!(
                            now < current.expires_at,
                            "relay refresh failed before the installed credential expired"
                        );
                        let wait = retry.min(duration_until(current.expires_at, now));
                        eprintln!("cmux-tui-iroh: relay refresh failed; retrying");
                        tokio::select! {
                            _ = shutdown.cancelled() => return Ok(()),
                            _ = tokio::time::sleep(wait) => {}
                        }
                        retry = retry.saturating_mul(2).min(RELAY_REFRESH_RETRY_MAX);
                    }
                }
            }
        }
    }

    async fn refresh_once(&self) -> Result<RelayGeneration> {
        let endpoint_id = self.endpoint_id().to_string();
        let access = self.broker.relay_access(&self.credential, &endpoint_id).await?;
        ensure!(access.endpoint_id == endpoint_id, "relay refresh changed EndpointID");
        let now = unix_time()? as i64;
        let policy = self.verifier.verify(&access.policy, now)?;
        let validated = validate_relay_access(&policy, &access, now)?;
        let current = self.relay.read().await.clone();
        ensure!(
            policy.sequence >= current.policy.sequence,
            "relay refresh rolled back the live policy"
        );

        let _discovery_guard = self.discovery_guard.lock().await;
        let snapshot = self.broker.discover(&self.credential).await?;
        validate_discovery(&snapshot, &self.binding, &policy.relay_urls())?;
        ensure!(!self.endpoint.is_closed(), "iroh endpoint closed during relay refresh");

        let mut replaced = Vec::with_capacity(validated.configs.len());
        for (url, config) in &validated.configs {
            let previous = self.endpoint.insert_relay(url.clone(), Arc::clone(config)).await;
            replaced.push((url.clone(), previous));
        }
        let install_result = async {
            wait_for_verified_relay(&self.endpoint, &validated.urls()).await?;
            self.verifier.record(&policy)?;
            Result::<(), anyhow::Error>::Ok(())
        }
        .await;
        if let Err(error) = install_result {
            rollback_relays(&self.endpoint, replaced).await;
            return Err(error);
        }

        let next = RelayGeneration {
            runtime_generation: current.runtime_generation.saturating_add(1),
            policy,
            refresh_after: validated.refresh_after,
            expires_at: validated.expires_at,
        };
        *self.relay.write().await = next.clone();
        *self.grant_keys.write().await = snapshot.grant_verification_keys.clone();
        let next_urls =
            next.policy.relays.iter().map(|relay| relay.url.as_str()).collect::<HashSet<_>>();
        for relay in &current.policy.relays {
            if !next_urls.contains(relay.url.as_str()) {
                let url =
                    relay.url.parse::<RelayUrl>().context("installed relay URL is invalid")?;
                self.endpoint.remove_relay(&url).await;
            }
        }
        ensure!(!self.endpoint.is_closed(), "iroh endpoint closed during relay refresh");
        Ok(next)
    }

    async fn active_relay_generation(&self) -> Result<RelayGeneration> {
        let generation = self.relay.read().await.clone();
        let now = unix_time()? as i64;
        ensure!(now < generation.expires_at, "installed relay authorization expired");
        Ok(generation)
    }

    pub async fn close(&self) {
        self.endpoint.close().await;
    }
}

pub struct EndpointRuntimeConfig<'a> {
    pub state_root: &'a Path,
    pub identity_name: &'a str,
    pub broker_url: url::Url,
    pub relay_environment: RelayEnvironment,
    pub platform: Platform,
    pub display_name: Option<&'a str>,
    pub pairing_enabled: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdmissionRequest {
    pub version: u32,
    pub grant: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdmissionResponse {
    pub accepted: bool,
}

pub async fn send_admission<R>(
    sender: &mut iroh::endpoint::SendStream,
    receiver: &mut R,
    grant: &str,
) -> Result<()>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    ensure!(grant.len() <= ADMISSION_FRAME_BYTES / 2, "pair grant is too large");
    write_json_line(sender, &AdmissionRequest { version: 1, grant: grant.to_string() }).await?;
    let response: AdmissionResponse =
        tokio::time::timeout(ADMISSION_TIMEOUT, read_json_line(receiver, ADMISSION_FRAME_BYTES))
            .await
            .context("server admission acknowledgement timed out")??;
    ensure!(response.accepted, "server rejected transport admission");
    Ok(())
}

pub async fn receive_admission<R>(receiver: &mut R) -> Result<AdmissionRequest>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    let request: AdmissionRequest =
        tokio::time::timeout(ADMISSION_TIMEOUT, read_json_line(receiver, ADMISSION_FRAME_BYTES))
            .await
            .context("transport admission frame timed out")??;
    ensure!(request.version == 1, "unsupported transport admission version");
    ensure!(!request.grant.is_empty(), "transport admission grant is empty");
    Ok(request)
}

pub async fn acknowledge_admission(sender: &mut iroh::endpoint::SendStream) -> Result<()> {
    write_json_line(sender, &AdmissionResponse { accepted: true }).await
}

pub async fn bridge_unix_and_iroh<LR, LW, RR>(
    mut local_reader: LR,
    mut local_writer: LW,
    mut sender: iroh::endpoint::SendStream,
    mut receiver: RR,
    cancel: CancellationToken,
) -> Result<()>
where
    LR: tokio::io::AsyncRead + Unpin,
    LW: tokio::io::AsyncWrite + Unpin,
    RR: tokio::io::AsyncRead + Unpin,
{
    let upstream = async {
        tokio::io::copy(&mut local_reader, &mut sender).await?;
        sender.finish()?;
        Result::<(), anyhow::Error>::Ok(())
    };
    let downstream = async {
        tokio::io::copy(&mut receiver, &mut local_writer).await?;
        local_writer.shutdown().await?;
        Result::<(), anyhow::Error>::Ok(())
    };
    tokio::select! {
        result = async { tokio::try_join!(upstream, downstream).map(|_| ()) } => result,
        _ = cancel.cancelled() => Ok(()),
    }
}

/// Typed end-of-stream signal for framed JSON reads, so callers can
/// distinguish a peer that closed the stream from a malformed frame
/// without matching on error-message text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamClosed;

impl std::fmt::Display for StreamClosed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("stream closed before JSON line")
    }
}

impl std::error::Error for StreamClosed {}

pub fn is_stream_closed(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| cause.downcast_ref::<StreamClosed>().is_some())
}

/// Callers must keep one buffered reader alive for the connection's whole
/// lifetime: bytes after the newline stay in the reader's buffer.
pub async fn read_json_line<R, T>(reader: &mut R, maximum_bytes: usize) -> Result<T>
where
    R: tokio::io::AsyncBufRead + Unpin,
    T: serde::de::DeserializeOwned,
{
    let mut bytes = Vec::new();
    let mut limited = reader.take(maximum_bytes as u64);
    let count = limited.read_until(b'\n', &mut bytes).await?;
    if count == 0 {
        return Err(anyhow::Error::new(StreamClosed));
    }
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    } else if count == maximum_bytes {
        anyhow::bail!("JSON line is too large");
    } else {
        return Err(anyhow::Error::new(StreamClosed));
    }
    ensure!(!bytes.is_empty(), "JSON line is empty");
    serde_json::from_slice(&bytes).context("JSON line is invalid")
}

pub async fn write_json_line<W, T>(writer: &mut W, value: &T) -> Result<()>
where
    W: tokio::io::AsyncWrite + Unpin,
    T: Serialize,
{
    write_bounded_json_line(writer, value, ADMISSION_FRAME_BYTES).await
}

pub async fn write_bounded_json_line<W, T>(
    writer: &mut W,
    value: &T,
    maximum_bytes: usize,
) -> Result<()>
where
    W: tokio::io::AsyncWrite + Unpin,
    T: Serialize,
{
    let mut bytes = serde_json::to_vec(value).context("cannot encode JSON line")?;
    ensure!(bytes.len() < maximum_bytes, "JSON line is too large");
    bytes.push(b'\n');
    writer.write_all(&bytes).await?;
    writer.flush().await?;
    Ok(())
}

struct ValidatedRelayAccess {
    configs: Vec<(RelayUrl, Arc<RelayConfig>)>,
    refresh_after: i64,
    expires_at: i64,
}

impl ValidatedRelayAccess {
    fn relay_mode(&self) -> RelayMode {
        RelayMode::Custom(RelayMap::from_iter(
            self.configs.iter().map(|(_, config)| Arc::clone(config)),
        ))
    }

    fn urls(&self) -> HashSet<RelayUrl> {
        self.configs.iter().map(|(url, _)| url.clone()).collect()
    }
}

fn validate_relay_access(
    policy: &VerifiedRelayPolicy,
    response: &RelayAccessResponse,
    now: i64,
) -> Result<ValidatedRelayAccess> {
    ensure!(
        response.relay_credentials.len() == policy.relays.len(),
        "relay credential set does not cover the signed policy"
    );
    let expected = policy.relays.iter().map(|relay| relay.url.as_str()).collect::<HashSet<_>>();
    let mut observed = HashSet::new();
    let mut configs = Vec::with_capacity(response.relay_credentials.len());
    let mut refresh_after = i64::MAX;
    let mut expires_at = i64::MAX;
    for credential in &response.relay_credentials {
        ensure!(
            expected.contains(credential.relay_url.as_str()),
            "credential covers an unknown relay"
        );
        ensure!(observed.insert(credential.relay_url.as_str()), "duplicate relay credential");
        ensure!(
            !credential.token.is_empty()
                && credential.token.len() <= 8 * 1024
                && !credential.token.bytes().any(|byte| byte.is_ascii_control()),
            "relay credential token is invalid"
        );
        ensure!(
            (30..=24 * 60 * 60).contains(&credential.ttl_seconds),
            "relay credential TTL is invalid"
        );
        ensure!(credential.refresh_after > now, "relay credential refresh time is stale");
        ensure!(
            credential.expires_at > credential.refresh_after,
            "relay credential expiry is invalid"
        );
        ensure!(
            credential.refresh_after >= credential.expires_at - credential.ttl_seconds,
            "relay credential lifetime is inconsistent"
        );
        ensure!(
            credential.expires_at <= now + credential.ttl_seconds + 30,
            "relay credential expiry exceeds its TTL"
        );
        let url =
            credential.relay_url.parse::<RelayUrl>().context("verified relay URL is invalid")?;
        let config =
            Arc::new(RelayConfig::from(url.clone()).with_auth_token(credential.token.clone()));
        configs.push((url, config));
        refresh_after = refresh_after.min(credential.refresh_after);
        expires_at = expires_at.min(credential.expires_at);
    }
    ensure!(observed.len() == expected.len(), "relay credential fleet is incomplete");
    expires_at = expires_at.min(policy.expires_at);
    ensure!(expires_at > now, "relay authorization is already expired");
    refresh_after = refresh_after.min(policy.expires_at.saturating_sub(30));
    ensure!(refresh_after > now, "relay authorization refresh window is too short");
    Ok(ValidatedRelayAccess { configs, refresh_after, expires_at })
}

fn validate_discovery(
    snapshot: &DiscoverySnapshot,
    binding: &Binding,
    relay_urls: &[String],
) -> Result<()> {
    ensure!(
        same_relay_fleet(&snapshot.relay_fleet, relay_urls),
        "broker discovery fleet differs from installed signed policy"
    );
    let local = snapshot
        .bindings
        .iter()
        .filter(|candidate| candidate.binding_id == binding.binding_id)
        .collect::<Vec<_>>();
    ensure!(local.len() == 1, "local binding is missing or ambiguous");
    ensure!(local[0].same_identity(binding), "local binding changed after registration");
    Ok(())
}

async fn wait_for_verified_relay(endpoint: &Endpoint, expected: &HashSet<RelayUrl>) -> Result<()> {
    let wait = async {
        let mut status = endpoint.home_relay_status();
        let mut current = status.get();
        loop {
            if current.iter().any(|relay| relay.is_connected() && expected.contains(relay.url())) {
                return Ok::<(), anyhow::Error>(());
            }
            current = status.updated().await.context("relay status watcher closed")?;
        }
    };
    tokio::time::timeout(ENDPOINT_ONLINE_TIMEOUT, wait)
        .await
        .context("refreshed relay fleet did not become reachable")??;
    Ok(())
}

async fn rollback_relays(endpoint: &Endpoint, replaced: Vec<(RelayUrl, Option<Arc<RelayConfig>>)>) {
    for (url, previous) in replaced.into_iter().rev() {
        match previous {
            Some(previous) => {
                endpoint.insert_relay(url, previous).await;
            }
            None => {
                endpoint.remove_relay(&url).await;
            }
        }
    }
}

fn duration_until(timestamp: i64, now: i64) -> Duration {
    Duration::from_secs(u64::try_from(timestamp.saturating_sub(now)).unwrap_or(0))
}

#[cfg(test)]
mod tests {
    use serde_json::json;
    use tokio::io::duplex;
    use uuid::Uuid;

    use super::*;

    #[tokio::test]
    async fn bounded_json_line_preserves_following_protocol_bytes() {
        let (mut writer, reader) = duplex(1024);
        tokio::spawn(async move {
            writer.write_all(b"{\"accepted\":true}\n{\"id\":1}\n").await.unwrap();
        });
        let mut reader = tokio::io::BufReader::new(reader);
        let response: AdmissionResponse = read_json_line(&mut reader, 128).await.unwrap();
        assert!(response.accepted);
        let mut rest = [0; 9];
        reader.read_exact(&mut rest).await.unwrap();
        assert_eq!(&rest, b"{\"id\":1}\n");
    }

    #[tokio::test]
    async fn bounded_json_line_rejects_oversize() {
        let (mut writer, reader) = duplex(1024);
        tokio::spawn(async move {
            writer.write_all(b"123456789\n").await.unwrap();
        });
        let mut reader = tokio::io::BufReader::new(reader);
        let error = read_json_line::<_, serde_json::Value>(&mut reader, 8).await.unwrap_err();
        assert!(!is_stream_closed(&error));
        assert!(error.to_string().contains("too large"));
    }

    #[tokio::test]
    async fn closed_stream_is_a_typed_signal() {
        let (writer, reader) = duplex(1024);
        drop(writer);
        let mut reader = tokio::io::BufReader::new(reader);
        let error = read_json_line::<_, serde_json::Value>(&mut reader, 128).await.unwrap_err();
        assert!(is_stream_closed(&error));
    }

    #[test]
    fn relay_credentials_cover_the_verified_fleet_exactly() {
        let policy = VerifiedRelayPolicy {
            jti: Uuid::new_v4(),
            sequence: 1,
            issued_at: 1_000,
            not_before: 1_000,
            expires_at: 1_300,
            relays: vec![crate::policy::VerifiedRelay {
                id: "test".into(),
                provider: "cmux".into(),
                region: "local".into(),
                url: "https://relay.example.com/".into(),
            }],
            compact: "signed-policy".into(),
        };
        let credential = crate::broker::RelayCredential {
            relay_url: "https://relay.example.com/".into(),
            token: "relay-token".into(),
            expires_at: 1_300,
            refresh_after: 1_240,
            ttl_seconds: 300,
        };
        let response = RelayAccessResponse {
            endpoint_id: "aa".repeat(32),
            relay_credentials: vec![credential.clone()],
            policy: "signed-policy".into(),
            preference: json!({}),
            preference_revision: 1,
        };
        assert!(validate_relay_access(&policy, &response, 1_000).is_ok());

        let mut extra = response.clone();
        extra.relay_credentials.push(credential);
        assert!(validate_relay_access(&policy, &extra, 1_000).is_err());

        let mut impossible_ttl = response;
        impossible_ttl.relay_credentials[0].expires_at = 2_000;
        assert!(validate_relay_access(&policy, &impossible_ttl, 1_000).is_err());
    }
}
