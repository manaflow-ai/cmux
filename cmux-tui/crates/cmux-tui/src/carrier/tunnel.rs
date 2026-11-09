//! The device tunnel into the team's provider Cloud mesh (S6 G3): what lets
//! the ssh backup carrier reach `<VM mesh ip>:22` with
//! `ssh -o ProxyCommand='cmux wg dial --hub S %h %p'`.
//!
//! One supervisor per Mac (an flock on `<socket>.tunnel-lock`, 0600; a second one gets
//! [`StartError::Held`] and uses the first one's socket):
//!
//! 1. **Attach.** `POST /v1/mesh/nodes/{machineId}/attach` with the person's
//!    credential answers the team's provider mesh in `mesh_id` (null, or 404
//!    `mesh.device.unavailable`: no mesh, [`TunnelStatus::Unavailable`], no
//!    retry). The device then signs a `cmux-mesh-v1` enrollment (purpose
//!    `enroll`, target that mesh) with its install key and attaches again
//!    with `{enrollment}`; the answer is its tunnel (`device_id`,
//!    `server_public_key`, `client_config`), never a private key
//!    (cmux-platform#1048).
//! 2. **Hub.** The answer and the device's WireGuard private key (the join
//!    record's key, which the platform requires) become a wg-quick config
//!    that goes only to a `wg hub --config - --client-token-stdin` child on
//!    its stdin: no file holds it. The hub serves SOCKS5 on the socket for
//!    `cmux wg dial`; port 22 needs no hub token.
//! 3. **Refresh.** Every [`TunnelTiming::refresh_every`] the device reads its
//!    tunnel straight from the VM API, `POST /v1/devices/{id}/signed/tunnel`
//!    (install-key signed, purpose `tunnel`, no credential), at the origin
//!    attach named in `vm_api_origin` (else the plan's derived one). The read
//!    replaces the attach's routes, gateway and keys; a changed config
//!    restarts the hub; 404 (device deleted, rotated away, team left the
//!    experiment) re-attaches.
//! 4. **Re-attach** on 409 `mesh.device.superseded` (the machine was rekeyed
//!    or detached while it enrolled), on 400 `mesh.device.enrollment_refused`
//!    (a fresh signature), and when the identity source's WireGuard key
//!    changed (a platform rekey; the device never calls `/signed/rotate-key`
//!    itself).
//!
//! Every loop ends: on [`TunnelHandle::stop`], on a terminal status
//! (unavailable, refused), or after [`TunnelTiming::max_failures`]
//! consecutive failed attaches, refreshes or hub starts; each retry waits a
//! jittered, doubling delay. Nothing here logs or prints a private key or a
//! credential: the rendered config is [`Zeroizing`] and has no `Debug`.

use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use cmux_server_core::pairing::native::mesh_proof;
use ring::rand::SecureRandom as _;
use serde_json::{Value, json};
use tokio::sync::watch;
use zeroize::Zeroizing;

use super::answer::{HttpSource, SourceError};

/// The reason `carrier capabilities` gives for ssh when the team has no
/// provider mesh: `ssh: unavailable (no mesh)`.
pub(crate) const NO_MESH: &str = "no mesh";

/// Who the device is, read afresh before every attach so a platform rekey
/// (a new join key) is picked up. The private halves never leave this
/// process except as the hub's stdin.
pub(crate) struct TunnelIdentity {
    /// The joined machine (`machine_…`), never its `cmm_` credential.
    pub machine_id: String,
    /// The device name the enrollment signs: the machine's name.
    pub name: String,
    /// The join record's WireGuard private key.
    pub wg_private: Zeroizing<[u8; 32]>,
    /// The device's install key (ES256), which signs every mesh request.
    pub install: Arc<InstallKey>,
}

impl TunnelIdentity {
    fn wg_public(&self) -> String {
        let secret = x25519_dalek::StaticSecret::from(*self.wg_private);
        STANDARD.encode(x25519_dalek::PublicKey::from(&secret).as_bytes())
    }

    /// The install public key as the VM API reads it: standard base64 of the
    /// 65-byte uncompressed point (the tail of its SPKI).
    fn install_public(&self) -> String {
        let spki = self.install.public_spki();
        STANDARD.encode(spki.get(spki.len().saturating_sub(65)..).unwrap_or_default())
    }

    /// One `cmux-mesh-v1` proof, fresh time and nonce.
    fn proof(&self, purpose: &str, target: &str, wg: &str, name: &str) -> Result<Value, String> {
        let rng = SystemRandom::new();
        let mut nonce = [0u8; 16];
        rng.fill(&mut nonce).map_err(|_| "no random source for the nonce".to_owned())?;
        let install = self.install_public();
        mesh_proof([purpose, target, wg, &install, name], now_ms(), nonce, |message| {
            self.install.sign(message, &rng)
        })
    }
}

/// Reads the device's identity; `Err` is terminal (no key to enroll).
pub(crate) type IdentitySource = Arc<dyn Fn() -> Result<TunnelIdentity, String> + Send + Sync>;

/// The client half of a provider tunnel, as attach answers it. Holds no
/// private key, so it may be compared and printed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DeviceTunnel {
    pub tunnel_id: String,
    pub device_id: String,
    pub mesh_id: String,
    pub address_v4: Option<String>,
    pub server_public_key: String,
    pub endpoint: String,
    pub interface_address: String,
    pub allowed_ips: Vec<String>,
    pub mtu: u16,
    pub persistent_keepalive_seconds: u16,
    /// The VM API origin attach named for this device's own reads
    /// (`vm_api_origin`); `None` uses the plan's derived origin.
    pub vm_api_origin: Option<String>,
}

/// Characters a config value may hold: addresses, ports, prefixes, host
/// names. No `=`, `#`, space or line break can reach the wg-quick text.
fn config_safe(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b".:-[]/_".contains(&b))
}

fn wg_key_text(value: &str) -> bool {
    value.len() == 44
        && value.ends_with('=')
        && STANDARD.decode(value).is_ok_and(|bytes| bytes.len() == 32)
}

fn text<'a>(value: &'a Value, name: &str) -> Option<&'a str> {
    value.get(name)?.as_str().filter(|s| !s.is_empty())
}

/// A non-empty route list whose every entry is safe in the config.
fn routes(value: &Value) -> Option<Vec<String>> {
    let routes: Vec<String> = value
        .as_array()?
        .iter()
        .map(|ip| ip.as_str().filter(|ip| config_safe(ip)).map(str::to_owned))
        .collect::<Option<_>>()?;
    (!routes.is_empty()).then_some(routes)
}

fn small(value: &Value, name: &str, min: u64, max: u64) -> Option<u16> {
    value.get(name)?.as_u64().filter(|n| (min..=max).contains(n)).and_then(|n| n.try_into().ok())
}

impl DeviceTunnel {
    /// The attach answer's tunnel; `None` when it enrolled nothing or a field
    /// would not be safe in a wg-quick config.
    pub(crate) fn from_attach(body: &Value) -> Option<Self> {
        let config = body.get("client_config").filter(|c| c.is_object())?;
        let tunnel = Self {
            tunnel_id: text(body, "tunnel_id")?.to_owned(),
            device_id: text(body, "device_id").filter(|d| d.starts_with("dev_"))?.to_owned(),
            mesh_id: text(body, "mesh_id")?.to_owned(),
            address_v4: text(body, "address_v4").map(str::to_owned),
            server_public_key: text(body, "server_public_key")
                .filter(|k| wg_key_text(k))?
                .to_owned(),
            endpoint: text(config, "endpoint").filter(|e| config_safe(e))?.to_owned(),
            interface_address: text(config, "interface_address")
                .filter(|a| config_safe(a))?
                .to_owned(),
            allowed_ips: routes(config.get("allowed_ips")?)?,
            mtu: small(config, "mtu", 576, 9000)?,
            persistent_keepalive_seconds: small(config, "persistent_keepalive_seconds", 0, 3600)?,
            // An origin that is not a bare https one (or loopback http) is
            // ignored: the derived origin serves instead.
            vm_api_origin: text(body, "vm_api_origin")
                .and_then(|origin| crate::cli::secure_cloud_origin(origin).ok()),
        };
        Some(tunnel)
    }

    /// This tunnel after a VM API `TunnelConfig` read (camelCase). The read
    /// is newer than the attach, so its routes, gateway, keys, address and
    /// timers replace the attach's; the attach's routes stay only when the
    /// read has no `allowedIps`. `None` when the read names another device
    /// or a field is not safe.
    pub(crate) fn refreshed(&self, body: &Value) -> Option<Self> {
        if text(body, "deviceId") != Some(self.device_id.as_str()) {
            return None;
        }
        let host = text(body, "endpointHost").filter(|h| config_safe(h))?;
        let port = small(body, "endpointPort", 1, 65535)?;
        let endpoint =
            if host.contains(':') { format!("[{host}]:{port}") } else { format!("{host}:{port}") };
        Some(Self {
            tunnel_id: text(body, "id")?.to_owned(),
            device_id: self.device_id.clone(),
            mesh_id: text(body, "meshId")?.to_owned(),
            address_v4: text(body, "meshAddress").map(str::to_owned),
            server_public_key: text(body, "serverPublicKey").filter(|k| wg_key_text(k))?.to_owned(),
            endpoint,
            interface_address: text(body, "interfaceAddress")
                .filter(|a| config_safe(a))?
                .to_owned(),
            allowed_ips: match body.get("allowedIps").filter(|ips| !ips.is_null()) {
                Some(ips) => routes(ips)?,
                None => self.allowed_ips.clone(),
            },
            mtu: small(body, "mtu", 576, 9000)?,
            persistent_keepalive_seconds: small(body, "persistentKeepaliveSeconds", 0, 3600)?,
            vm_api_origin: self.vm_api_origin.clone(),
        })
    }

    /// The wg-quick config the hub reads on stdin. Only ever handed to the
    /// hub; never logged or written to a file.
    pub(crate) fn wg_quick(&self, private: &[u8; 32]) -> Zeroizing<String> {
        let key = Zeroizing::new(STANDARD.encode(private));
        let mut text = Zeroizing::new(String::with_capacity(320));
        text.push_str("[Interface]\nPrivateKey = ");
        text.push_str(&key);
        text.push_str(&format!(
            "\nAddress = {}\nMTU = {}\n\n[Peer]\nPublicKey = {}\nEndpoint = {}\nAllowedIPs = {}\n",
            self.interface_address,
            self.mtu,
            self.server_public_key,
            self.endpoint,
            self.allowed_ips.join(", "),
        ));
        if self.persistent_keepalive_seconds > 0 {
            text.push_str(&format!(
                "PersistentKeepalive = {}\n",
                self.persistent_keepalive_seconds
            ));
        }
        text
    }
}

/// What the supervisor is doing; `Ready` carries what `cmux wg dial` needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TunnelStatus {
    Starting,
    Ready {
        socket: PathBuf,
        tunnel_id: String,
        device_id: String,
        mesh_id: String,
        address_v4: Option<String>,
    },
    /// Retrying after a failure; the tunnel is down until it recovers.
    Retrying(String),
    /// The team has no provider mesh ([`NO_MESH`]); nothing retries.
    Unavailable(String),
    /// Refused or out of attempts; nothing retries.
    Failed(String),
    Stopped,
}

impl TunnelStatus {
    pub(crate) fn is_final(&self) -> bool {
        matches!(self, Self::Unavailable(_) | Self::Failed(_) | Self::Stopped)
    }
}

/// A running `wg hub`.
#[async_trait]
pub(crate) trait RunningHub: Send {
    /// Resolves when the hub ends on its own, with why.
    async fn exited(&mut self) -> String;
    /// Ends the hub and waits for it.
    async fn stop(self: Box<Self>);
}

/// Starts a hub with a config on `socket`, ready to serve when it answers.
#[async_trait]
pub(crate) trait HubLauncher: Send + Sync {
    async fn launch(
        &self,
        config: Zeroizing<String>,
        socket: &Path,
    ) -> Result<Box<dyn RunningHub>, String>;
}

/// Delays and bounds; [`TunnelTiming::default`] for real use.
#[derive(Clone, Copy, Debug)]
pub(crate) struct TunnelTiming {
    pub refresh_every: Duration,
    pub retry_floor: Duration,
    pub retry_ceiling: Duration,
    /// Consecutive failures (attach, refresh or hub start) before `Failed`.
    pub max_failures: u32,
}

impl Default for TunnelTiming {
    fn default() -> Self {
        Self {
            // Well inside the gateway's 5-10 minute idle forget; a refresh is
            // one small signed POST.
            refresh_every: Duration::from_secs(5 * 60),
            retry_floor: Duration::from_secs(1),
            retry_ceiling: Duration::from_secs(60),
            max_failures: 8,
        }
    }
}

/// One supervisor's inputs.
pub(crate) struct TunnelPlan {
    pub identity: IdentitySource,
    /// cmux-platform with the person's credential (attach).
    pub platform: Arc<HttpSource>,
    /// The VM API origin (the device's own signed tunnel read).
    pub vm_api: String,
    /// The hub's SOCKS5 socket, for `cmux wg dial --hub`.
    pub socket: PathBuf,
    pub launcher: Arc<dyn HubLauncher>,
    pub timing: TunnelTiming,
    /// The retry delay for a ceiling (the session's full-jitter draw).
    pub jitter: fn(Duration) -> Duration,
}

#[derive(Debug)]
pub(crate) enum StartError {
    /// Another supervisor on this Mac holds the tunnel; its socket is
    /// `socket`.
    Held {
        socket: PathBuf,
    },
    Io(String),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Held { socket } => {
                write!(f, "another process holds the Cloud tunnel at {}", socket.display())
            }
            Self::Io(why) => write!(f, "the Cloud tunnel lock is unavailable: {why}"),
        }
    }
}

/// A running supervisor.
pub(crate) struct TunnelHandle {
    socket: PathBuf,
    status: watch::Receiver<TunnelStatus>,
    stop: watch::Sender<bool>,
    task: tokio::task::JoinHandle<TunnelStatus>,
    _lock: File,
}

impl TunnelHandle {
    /// The socket `cmux wg dial --hub` takes (served once `Ready`).
    pub(crate) fn socket(&self) -> &Path {
        &self.socket
    }

    pub(crate) fn status(&self) -> watch::Receiver<TunnelStatus> {
        self.status.clone()
    }

    /// Waits for the first `Ready` or final status.
    #[cfg(test)]
    pub(crate) async fn settled(&self) -> TunnelStatus {
        let mut status = self.status.clone();
        let settled = status
            .wait_for(|s| s.is_final() || matches!(s, TunnelStatus::Ready { .. }))
            .await
            .map(|s| s.clone());
        settled.unwrap_or(TunnelStatus::Stopped)
    }

    /// Stops the hub and the supervisor; the final status.
    pub(crate) async fn stop(self) -> TunnelStatus {
        let _ = self.stop.send(true);
        self.task.await.unwrap_or(TunnelStatus::Stopped)
    }

    /// Waits for the supervisor to end by itself (a final status).
    pub(crate) async fn finished(self) -> TunnelStatus {
        self.task.await.unwrap_or(TunnelStatus::Stopped)
    }
}

/// Starts the supervisor for this Mac, on the current runtime.
pub(crate) fn start(plan: TunnelPlan) -> Result<TunnelHandle, StartError> {
    let lock = hold(&plan.socket)?;
    let (status_tx, status) = watch::channel(TunnelStatus::Starting);
    let (stop, stop_rx) = watch::channel(false);
    let socket = plan.socket.clone();
    let task = tokio::spawn(async move {
        let last = Supervisor { plan, status: status_tx.clone(), stop: stop_rx }.run().await;
        status_tx.send_replace(last.clone());
        last
    });
    Ok(TunnelHandle { socket, status, stop, task, _lock: lock })
}

/// The one-per-Mac lock beside the socket.
/// The supervisor's own lock: `<socket>.tunnel-lock`, owner-only (0600) and
/// never followed through a symlink. Never `<socket>.lock`: that one is the
/// hub's (`OwnedUnixListener::bind` leases it), and holding it here would
/// keep the hub from binding.
pub(crate) fn lock_path(socket: &Path) -> PathBuf {
    let mut path = socket.as_os_str().to_owned();
    path.push(".tunnel-lock");
    PathBuf::from(path)
}

fn hold(socket: &Path) -> Result<File, StartError> {
    use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
    let io = |e: std::io::Error| StartError::Io(format!("{:?}", e.kind()));
    // The hub secures (and checks) the socket's directory; it must exist
    // first for the lock beside the socket, owner-only like the hub makes it.
    if let Some(parent) = socket.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent).map_err(io)?;
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(lock_path(socket))
        .map_err(io)?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(std::fs::TryLockError::WouldBlock) => {
            Err(StartError::Held { socket: socket.to_path_buf() })
        }
        Err(std::fs::TryLockError::Error(e)) => Err(StartError::Io(format!("{:?}", e.kind()))),
    }
}

/// Why an attach or refresh did not give a tunnel.
#[derive(Debug, PartialEq, Eq)]
enum Miss {
    /// The team has no provider mesh.
    NoMesh(String),
    /// The device is gone (refresh 404) or superseded: attach again.
    Reattach(String),
    /// Try the same step again after a delay.
    Retry(String),
    Fatal(String),
}

impl From<SourceError> for Miss {
    fn from(error: SourceError) -> Self {
        if error.retryable { Self::Retry(error.detail) } else { Self::Fatal(error.detail) }
    }
}

fn code(body: &Value) -> &str {
    body.get("code").and_then(Value::as_str).unwrap_or("")
}

/// The attach answer's status read as a step outcome.
fn attach_miss(status: u16, body: &Value) -> Miss {
    let code = code(body);
    let detail = format!("attach answered {status} {code}");
    match (status, code) {
        (404, "mesh.device.unavailable") => Miss::NoMesh(NO_MESH.into()),
        (409, "mesh.device.superseded") => Miss::Reattach(detail),
        (400, "mesh.device.enrollment_refused") => Miss::Reattach(detail),
        (408 | 425 | 429, _) | (500..=599, _) => Miss::Retry(detail),
        _ => Miss::Fatal(detail),
    }
}

struct Supervisor {
    plan: TunnelPlan,
    status: watch::Sender<TunnelStatus>,
    stop: watch::Receiver<bool>,
}

/// What the hub loop ended with.
enum HubEnd {
    Stopped,
    Reattach,
    Final(TunnelStatus),
}

impl Supervisor {
    async fn run(mut self) -> TunnelStatus {
        let mut failures = 0u32;
        loop {
            if *self.stop.borrow() {
                return TunnelStatus::Stopped;
            }
            let identity = match (self.plan.identity)() {
                Ok(identity) => identity,
                Err(why) => return TunnelStatus::Failed(why),
            };
            let attached = tokio::select! {
                attached = attach(&self.plan, &identity) => attached,
                _ = self.stop.wait_for(|stop| *stop) => return TunnelStatus::Stopped,
            };
            let tunnel = match attached {
                Ok(tunnel) => tunnel,
                Err(Miss::NoMesh(why)) => return TunnelStatus::Unavailable(why),
                Err(Miss::Fatal(why)) => return TunnelStatus::Failed(why),
                Err(Miss::Reattach(why) | Miss::Retry(why)) => {
                    if let Some(end) = self.failed(&mut failures, why).await {
                        return end;
                    }
                    continue;
                }
            };
            failures = 0;
            match self.serve(identity, tunnel).await {
                HubEnd::Stopped => return TunnelStatus::Stopped,
                HubEnd::Final(status) => return status,
                HubEnd::Reattach => {}
            }
        }
    }

    /// Counts a failure and waits out its delay; `Some` when the supervisor
    /// should end (out of attempts, or stopped while it waited).
    /// The wait before retry number `failures` (1-based): the floor doubling
    /// per failure up to the ceiling, full jitter, never under half the floor.
    fn retry_delay(&self, failures: u32) -> Duration {
        let timing = &self.plan.timing;
        let exponent = failures.saturating_sub(1).min(16);
        let ceiling = timing.retry_floor.saturating_mul(1 << exponent).min(timing.retry_ceiling);
        (self.plan.jitter)(ceiling).max(timing.retry_floor.checked_div(2).unwrap_or_default())
    }

    fn ready(&self, tunnel: &DeviceTunnel) {
        self.status.send_replace(TunnelStatus::Ready {
            socket: self.plan.socket.clone(),
            tunnel_id: tunnel.tunnel_id.clone(),
            device_id: tunnel.device_id.clone(),
            mesh_id: tunnel.mesh_id.clone(),
            address_v4: tunnel.address_v4.clone(),
        });
    }

    async fn failed(&mut self, failures: &mut u32, why: String) -> Option<TunnelStatus> {
        *failures = failures.saturating_add(1);
        if *failures >= self.plan.timing.max_failures {
            return Some(TunnelStatus::Failed(format!("{why} ({failures} attempts)")));
        }
        self.status.send_replace(TunnelStatus::Retrying(why));
        let delay = self.retry_delay(*failures);
        tokio::select! {
            _ = tokio::time::sleep(delay) => None,
            _ = self.stop.wait_for(|stop| *stop) => Some(TunnelStatus::Stopped),
        }
    }
}

/// Attach, sign, attach (the G2 contract).
async fn attach(plan: &TunnelPlan, identity: &TunnelIdentity) -> Result<DeviceTunnel, Miss> {
    let path = format!("/v1/mesh/nodes/{}/attach", identity.machine_id);
    let (status, body) = plan.platform.post(&path, &json!({})).await?;
    if status != 200 {
        return Err(attach_miss(status, &body));
    }
    let Some(mesh) = text(&body, "mesh_id") else {
        return Err(Miss::NoMesh(NO_MESH.into()));
    };
    let wg = identity.wg_public();
    let mut enrollment =
        identity.proof("enroll", mesh, &wg, &identity.name).map_err(Miss::Fatal)?;
    if let Some(fields) = enrollment.as_object_mut() {
        fields.insert("name".into(), identity.name.clone().into());
        fields.insert("wgPublicKey".into(), wg.clone().into());
        fields.insert("installPublicKey".into(), identity.install_public().into());
    }
    let (status, body) = plan.platform.post(&path, &json!({ "enrollment": enrollment })).await?;
    if status != 200 {
        return Err(attach_miss(status, &body));
    }
    if text(&body, "client_public_key").is_some_and(|key| key != wg) {
        return Err(Miss::Reattach("attach answered another key".into()));
    }
    DeviceTunnel::from_attach(&body).ok_or_else(|| Miss::Fatal("attach answered no tunnel".into()))
}

impl Supervisor {
    /// The device's own tunnel read from the VM API.
    async fn refresh(
        &self,
        client: &reqwest::Client,
        identity: &TunnelIdentity,
        tunnel: &DeviceTunnel,
    ) -> Result<DeviceTunnel, Miss> {
        let proof = identity.proof("tunnel", &tunnel.device_id, "", "").map_err(Miss::Fatal)?;
        let origin = tunnel.vm_api_origin.as_deref().unwrap_or(&self.plan.vm_api);
        let url = format!("{origin}/v1/devices/{}/signed/tunnel", tunnel.device_id);
        let response = client
            .post(url)
            .json(&proof)
            .send()
            .await
            .map_err(|_| Miss::Retry("the VM API did not answer".into()))?;
        let status = response.status().as_u16();
        let body: Value = response.json().await.unwrap_or(Value::Null);
        match status {
            200 => tunnel
                .refreshed(&body)
                .ok_or_else(|| Miss::Retry("the VM API answered an unreadable tunnel".into())),
            // Deleted, rotated away, or the team lost the experiment: the
            // attach says which.
            404 => Err(Miss::Reattach(format!("tunnel read answered 404 {}", code(&body)))),
            // 403 a clock off by more than 120 s, 409 a replay: sign again.
            _ => Err(Miss::Retry(format!("tunnel read answered {status} {}", code(&body)))),
        }
    }

    /// Keeps a hub up on `tunnel` until stop, a re-attach or a final status.
    async fn serve(&mut self, identity: TunnelIdentity, mut tunnel: DeviceTunnel) -> HubEnd {
        let client = match reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(30))
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .build()
        {
            Ok(client) => client,
            Err(_) => return HubEnd::Final(TunnelStatus::Failed("no HTTP client".into())),
        };
        let wg_public = identity.wg_public();
        let mut failures = 0u32;
        loop {
            let config = tunnel.wg_quick(&identity.wg_private);
            let launched = tokio::select! {
                launched = self.plan.launcher.launch(config, &self.plan.socket) => launched,
                _ = self.stop.wait_for(|stop| *stop) => return HubEnd::Stopped,
            };
            let mut hub = match launched {
                Ok(hub) => hub,
                Err(why) => {
                    if let Some(end) = self.failed(&mut failures, format!("hub: {why}")).await {
                        return HubEnd::Final(end);
                    }
                    continue;
                }
            };
            self.ready(&tunnel);
            // The hub runs until it ends, the config changes, or the device
            // must attach again.
            let next = loop {
                // After a failed read the next one comes on the retry
                // backoff, never later than the usual refresh.
                let wait = match failures {
                    0 => self.plan.timing.refresh_every,
                    n => self.retry_delay(n).min(self.plan.timing.refresh_every),
                };
                let tick = tokio::time::sleep(wait);
                // `None` is the refresh tick.
                let event = tokio::select! {
                    _ = self.stop.wait_for(|stop| *stop) => Some(None),
                    why = hub.exited() => Some(Some(why)),
                    _ = tick => None,
                };
                match event {
                    Some(None) => {
                        hub.stop().await;
                        return HubEnd::Stopped;
                    }
                    // A hub that ends by itself restarts on a fresh read.
                    Some(Some(why)) => {
                        let why = format!("hub ended: {why}");
                        if let Some(end) = self.failed(&mut failures, why).await {
                            return HubEnd::Final(end);
                        }
                        break None;
                    }
                    None => {}
                }
                // A platform rekey changed the join key: enroll the new one.
                match (self.plan.identity)() {
                    Ok(now) if now.wg_public() == wg_public => {}
                    Ok(_) => {
                        hub.stop().await;
                        return HubEnd::Reattach;
                    }
                    Err(why) => {
                        hub.stop().await;
                        return HubEnd::Final(TunnelStatus::Failed(why));
                    }
                }
                match self.refresh(&client, &identity, &tunnel).await {
                    Ok(fresh) if fresh == tunnel => {
                        // A read that works again after a failure: the
                        // tunnel the hub serves is current, so it is ready.
                        if failures > 0 {
                            failures = 0;
                            self.ready(&tunnel);
                        }
                    }
                    Ok(fresh) => break Some(fresh),
                    Err(Miss::Reattach(_) | Miss::NoMesh(_)) => {
                        hub.stop().await;
                        return HubEnd::Reattach;
                    }
                    Err(Miss::Fatal(why)) => {
                        hub.stop().await;
                        return HubEnd::Final(TunnelStatus::Failed(why));
                    }
                    // The hub keeps serving the config it has until the
                    // reads have failed `max_failures` times in a row, which
                    // is final: a re-attach would reset the count and an
                    // unreachable VM API would loop for good.
                    Err(Miss::Retry(why)) => {
                        failures = failures.saturating_add(1);
                        if failures >= self.plan.timing.max_failures {
                            hub.stop().await;
                            let why = format!("{why} ({failures} attempts)");
                            return HubEnd::Final(TunnelStatus::Failed(why));
                        }
                        self.status.send_replace(TunnelStatus::Retrying(why));
                    }
                }
            };
            match next {
                Some(fresh) => {
                    hub.stop().await;
                    tunnel = fresh;
                }
                // The hub ended: read the tunnel before starting another.
                None => match self.refresh(&client, &identity, &tunnel).await {
                    Ok(fresh) => tunnel = fresh,
                    Err(Miss::Reattach(_) | Miss::NoMesh(_)) => return HubEnd::Reattach,
                    Err(Miss::Fatal(why)) => return HubEnd::Final(TunnelStatus::Failed(why)),
                    Err(Miss::Retry(_)) => {}
                },
            }
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(1, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .max(1)
}

/// The real hub: `cmux wg hub --config - --socket S --client-token-stdin
/// --exit-with-parent`, the token and config on its stdin, ready when it
/// prints its `hub-ready` line.
pub(crate) struct ProcessHubLauncher {
    exe: PathBuf,
    token: Zeroizing<String>,
    ready_timeout: Duration,
}

impl ProcessHubLauncher {
    /// `exe` is this cmux binary. The hub token is random per supervisor; ssh
    /// (port 22) needs none, anything else through the hub does.
    pub(crate) fn new(exe: PathBuf) -> Result<Self, String> {
        let mut bytes = Zeroizing::new([0u8; 24]);
        SystemRandom::new().fill(bytes.as_mut()).map_err(|_| "no random source".to_owned())?;
        let token = Zeroizing::new(bytes.iter().map(|b| format!("{b:02x}")).collect::<String>());
        // Covers endpoint resolution and the first handshake inside `wg hub`.
        Ok(Self { exe, token, ready_timeout: Duration::from_secs(45) })
    }
}

struct ProcessHub {
    pid: libc::pid_t,
    /// Set once the reaper thread has waited the child out.
    ended: watch::Receiver<Option<String>>,
}

impl ProcessHub {
    fn signal(&self, signal: libc::c_int) {
        // Never after the reaper's wait: the pid could be another process's.
        if self.ended.borrow().is_none() {
            // SAFETY: `pid` is this supervisor's own child, not yet reaped.
            unsafe { libc::kill(self.pid, signal) };
        }
    }

    async fn wait_ended(&mut self) -> String {
        match self.ended.wait_for(Option::is_some).await {
            Ok(why) => why.clone().unwrap_or_default(),
            Err(_) => "the hub's reaper ended".into(),
        }
    }
}

impl Drop for ProcessHub {
    fn drop(&mut self) {
        // A supervisor dropped without `stop` still ends its hub (the hub's
        // `--exit-with-parent` covers this process ending).
        self.signal(libc::SIGTERM);
    }
}

#[async_trait]
impl RunningHub for ProcessHub {
    async fn exited(&mut self) -> String {
        self.wait_ended().await
    }

    async fn stop(mut self: Box<Self>) {
        self.signal(libc::SIGTERM);
        if tokio::time::timeout(Duration::from_secs(5), self.wait_ended()).await.is_err() {
            self.signal(libc::SIGKILL);
            self.wait_ended().await;
        }
    }
}

#[async_trait]
impl HubLauncher for ProcessHubLauncher {
    async fn launch(
        &self,
        config: Zeroizing<String>,
        socket: &Path,
    ) -> Result<Box<dyn RunningHub>, String> {
        use std::io::{BufRead as _, Write as _};
        let mut child = cmux_process::Command::new(&self.exe)
            .args(["wg", "hub", "--config", "-", "--socket"])
            .arg(socket)
            .args(["--client-token-stdin", "--exit-with-parent"])
            .stdin(cmux_process::Stdio::piped())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::inherit())
            .spawn()
            .map_err(|e| format!("could not start wg hub ({:?})", e.kind()))?;
        let pid = libc::pid_t::try_from(child.id()).map_err(|_| "wg hub has no pid")?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        let (done, ended) = watch::channel(None);
        // The reaper: the only wait on the child, so the pid stays ours
        // until it reports.
        std::thread::spawn(move || {
            let why = match child.wait() {
                Ok(status) => status.to_string(),
                Err(e) => format!("{:?}", e.kind()),
            };
            done.send_replace(Some(why));
        });
        let hub = ProcessHub { pid, ended };
        let mut input = Zeroizing::new(Vec::with_capacity(self.token.len() + 1 + config.len()));
        input.extend_from_slice(self.token.as_bytes());
        input.push(b'\n');
        input.extend_from_slice(config.as_bytes());
        // Pipes block: both ends run off the runtime. A hub that never answers
        // is killed at the deadline, which ends the read with EOF.
        let ready = tokio::task::spawn_blocking(move || {
            let (Some(mut stdin), Some(stdout)) = (stdin, stdout) else { return false };
            if stdin.write_all(&input).is_err() {
                return false;
            }
            drop(stdin);
            let mut line = String::new();
            let read = std::io::BufReader::new(stdout).read_line(&mut line);
            matches!(read, Ok(n) if n > 0)
                && serde_json::from_str::<Value>(&line)
                    .is_ok_and(|v| v.get("event").and_then(Value::as_str) == Some("hub-ready"))
        });
        let ready = matches!(tokio::time::timeout(self.ready_timeout, ready).await, Ok(Ok(true)));
        if !ready {
            Box::new(hub).stop().await;
            return Err("wg hub did not become ready".into());
        }
        Ok(Box::new(hub))
    }
}

#[cfg(test)]
#[path = "tunnel_tests.rs"]
mod tests;
