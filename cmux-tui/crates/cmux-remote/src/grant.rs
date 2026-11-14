//! The daemon's hook for carrier grants (`ClientAuthMode::Grant`).
//!
//! A daemon admits a grant only through the [`GrantVerifier`] its owner
//! installs at start ([`crate::identity::AuthDatabase::set_grant_verifier`]).
//! With none installed, every grant is refused. The verifier sees the token
//! and the Noise static key that just finished the handshake, after the
//! handshake, and answers the session's services and a stable device id, or
//! a refusal. The Cloud verifier is cmux-link's
//! [`CarrierGrantVerifier`](cmux_link::carrier_grant::CarrierGrantVerifier).
//!
//! A grant only admits a new session (generation 0): an admitted session is
//! never re-checked against the grant's expiry, and it ends only by the
//! session's own rules (its resume lease, or a retire pushed to it). A resume
//! (generation 1 and up) carries no grant: the daemon re-admits the Noise key
//! a grant admitted before into the same session ([`AdmittedGrants`]), with
//! that session's own grant, device id and services. Its generation fence admits that only into the key's existing
//! session, so a resume never opens a new one.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use cmux_link::carrier_grant::{CarrierGrant, CarrierGrantVerifier};
use cmux_link::keyset::Keyset;
use cmux_link::token::{TokenRefusal, TokenRefused};
use cmux_remote_protocol::{Service, SessionId};
use serde_json::Value;
use sha2::{Digest as _, Sha256};

use crate::crypto::{ConnectionAttemptId, ServiceAuthority, public_key_fingerprint};

/// The most grant-admitted Noise keys the daemon remembers for resumes.
pub const MAX_ADMITTED_GRANTS: usize = 4096;

/// The device id prefix of a session a carrier grant admitted.
pub const GRANT_DEVICE_PREFIX: &str = "carrier:";

/// What a presented grant is checked against.
#[derive(Debug, Clone, Copy)]
pub struct GrantPresentation<'a> {
    pub token: &'a str,
    /// The client's Noise static public key, from the finished handshake.
    pub noise_key: &'a [u8; 32],
    /// [`link_group`] of the handshake: every physical link of one new
    /// session presents the same grant with the same group.
    pub link_group: [u8; 32],
}

/// The daemon's digest of one new session's physical links: its session,
/// generation and connection attempt. The daemon's generation fence makes a
/// group that already registered unable to open a session again.
pub fn link_group(session: SessionId, generation: u64, attempt: ConnectionAttemptId) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(b"cmux-carrier-grant-link-group-v1");
    digest.update(session.0);
    digest.update(generation.to_be_bytes());
    digest.update(attempt.0);
    digest.finalize().into()
}

/// The grants this daemon admitted, by Noise key and session, for resumes:
/// each session resumes with the grant that opened it, so a later session of
/// the same key with a fresh grant leaves it as it was. Bounded and least
/// recently used first: an admission or a resume makes an entry the newest,
/// so one in use is forgotten only after [`MAX_ADMITTED_GRANTS`] others were
/// used since. A forgotten one needs a new grant.
#[derive(Debug, Default)]
pub(crate) struct AdmittedGrants {
    inner: Mutex<Admitted>,
    capacity: Option<usize>,
}

#[derive(Debug, Default)]
struct Admitted {
    by_key: HashMap<AdmittedKey, GrantAdmission>,
    /// Oldest use first.
    order: VecDeque<AdmittedKey>,
}

/// A client's Noise key and the session its grant opened.
type AdmittedKey = ([u8; 32], SessionId);

impl Admitted {
    fn touch(&mut self, key: AdmittedKey) {
        if let Some(at) = self.order.iter().position(|held| *held == key) {
            self.order.remove(at);
        }
        self.order.push_back(key);
    }
}

impl AdmittedGrants {
    #[cfg(test)]
    fn with_capacity(capacity: usize) -> Self {
        Self { inner: Mutex::default(), capacity: Some(capacity) }
    }

    pub(crate) fn remember(
        &self,
        noise_key: [u8; 32],
        session: SessionId,
        admission: GrantAdmission,
    ) {
        let capacity = self.capacity.unwrap_or(MAX_ADMITTED_GRANTS);
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.by_key.insert((noise_key, session), admission);
        guard.touch((noise_key, session));
        while guard.order.len() > capacity {
            if let Some(oldest) = guard.order.pop_front() {
                guard.by_key.remove(&oldest);
            }
        }
    }

    /// The admission of `noise_key` in `session` for a resume, which makes it
    /// the newest.
    pub(crate) fn get(&self, noise_key: &[u8; 32], session: SessionId) -> Option<GrantAdmission> {
        let key = (*noise_key, session);
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let admission = guard.by_key.get(&key).cloned()?;
        guard.touch(key);
        Some(admission)
    }
}

/// An admitted grant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrantAdmission {
    /// `carrier:<subject>:<key fingerprint>`; see [`grant_device_id`].
    pub device_id: String,
    pub authority: ServiceAuthority,
}

/// Checks carrier grants. Installed once at daemon start.
pub trait GrantVerifier: Send + Sync {
    /// Admit the grant, or say why not. The message goes back to the client,
    /// so it never carries token or key bytes.
    fn verify(&self, presentation: GrantPresentation<'_>) -> Result<GrantAdmission, String>;
    /// The new session `link_group` presented for has registered: its
    /// grant admits no further link.
    fn seal(&self, link_group: [u8; 32]);
}

/// The stable device id of `subject`'s client with `noise_key`:
/// `carrier:<subject>:<fingerprint>`. The subject never holds a `:`, so the
/// id never collides with a trusted carrier's `carrier:<fingerprint>`.
pub fn grant_device_id(subject: &str, noise_key: &[u8; 32]) -> String {
    format!("{GRANT_DEVICE_PREFIX}{subject}:{}", public_key_fingerprint(noise_key))
}

/// Whether `device_id` names a grant-admitted session.
pub fn is_grant_device_id(device_id: &str) -> bool {
    device_id.strip_prefix(GRANT_DEVICE_PREFIX).is_some_and(|rest| rest.contains(':'))
}

/// A service name a grant may carry: the wire name of a cmux-remote
/// [`Service`] (`mux-control`, `workspace-rpc`, `process-stream`,
/// `terminal-bytes-v1`, `tcp-tunnel`, `computer-use`, `local-socket`,
/// `acpmux`).
pub fn service_from_name(name: &str) -> Option<Service> {
    serde_json::from_value(Value::String(name.to_owned())).ok()
}

/// The services only the machine's owner holds: [`Service::LocalSocket`]
/// (the Cloud desktop). A grant gets them from its `vmk: "owner"` claim,
/// never from its `svc` list, which the verifier strips of them.
pub fn owner_services(owner: bool) -> impl Iterator<Item = Service> {
    owner.then_some(Service::LocalSocket).into_iter()
}

impl GrantVerifier for CarrierGrantVerifier {
    fn verify(&self, presentation: GrantPresentation<'_>) -> Result<GrantAdmission, String> {
        let grant = CarrierGrantVerifier::verify_with(
            self,
            presentation.token,
            presentation.noise_key,
            presentation.link_group,
            serves_any,
        );
        admit(grant, presentation.noise_key)
    }

    fn seal(&self, link_group: [u8; 32]) {
        CarrierGrantVerifier::seal(self, link_group);
    }
}

/// The services of a grant this daemon knows. A name it does not know grants
/// nothing; `local-socket` comes only from the owner claim, never from `svc`.
fn known_services(grant: &CarrierGrant) -> Vec<Service> {
    let mut services = grant
        .services
        .iter()
        .filter_map(|name| service_from_name(name))
        .filter(|service| *service != Service::LocalSocket)
        .collect::<Vec<_>>();
    services.extend(owner_services(grant.owner()));
    services
}

/// The verifier's last check, run before the grant's `jti` is spent: a grant
/// naming only unknown services is refused and stays unspent.
fn serves_any(grant: &CarrierGrant) -> bool {
    !known_services(grant).is_empty()
}

/// The admission of a verified grant: its services this daemon knows (never
/// empty: [`serves_any`] refused such a grant before it was spent).
fn admit(
    grant: Result<CarrierGrant, TokenRefusal>,
    noise_key: &[u8; 32],
) -> Result<GrantAdmission, String> {
    let grant = grant.map_err(|refusal| match refusal.reason {
        "no_known_service" => "carrier grant refused: no service this daemon serves".to_owned(),
        _ => format!("carrier grant refused: {refusal}"),
    })?;
    let services = known_services(&grant);
    if services.is_empty() {
        return Err("carrier grant refused: no service this daemon serves".into());
    }
    Ok(GrantAdmission {
        device_id: grant_device_id(&grant.subject, noise_key),
        authority: ServiceAuthority::from_services(services).with_grant(grant),
    })
}

/// The session daemon's grant configuration, a JSON file its host writes
/// (`cmux-tui server --carrier-grant-config FILE`):
///
/// ```json
/// {"issuer": "cmux:cloud:production", "machine": "vm_…", "team": "team_…",
///  "keyset": {"version": "<16 hex>", "keys": {"<kid>": <Ed25519 public JWK>}}}
/// ```
///
/// Every field is public: the issuer and ids name this machine, the keyset
/// holds public keys.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrantConfig {
    pub issuer: String,
    pub machine: String,
    pub team: String,
    pub keys: Keyset,
}

impl GrantConfig {
    pub fn parse(text: &str) -> Result<Self, String> {
        let value: Value =
            serde_json::from_str(text).map_err(|e| format!("grant config is not JSON: {e}"))?;
        let object = value.as_object().ok_or("grant config is not an object")?;
        if let Some(key) = object
            .keys()
            .find(|key| !matches!(key.as_str(), "issuer" | "machine" | "team" | "keyset"))
        {
            return Err(format!("grant config has an unknown key {key:?}"));
        }
        let field = |name: &str| {
            object
                .get(name)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| format!("grant config `{name}` is missing"))
        };
        let keys = cmux_link::keyset::read_keyset(object.get("keyset").unwrap_or(&Value::Null))
            .map_err(|refused| format!("grant config keyset refused: {}", refused.as_str()))?;
        Ok(Self {
            issuer: field("issuer")?,
            machine: field("machine")?,
            team: field("team")?,
            keys,
        })
    }
}

/// What identifies one version of the grant config file: its mtime, size
/// and inode. The host writes it by rename, so a new keyset is a new stamp.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Stamp {
    modified: Option<std::time::SystemTime>,
    len: u64,
    inode: u64,
}

fn stamp(path: &Path) -> Option<Stamp> {
    let meta = std::fs::metadata(path).ok()?;
    #[cfg(unix)]
    let inode = std::os::unix::fs::MetadataExt::ino(&meta);
    #[cfg(not(unix))]
    let inode = 0;
    Some(Stamp { modified: meta.modified().ok(), len: meta.len(), inode })
}

/// The daemon's grant verifier over its [`GrantConfig`] file. A grant
/// signed by a kid the held keyset lacks re-reads the file when it changed
/// since the last read (its [`Stamp`]), and installs its keyset when the
/// issuer, machine and team are unchanged, then checks the grant again. An
/// unchanged file is never read again, and a file rewritten right after a
/// refused grant is read at the next one: no time throttle stands between
/// a rotation and its first grant. Spent grants stay spent across a reload.
pub struct FileGrantVerifier {
    path: PathBuf,
    config: GrantConfig,
    inner: CarrierGrantVerifier,
    /// The stamp of the file as last read.
    loaded: Mutex<Option<Stamp>>,
    /// Told the kid of a grant the held keyset and the file both lack, at
    /// most once per [`UNKNOWN_KID_REPORT_INTERVAL`]: the host fetches the
    /// keyset and rewrites the file.
    unknown_kid: Option<UnknownKidHook>,
    reported_at: Mutex<Option<Instant>>,
}

/// [`FileGrantVerifier::with_unknown_kid_hook`]'s hook; it must not block.
pub type UnknownKidHook = Box<dyn Fn(&str) + Send + Sync>;

/// How often an unknown kid may be reported to the host (its fetch for an
/// unknown kid is limited the same way, cmux-link `keyset`).
pub const UNKNOWN_KID_REPORT_INTERVAL: Duration = cmux_link::keyset::UNKNOWN_KID_INTERVAL;

/// The `kid` of a compact JWS's header, when it has one.
fn token_kid(token: &str) -> Option<String> {
    use base64::Engine as _;
    let header = token.split('.').next()?;
    if header.len() > 1024 {
        return None;
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(header).ok()?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    value.get("kid")?.as_str().map(str::to_owned)
}

impl std::fmt::Debug for FileGrantVerifier {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FileGrantVerifier")
            .field("path", &self.path)
            .field("machine", &self.config.machine)
            .finish_non_exhaustive()
    }
}

impl FileGrantVerifier {
    pub fn load(path: impl Into<PathBuf>) -> Result<Self, String> {
        let path = path.into();
        // The stamp before the read: a write in between is read again.
        let loaded = stamp(&path);
        let config = read_config(&path)?;
        let inner = CarrierGrantVerifier::with_system_clock(
            config.issuer.clone(),
            config.machine.clone(),
            config.team.clone(),
            config.keys.clone(),
        )
        .map_err(|_| "grant config names no valid issuer, machine, team or keyset".to_string())?;
        Ok(Self {
            path,
            config,
            inner,
            loaded: Mutex::new(loaded),
            unknown_kid: None,
            reported_at: Mutex::new(None),
        })
    }

    /// Reports a grant's kid that neither the held keyset nor the file has.
    pub fn with_unknown_kid_hook(mut self, hook: UnknownKidHook) -> Self {
        self.unknown_kid = Some(hook);
        self
    }

    fn report_unknown_kid(&self, token: &str) {
        let Some(hook) = self.unknown_kid.as_ref() else { return };
        let Some(kid) = token_kid(token) else { return };
        let mut reported_at =
            self.reported_at.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if reported_at.is_some_and(|at| at.elapsed() < UNKNOWN_KID_REPORT_INTERVAL) {
            return;
        }
        *reported_at = Some(Instant::now());
        drop(reported_at);
        hook(&kid);
    }

    pub fn config(&self) -> &GrantConfig {
        &self.config
    }

    /// Re-reads the file for a new keyset when it changed since the last
    /// read; `true` when a keyset was installed.
    fn reload_keys(&self) -> bool {
        let mut loaded = self.loaded.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let now = stamp(&self.path);
        if now.is_none() || *loaded == now {
            return false;
        }
        *loaded = now;
        let Ok(fresh) = read_config(&self.path) else { return false };
        let same_binding = fresh.issuer == self.config.issuer
            && fresh.machine == self.config.machine
            && fresh.team == self.config.team;
        same_binding && self.inner.replace_keys(fresh.keys).is_ok()
    }
}

fn read_config(path: &Path) -> Result<GrantConfig, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read grant config {}: {e}", path.display()))?;
    GrantConfig::parse(&text)
}

impl GrantVerifier for FileGrantVerifier {
    fn verify(&self, presentation: GrantPresentation<'_>) -> Result<GrantAdmission, String> {
        let check = || {
            self.inner.verify_with(
                presentation.token,
                presentation.noise_key,
                presentation.link_group,
                serves_any,
            )
        };
        let unknown = |grant: &Result<CarrierGrant, TokenRefusal>| matches!(grant, Err(refusal) if refusal.kind == TokenRefused::UnknownKey);
        let mut grant = check();
        if unknown(&grant) && self.reload_keys() {
            grant = check();
        }
        if unknown(&grant) {
            self.report_unknown_kid(presentation.token);
        }
        admit(grant, presentation.noise_key)
    }

    fn seal(&self, link_group: [u8; 32]) {
        self.inner.seal(link_group);
    }
}

#[cfg(test)]
mod tests;
