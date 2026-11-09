//! The ssh backup carrier (S6 G4): the second route of a carrier dial,
//! after the relay, on the same session and the same route runner.
//!
//! `ssh://cmux@<VM mesh ip>` through this Mac's tunnel into the team's
//! provider mesh (`cmux carrier tunnel`, [`super::tunnel`]): system `ssh`
//! with `ProxyCommand=<this cmux> wg dial --hub <hub socket> %h %p`, the
//! device's carrier key only (`IdentitiesOnly=yes`, no agent), and the
//! machine's host key pinned (`StrictHostKeyChecking=yes`,
//! `UserKnownHostsFile=<pin>`), with `-F /dev/null` so nothing of the
//! person's own ssh config or `~/.ssh/known_hosts` takes part. The key's
//! forced command runs `remote-link` (cmux-platform `SSH_CARRIER_COMMAND`),
//! so nothing is probed or installed first (G1's forced-command mode, the
//! no-op [`super::client`] `bootstrap_ssh`).
//!
//! The route exists only when the answer has an `ssh` candidate, this
//! device has a carrier key, and the tunnel's hub answers on its socket
//! ([`ssh_route`]); otherwise it is left out, and [`Absent::code`] says why
//! in the connect log. `carrier capabilities` reports the device's half of
//! that check ([`ssh_ready`]), so the two never disagree.
//!
//! The platform authorizes the key for 15 minutes
//! (`ssh-endpoint`, `purpose: "carrier"`): a link authorizes it before it
//! opens when the last authorization is near its end, and writes the pin
//! from that answer's host key. One authorization is made ahead
//! ([`SshRoute::prewarm`]) once the session is up, so a failover onto ssh
//! inside those minutes costs no guest exec.
//!
//! The private state lives under `<workspace state dir>/carrier/ssh` (0700):
//! the device's carrier key `id_ed25519` (0600, OpenSSH format) and one pin
//! per machine, `<machine>/known_hosts` (0600).

use std::fs::{DirBuilder, OpenOptions};
use std::io::Write as _;
use std::net::IpAddr;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::provider::{
    ConnectRequest, LinkGroup, LinkRequest, ProviderError, SshProvider, SshProviderConfig,
    TransportProvider,
};
use tokio::time::Instant;
use url::Url;
use zeroize::Zeroizing;

use super::answer::{CarrierAnswer, CarrierSource, SourceError, SshCandidate, now_unix};
use super::client::RESUME_DEADLINE;
use crate::remote_runtime::ResolvedRouteCandidate;

/// The ssh client a carrier runs: `ssh` on `PATH`, or this variable's value.
pub(super) const SSH_BINARY_ENV: &str = "CMUX_CARRIER_SSH_BINARY";
/// An authorization is renewed this long before the key's expiry.
const KEY_MARGIN_SECS: u64 = 60;
/// The longest one authorization (its turn, the platform's answer and the
/// pin) may take once the dial that built the route is over: a resume's
/// whole window.
const AUTHORIZE_TIMEOUT: Duration = RESUME_DEADLINE;
/// The remote command the provider names. sshd runs the key's forced
/// command instead (cmux-platform `SSH_CARRIER_COMMAND`, the same words), so
/// these only say what runs there.
const REMOTE_BINARY: &str = "~/.cmux/bin/cmux-tui";
const REMOTE_SESSION: &str = "cloud";
const REMOTE_MUX_SOCKET: &str = "/tmp/cmux-tui-1000/cloud.sock";

/// Where the ssh carrier's pieces come from, for every dial of one process.
#[derive(Clone, Debug, Default)]
pub(super) struct SshSetup {
    /// The tunnel hub's socket (`carrier tunnel --socket`).
    pub hub: Option<PathBuf>,
    /// The private directory for the carrier key and the pins.
    pub state: Option<PathBuf>,
    /// The ssh client.
    pub ssh_binary: String,
    /// This cmux binary, which the ProxyCommand runs as `wg dial`.
    pub exe: Option<PathBuf>,
}

impl SshSetup {
    /// `--wg-hub`, else [`default_hub`]; the state directory, the ssh
    /// client and this binary from the environment.
    pub(super) fn from_env(hub: Option<PathBuf>) -> Self {
        let state = cmux_tui_core::platform::workspace_state_dir()
            .map(|dir| dir.join("carrier").join("ssh"));
        Self {
            hub: hub.or_else(default_hub),
            state,
            ssh_binary: std::env::var(SSH_BINARY_ENV)
                .ok()
                .filter(|b| !b.trim().is_empty())
                .unwrap_or_else(|| "ssh".into()),
            exe: std::env::current_exe().ok(),
        }
    }
}

/// `<workspace state dir>/carrier/tunnel.sock`: where a dial looks for the
/// tunnel hub when `--wg-hub` names none (`carrier tunnel --socket` takes it).
pub(super) fn default_hub() -> Option<PathBuf> {
    cmux_tui_core::platform::workspace_state_dir()
        .map(|dir| dir.join("carrier").join("tunnel.sock"))
        .filter(|path| cmux_unix_socket::fits(path))
}

/// A refusal the platform means for good (ssh-endpoint's 501, an answer
/// that is not a carrier key's), kept for the rest of one dial: its routes
/// leave ssh out from then on, and say why, instead of asking again.
#[derive(Clone, Debug, Default)]
pub(super) struct SshRefusal(Arc<OnceLock<String>>);

impl SshRefusal {
    /// The refusal's reason, once there is one.
    pub(super) fn get(&self) -> Option<&str> {
        self.0.get().map(String::as_str)
    }

    fn set(&self, reason: String) {
        let _ = self.0.set(reason);
    }
}

/// Why an answer's dial has no ssh route.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Absent {
    /// The answer has no (well-formed) `ssh`: not the owner, not a mesh
    /// member yet, or a platform without the field.
    Candidate,
    /// No tunnel hub answers on its socket (no `carrier tunnel`, or the
    /// team's mesh devices are off).
    Tunnel,
    /// No carrier key: no private state directory, or the key could not be
    /// read or made.
    Key,
    /// The platform refused the carrier key for good earlier in the dial
    /// ([`SshRefusal`]).
    Refused,
}

impl Absent {
    /// The connect log's word for it.
    pub(super) fn code(self) -> &'static str {
        match self {
            Self::Candidate => "no_candidate",
            Self::Tunnel => "no_tunnel",
            Self::Key => "no_key",
            Self::Refused => "refused",
        }
    }
}

/// Whether the hub serves its socket now.
fn hub_up(socket: &Path) -> bool {
    std::os::unix::net::UnixStream::connect(socket).is_ok()
}

/// What [`ssh_device`] found.
struct SshDevice<'a> {
    hub: &'a Path,
    exe: &'a Path,
    state: &'a Path,
    key: CarrierKey,
}

/// This device's half of the ssh route, or why there is none: no refusal
/// this dial, the tunnel hub up, this binary for the ProxyCommand, paths ssh
/// can take, and the carrier key (read, or made the first time). [`ssh_route`] asks it for
/// every answer, and `carrier capabilities` reports it as ssh's
/// availability ([`super::fault::this_build`]), so the two cannot disagree.
fn ssh_device<'a>(setup: &'a SshSetup, refusal: &SshRefusal) -> Result<SshDevice<'a>, Absent> {
    if refusal.get().is_some() {
        return Err(Absent::Refused);
    }
    let hub = setup.hub.as_deref().filter(|hub| hub_up(hub)).ok_or(Absent::Tunnel)?;
    let exe = setup.exe.as_deref().ok_or(Absent::Tunnel)?;
    let state = setup.state.as_deref().ok_or(Absent::Key)?;
    // Every path the route hands ssh must be one ssh can take, checked
    // here with the same words the route's arguments use: the pin's own
    // directory is a machine id, which adds no character ssh refuses.
    ssh_arguments(&CarrierKey::path_in(state), &state.join("known_hosts"), exe, hub)
        .ok_or(Absent::Key)?;
    let key = CarrierKey::load_or_create(state).map_err(|_| Absent::Key)?;
    Ok(SshDevice { hub, exe, state, key })
}

/// Whether this device can carry the ssh route ([`ssh_device`]), for
/// `carrier capabilities`, which has no answer and no dial: the answer's
/// `ssh` candidate and the platform's refusal are per dial, in the connect
/// log's `ssh=`.
pub(super) fn ssh_ready(setup: &SshSetup) -> Result<(), Absent> {
    ssh_device(setup, &SshRefusal::default()).map(|_| ())
}

/// The ssh route of `answer`, or why there is none. Nothing here asks the
/// network: the key is authorized when a link opens, by the dial's
/// `deadline` while it runs (see [`SshRoute::authorize`]).
pub(super) fn ssh_route(
    setup: &SshSetup,
    answer: &CarrierAnswer,
    machine: &str,
    source: Arc<dyn CarrierSource>,
    deadline: Instant,
    refusal: &SshRefusal,
) -> Result<Arc<SshRoute>, Absent> {
    let candidate = answer.ssh.clone().ok_or(Absent::Candidate)?;
    let SshDevice { hub, exe, state, key } = ssh_device(setup, refusal)?;
    let pin = state.join(machine).join("known_hosts");
    let args = ssh_arguments(&key.path, &pin, exe, hub).ok_or(Absent::Key)?;
    let config = SshProviderConfig {
        ssh_binary: setup.ssh_binary.clone(),
        remote_binary: REMOTE_BINARY.into(),
        remote_session: REMOTE_SESSION.into(),
        remote_mux_socket: Some(REMOTE_MUX_SOCKET.into()),
        extra_args: args,
        // The dial's stderr is a contract the probe reads: ssh's own words
        // go into the link's error and the connect log instead.
        capture_stderr: true,
        ..SshProviderConfig::default()
    };
    let provider = SshProvider::new(config).map_err(|_| Absent::Key)?;
    let url = route_url(&candidate).ok_or(Absent::Candidate)?;
    Ok(Arc::new(SshRoute {
        url,
        machine: machine.to_owned(),
        candidate,
        public_key: key.public_line,
        pin,
        source,
        provider,
        dial_deadline: deadline,
        refusal: refusal.clone(),
        authorized_until: AtomicU64::new(0),
        authorizing: tokio::sync::Mutex::new(()),
    }))
}

/// `ssh://<user>@<host>:<port>`.
fn route_url(candidate: &SshCandidate) -> Option<Url> {
    let host = match candidate.host {
        IpAddr::V4(ip) => ip.to_string(),
        IpAddr::V6(ip) => format!("[{ip}]"),
    };
    Url::parse(&format!("ssh://{}@{host}:{}", candidate.user, candidate.port)).ok()
}

/// A path as one ssh config word, for options ssh expands: `%` doubled
/// (`IdentityFile`, `UserKnownHostsFile` and `ProxyCommand` expand `%`
/// tokens), and `None` for a `"`, a control character, or `${` (the first
/// two also expand `${VAR}`, and nothing escapes it).
fn ssh_path(path: &Path) -> Option<String> {
    let text = path.to_str()?;
    let unsafe_char = text.chars().any(|c| c == '"' || c.is_control());
    (!unsafe_char && !text.contains("${")).then(|| text.replace('%', "%%"))
}

/// A path as one `/bin/sh` word inside the ProxyCommand: single-quoted,
/// with `%` doubled.
fn shell_path(path: &Path) -> Option<String> {
    let text = ssh_path(path)?;
    Some(format!("'{}'", text.replace('\'', r"'\''")))
}

/// The ssh options of the carrier: only the carrier key, the pin, and the
/// tunnel's `wg dial` as the ProxyCommand, with no person's config, agent,
/// known hosts, prompt or shared master. `None` for a path ssh cannot take.
///
/// The key goes as `-o IdentityFile`, not `-i`: ssh `stat`s an `-i` path
/// as given, before it expands `%%` back to `%`, so a key whose path holds
/// a `%` would be dropped with a warning (and a single `%` is a token).
pub(super) fn ssh_arguments(key: &Path, pin: &Path, exe: &Path, hub: &Path) -> Option<Vec<String>> {
    let proxy =
        format!("ProxyCommand={} wg dial --hub {} %h %p", shell_path(exe)?, shell_path(hub)?);
    let mut args = vec!["-F".to_owned(), "/dev/null".to_owned()];
    for option in [
        format!("IdentityFile=\"{}\"", ssh_path(key)?),
        "IdentitiesOnly=yes".to_owned(),
        "IdentityAgent=none".to_owned(),
        "StrictHostKeyChecking=yes".to_owned(),
        format!("UserKnownHostsFile=\"{}\"", ssh_path(pin)?),
        "GlobalKnownHostsFile=/dev/null".to_owned(),
        "CheckHostIP=no".to_owned(),
        "HostKeyAlgorithms=ssh-ed25519".to_owned(),
        "BatchMode=yes".to_owned(),
        "ControlMaster=no".to_owned(),
        "ControlPath=none".to_owned(),
        "ConnectTimeout=10".to_owned(),
        "ServerAliveInterval=15".to_owned(),
        "ServerAliveCountMax=2".to_owned(),
        "LogLevel=ERROR".to_owned(),
        proxy,
    ] {
        args.push("-o".to_owned());
        args.push(option);
    }
    Some(args)
}

/// The known_hosts line that pins `host_key` for `host:port`.
pub(super) fn pin_line(host: IpAddr, port: u16, host_key: &str) -> String {
    let name = match (host, port) {
        (IpAddr::V4(ip), 22) => ip.to_string(),
        (IpAddr::V6(ip), 22) => ip.to_string(),
        (ip, port) => format!("[{ip}]:{port}"),
    };
    format!("{name} {host_key}\n")
}

/// Creates `dir` (and its parents) owner-only.
fn private_dir(dir: &Path) -> std::io::Result<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(dir)
}

/// Writes `bytes` to a file that must not exist yet, 0600, never through a symlink.
fn write_new(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Writes `bytes` to `path` as a new 0600 file, never through a symlink:
/// a fresh temporary beside it, then renamed over it.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let folder = path.parent().ok_or(std::io::ErrorKind::InvalidInput)?;
    private_dir(folder)?;
    let temporary =
        temporary_beside(folder, path.file_name().and_then(|n| n.to_str()).unwrap_or("file"))?;
    write_own(&temporary, bytes)?;
    let renamed = std::fs::rename(&temporary, path);
    if renamed.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    renamed
}

/// A temporary file name in `folder` for `stem` that no other write uses,
/// in this process (a counter) or another (the pid and a random part).
fn temporary_beside(folder: &Path, stem: &str) -> std::io::Result<PathBuf> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let mut nonce = [0_u8; 8];
    getrandom::fill(&mut nonce).map_err(|_| std::io::Error::from(std::io::ErrorKind::Other))?;
    Ok(folder.join(format!(
        ".{stem}.{}.{}.{:016x}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed),
        u64::from_be_bytes(nonce)
    )))
}

/// [`write_new`], removing the file again if it made it and the write
/// failed; a file that was there already is never touched.
fn write_own(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let written = write_new(path, bytes);
    if let Err(error) = &written
        && error.kind() != std::io::ErrorKind::AlreadyExists
    {
        let _ = std::fs::remove_file(path);
    }
    written
}

/// Writes the pin for `host:port` to `pin`, replacing any earlier one.
pub(super) fn write_pin(
    pin: &Path,
    host: IpAddr,
    port: u16,
    host_key: &str,
) -> std::io::Result<()> {
    write_private(pin, pin_line(host, port, host_key).as_bytes())
}

/// The device's carrier key: an Ed25519 key in OpenSSH's format, made once.
pub(super) struct CarrierKey {
    pub path: PathBuf,
    /// `ssh-ed25519 <base64>`, what `ssh-endpoint` authorizes.
    pub public_line: String,
}

const OPENSSH_MAGIC: &[u8] = b"openssh-key-v1\0";
const PEM_BEGIN: &str = "-----BEGIN OPENSSH PRIVATE KEY-----";
const PEM_END: &str = "-----END OPENSSH PRIVATE KEY-----";

fn put_string(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&u32::try_from(bytes.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(bytes);
}

/// The 51-byte `ssh-ed25519` public key blob.
fn public_blob(public: &[u8; 32]) -> Vec<u8> {
    let mut blob = Vec::with_capacity(51);
    put_string(&mut blob, b"ssh-ed25519");
    put_string(&mut blob, public);
    blob
}

/// An unencrypted OpenSSH private key file for `seed` (PROTOCOL.key).
pub(super) fn openssh_private_key(seed: &[u8; 32], check: u32) -> Option<Zeroizing<String>> {
    let pair = ring::signature::Ed25519KeyPair::from_seed_unchecked(seed).ok()?;
    let public: [u8; 32] = ring::signature::KeyPair::public_key(&pair).as_ref().try_into().ok()?;
    let mut private = Zeroizing::new(Vec::with_capacity(160));
    private.extend_from_slice(&check.to_be_bytes());
    private.extend_from_slice(&check.to_be_bytes());
    put_string(&mut private, b"ssh-ed25519");
    put_string(&mut private, &public);
    let mut secret = Zeroizing::new(Vec::with_capacity(64));
    secret.extend_from_slice(seed);
    secret.extend_from_slice(&public);
    put_string(&mut private, &secret);
    put_string(&mut private, b"cmux-carrier");
    let mut pad = 1_u8;
    while private.len() % 8 != 0 {
        private.push(pad);
        pad = pad.wrapping_add(1);
    }
    let mut body = Zeroizing::new(Vec::with_capacity(256));
    body.extend_from_slice(OPENSSH_MAGIC);
    put_string(&mut body, b"none");
    put_string(&mut body, b"none");
    put_string(&mut body, b"");
    body.extend_from_slice(&1_u32.to_be_bytes());
    put_string(&mut body, &public_blob(&public));
    put_string(&mut body, &private);
    let encoded = Zeroizing::new(STANDARD.encode(&*body));
    let mut text = Zeroizing::new(format!("{PEM_BEGIN}\n"));
    for chunk in encoded.as_bytes().chunks(70) {
        text.push_str(std::str::from_utf8(chunk).ok()?);
        text.push('\n');
    }
    text.push_str(PEM_END);
    text.push('\n');
    Some(text)
}

/// Big-endian `uint32` and `string` fields, front to back.
struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, length: usize) -> Option<&'a [u8]> {
        let (value, rest) = self.0.split_at_checked(length)?;
        self.0 = rest;
        Some(value)
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_be_bytes(self.take(4)?.try_into().ok()?))
    }

    fn string(&mut self) -> Option<&'a [u8]> {
        let length = usize::try_from(self.u32()?).ok()?;
        self.take(length)
    }
}

/// The public line of an OpenSSH private key file this module wrote.
pub(super) fn public_line_of(text: &str) -> Option<String> {
    let inner = text.trim().strip_prefix(PEM_BEGIN)?.strip_suffix(PEM_END)?;
    let compact: String = inner.chars().filter(|c| !c.is_whitespace()).collect();
    let body = Zeroizing::new(STANDARD.decode(compact).ok()?);
    let mut reader = Reader(body.strip_prefix(OPENSSH_MAGIC)?);
    let (cipher, kdf, _options) = (reader.string()?, reader.string()?, reader.string()?);
    if cipher != b"none" || kdf != b"none" || reader.u32()? != 1 {
        return None;
    }
    let blob = reader.string()?;
    let key = super::answer::ed25519_host_key(&format!("ssh-ed25519 {}", STANDARD.encode(blob)))?;
    Some(key)
}

impl CarrierKey {
    /// Where the key lives in `state`.
    fn path_in(state: &Path) -> PathBuf {
        state.join("id_ed25519")
    }

    /// `<state>/id_ed25519`, made (0600, never through a symlink) when
    /// there is none. Two processes making it at once keep the first.
    pub(super) fn load_or_create(state: &Path) -> std::io::Result<Self> {
        let path = Self::path_in(state);
        let invalid = || std::io::Error::from(std::io::ErrorKind::InvalidData);
        let read = || -> std::io::Result<Self> {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&path)?;
            use std::os::unix::fs::MetadataExt as _;
            let metadata = file.metadata()?;
            // SAFETY: geteuid has no preconditions.
            let owner = unsafe { libc::geteuid() };
            if metadata.mode() & 0o077 != 0 || metadata.uid() != owner {
                return Err(std::io::ErrorKind::PermissionDenied.into());
            }
            let mut text = Zeroizing::new(String::new());
            std::io::Read::read_to_string(&mut &file, &mut text)?;
            let public_line = public_line_of(&text).ok_or_else(invalid)?;
            Ok(Self { path: path.clone(), public_line })
        };
        match read() {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            other => return other,
        }
        private_dir(state)?;
        let mut seed = Zeroizing::new([0_u8; 32]);
        let mut check = [0_u8; 4];
        getrandom::fill(seed.as_mut()).map_err(|_| invalid())?;
        getrandom::fill(&mut check).map_err(|_| invalid())?;
        let text = openssh_private_key(&seed, u32::from_be_bytes(check)).ok_or_else(invalid)?;
        // A name no other creation uses, so each removes only its own file.
        let made = temporary_beside(state, "id_ed25519")?;
        write_own(&made, text.as_bytes())?;
        // A link, not a rename: one that lost the race keeps the winner's key.
        let linked = std::fs::hard_link(&made, &path);
        let _ = std::fs::remove_file(&made);
        match linked {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        read()
    }
}

/// One answer's ssh route: the candidate, the device's carrier key, its pin,
/// and when the platform last authorized the key.
pub(super) struct SshRoute {
    url: Url,
    machine: String,
    candidate: SshCandidate,
    public_key: String,
    pin: PathBuf,
    source: Arc<dyn CarrierSource>,
    provider: SshProvider,
    /// The deadline of the dial that built the route.
    dial_deadline: Instant,
    /// The dial's permanent refusal, shared by every route it builds.
    refusal: SshRefusal,
    /// Unix seconds; 0 before the first authorization.
    authorized_until: AtomicU64,
    /// One authorization at a time.
    authorizing: tokio::sync::Mutex<()>,
}

impl std::fmt::Debug for SshRoute {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SshRoute").field("url", &self.url.as_str()).finish_non_exhaustive()
    }
}

impl SshRoute {
    /// The route candidate the runner tries.
    pub(super) fn candidate(&self) -> ResolvedRouteCandidate {
        ResolvedRouteCandidate::for_provider(self.url.clone(), &self.provider)
    }

    fn authorized_at(&self, now: u64) -> bool {
        now.saturating_add(KEY_MARGIN_SECS) < self.authorized_until.load(Ordering::Acquire)
    }

    /// When an authorization starting now must be over: the dial's own
    /// deadline while the dial runs, never more than [`AUTHORIZE_TIMEOUT`].
    fn authorize_by(&self, now: Instant) -> Instant {
        let cap = now.checked_add(AUTHORIZE_TIMEOUT).unwrap_or(now);
        if self.dial_deadline > now { self.dial_deadline.min(cap) } else { cap }
    }

    /// Why the platform refused this dial's carrier key for good, if it did.
    pub(super) fn refused(&self) -> Option<&str> {
        self.refusal.get()
    }

    /// Authorizes the carrier key unless an earlier authorization still
    /// holds, and writes the pin from the answer's host key. The answer must
    /// name the candidate's own host, port and user. Waiting for another
    /// authorization's turn and the platform's answer both end by
    /// [`Self::authorize_by`]. Every failure is a link error the reconnect
    /// loop retries, so a resume goes on to the next route; one the platform
    /// means for good is also kept as the dial's [`SshRefusal`], and no
    /// later link asks again.
    pub(super) async fn authorize(&self) -> Result<(), ProviderError> {
        if let Some(reason) = self.refused() {
            return Err(dropped(reason));
        }
        if self.authorized_at(now_unix()) {
            return Ok(());
        }
        let started = Instant::now();
        let by = self.authorize_by(started);
        match tokio::time::timeout_at(by, self.authorize_now()).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) if !error.retryable => {
                self.refusal.set(error.detail);
                Err(dropped(self.refused().unwrap_or("refused")))
            }
            Ok(Err(error)) => Err(ProviderError::Link(LinkError::Transport(format!(
                "carrier ssh key: {}",
                error.detail
            )))),
            Err(_) => Err(ProviderError::Link(LinkError::Transport(format!(
                "carrier ssh key: no authorization within {} ms",
                by.saturating_duration_since(started).as_millis()
            )))),
        }
    }

    async fn authorize_now(&self) -> Result<(), SourceError> {
        let _one = self.authorizing.lock().await;
        // The authorization this one waited for may have been refused for
        // good: then nothing asks again.
        if let Some(reason) = self.refused() {
            return Err(SourceError { retryable: false, detail: reason.to_owned() });
        }
        if self.authorized_at(now_unix()) {
            return Ok(());
        }
        let endpoint = self.source.ssh_endpoint(&self.machine, &self.public_key).await?;
        let candidate = &self.candidate;
        if endpoint.host != candidate.host
            || endpoint.port != candidate.port
            || endpoint.user != candidate.user
        {
            return Err(SourceError::retry("the endpoint names another host than the answer"));
        }
        write_pin(&self.pin, endpoint.host, endpoint.port, &endpoint.host_key).map_err(|e| {
            SourceError::retry(format!("the pin could not be written ({:?})", e.kind()))
        })?;
        self.authorized_until.store(endpoint.expires_at, Ordering::Release);
        Ok(())
    }

    /// One authorization ahead of any failover, in the background: a single
    /// try, bounded as every authorization is.
    pub(super) fn prewarm(self: &Arc<Self>) {
        let route = self.clone();
        tokio::spawn(async move {
            let _ = route.authorize().await;
        });
    }

    /// A link group on this route: each open authorizes the key first.
    pub(super) async fn group(
        self: &Arc<Self>,
        request: ConnectRequest,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        let inner = self.provider.connect(request).await?;
        Ok(Arc::new(SshGroup { route: self.clone(), inner }))
    }
}

/// The link error of a route the platform refused for good.
fn dropped(reason: &str) -> ProviderError {
    ProviderError::Link(LinkError::Transport(format!("carrier ssh route dropped: {reason}")))
}

/// The ssh provider's group, with the carrier key authorized before each
/// link (each one a fresh `ssh` run).
struct SshGroup {
    route: Arc<SshRoute>,
    inner: Arc<dyn LinkGroup>,
}

#[async_trait]
impl LinkGroup for SshGroup {
    fn description(&self) -> &str {
        self.inner.description()
    }
    fn capabilities(&self) -> cmux_remote::provider::ProviderCapabilities {
        self.inner.capabilities()
    }
    fn evidence(&self) -> &cmux_remote::provider::CarrierEvidence {
        self.inner.evidence()
    }
    async fn transport_snapshot(&self) -> cmux_remote::observability::TransportSnapshot {
        self.inner.transport_snapshot().await
    }
    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        self.route.authorize().await?;
        self.inner.open(request).await
    }
    async fn close(&self) -> Result<(), ProviderError> {
        self.inner.close().await
    }
}

#[cfg(test)]
#[path = "ssh_tests.rs"]
mod tests;
