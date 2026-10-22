//! Per-peer trust records and the audit log for requests from other machines.
//!
//! Each machine keeps its own record of what every paired peer may do here.
//! Records are written only on this machine (never by the peer and never from
//! the device registry), and a peer without a record gets nothing. See
//! `docs/multi-machine-sessions.md#per-host-trust`.
//!
//! Nothing calls [`PeerTrustBook::admit`] from a remote method yet; this
//! module is the local authority that `machine.session.request` will consult.

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::secure_directory::{DirectoryAccess, ensure_secure_directory};

/// Trust records, relative to the remote state root.
pub const PEER_TRUST_FILE: &str = "peer-trust.json";
/// Append-only JSON Lines audit log, relative to the remote state root.
pub const PEER_AUDIT_FILE: &str = "peer-audit.jsonl";

const BOOK_VERSION: u32 = 1;
const MAX_PEERS: usize = 256;
const MAX_FOLDERS: usize = 64;
const MAX_BOOK_BYTES: u64 = 1024 * 1024;
const MAX_AUDIT_LINE_BYTES: usize = 8 * 1024;
const MAX_AUDIT_FIELD_BYTES: usize = 1024;
/// The audit log rotates to `peer-audit.jsonl.1` past this size.
const MAX_AUDIT_FILE_BYTES: u64 = 4 * 1024 * 1024;
const FINGERPRINT_LEN: usize = 22;

/// What a peer may do on this machine. There is deliberately no shell tier:
/// opening a terminal for a peer needs its own design and security review.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TrustTier {
    /// The peer may only see that this machine exists.
    None,
    /// Each session request waits for the user's approval on this machine.
    Ask,
    /// Session requests for allowed agents in allowed folders start without asking.
    Folders,
}

/// Agents a peer may ask for. A closed set: the launcher is always this
/// machine's own, so a peer never supplies a command.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PeerAgent {
    Claude,
    Codex,
    Opencode,
    Pi,
}

impl PeerAgent {
    pub const ALL: [Self; 4] = [Self::Claude, Self::Codex, Self::Opencode, Self::Pi];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Opencode => "opencode",
            Self::Pi => "pi",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|agent| agent.as_str() == value)
    }
}

/// One peer's grant on this machine, keyed by the peer's device fingerprint.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerTrust {
    pub fingerprint: String,
    pub tier: TrustTier,
    /// Absolute folders. A request's working directory must resolve inside one.
    #[serde(default)]
    pub folders: Vec<PathBuf>,
    #[serde(default)]
    pub agents: Vec<PeerAgent>,
    #[serde(default)]
    pub expires_at_unix: Option<u64>,
    pub updated_at_unix: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RefuseReason {
    /// No record, or the record's tier is `none`.
    NoGrant,
    Expired,
    AgentNotAllowed,
    /// The working directory is missing or resolves outside every allowed folder.
    FolderNotAllowed,
}

/// A decision on a session request. Admit and Ask carry the resolved working
/// directory; launch there, not in the path the peer sent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Admission {
    Admit(PathBuf),
    /// Allowed only after the user approves on this machine.
    Ask(PathBuf),
    Refuse(RefuseReason),
}

#[derive(Debug)]
pub enum PeerTrustError {
    Io(io::Error),
    Json(serde_json::Error),
    Invalid(&'static str),
}

impl std::fmt::Display for PeerTrustError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "peer trust I/O failed: {error}"),
            Self::Json(error) => write!(formatter, "peer trust state is invalid: {error}"),
            Self::Invalid(reason) => formatter.write_str(reason),
        }
    }
}

impl std::error::Error for PeerTrustError {}

impl From<io::Error> for PeerTrustError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PersistedBook {
    version: u32,
    #[serde(default)]
    peers: Vec<PeerTrust>,
}

/// All trust records on this machine.
#[derive(Clone, Debug, Default)]
pub struct PeerTrustBook {
    peers: Vec<PeerTrust>,
}

impl PeerTrustBook {
    /// Loads `state_root/peer-trust.json`. A missing file is an empty book.
    pub fn load(state_root: &Path) -> Result<Self, PeerTrustError> {
        let path = state_root.join(PEER_TRUST_FILE);
        let bytes = match read_owner_file(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(error) => return Err(error.into()),
        };
        let persisted: PersistedBook =
            serde_json::from_slice(&bytes).map_err(PeerTrustError::Json)?;
        if persisted.version != BOOK_VERSION {
            return Err(PeerTrustError::Invalid("unsupported peer trust state version"));
        }
        let mut book = Self::default();
        for peer in persisted.peers {
            book.insert(peer)?;
        }
        Ok(book)
    }

    /// Loads the book, applies `change` and saves it, holding an exclusive
    /// lock so concurrent writers don't lose each other's updates.
    pub fn update<T>(
        state_root: &Path,
        change: impl FnOnce(&mut Self) -> Result<T, PeerTrustError>,
    ) -> Result<T, PeerTrustError> {
        ensure_secure_directory(state_root, DirectoryAccess::ManagedOwnerOnly)?;
        let _lock = crate::owner_lock::OwnerFileLock::acquire(
            &state_root.join(format!("{PEER_TRUST_FILE}.lock")),
        )?;
        let mut book = Self::load(state_root)?;
        let value = change(&mut book)?;
        book.save(state_root)?;
        Ok(value)
    }

    /// Writes the book atomically as an owner-only file.
    pub fn save(&self, state_root: &Path) -> Result<(), PeerTrustError> {
        ensure_secure_directory(state_root, DirectoryAccess::ManagedOwnerOnly)?;
        let persisted = PersistedBook { version: BOOK_VERSION, peers: self.peers.clone() };
        let data = serde_json::to_vec_pretty(&persisted).map_err(PeerTrustError::Json)?;
        let path = state_root.join(PEER_TRUST_FILE);
        let mut suffix = [0u8; 8];
        getrandom::fill(&mut suffix).map_err(|error| io::Error::other(error.to_string()))?;
        let temporary = state_root.join(format!(
            ".{PEER_TRUST_FILE}.tmp-{}-{}",
            std::process::id(),
            u64::from_le_bytes(suffix)
        ));
        let result = (|| -> io::Result<()> {
            let mut file = owner_only_options().write(true).create_new(true).open(&temporary)?;
            file.write_all(&data)?;
            file.sync_all()?;
            fs::rename(&temporary, &path)?;
            #[cfg(unix)]
            File::open(state_root)?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        Ok(result?)
    }

    pub fn peers(&self) -> &[PeerTrust] {
        &self.peers
    }

    pub fn get(&self, fingerprint: &str) -> Option<&PeerTrust> {
        self.peers.iter().find(|peer| peer.fingerprint == fingerprint)
    }

    /// Adds or replaces a peer's grant. Folders are resolved through symlinks
    /// and stored resolved; each must exist and must not be the filesystem
    /// root, the home folder or one of its ancestors.
    pub fn set(&mut self, mut peer: PeerTrust) -> Result<(), PeerTrustError> {
        for folder in &mut peer.folders {
            *folder = fs::canonicalize(&*folder)
                .ok()
                .filter(|resolved| resolved.is_dir())
                .ok_or(PeerTrustError::Invalid("allowed folders must be existing folders"))?;
        }
        self.insert(peer)
    }

    fn insert(&mut self, peer: PeerTrust) -> Result<(), PeerTrustError> {
        validate_fingerprint(&peer.fingerprint)?;
        if peer.folders.len() > MAX_FOLDERS {
            return Err(PeerTrustError::Invalid("too many allowed folders"));
        }
        for folder in &peer.folders {
            validate_folder(folder)?;
        }
        if let Some(existing) =
            self.peers.iter_mut().find(|existing| existing.fingerprint == peer.fingerprint)
        {
            *existing = peer;
        } else if self.peers.len() >= MAX_PEERS {
            return Err(PeerTrustError::Invalid("too many peer trust records"));
        } else {
            self.peers.push(peer);
        }
        Ok(())
    }

    /// Removes a peer's grant. Returns whether one existed.
    pub fn forget(&mut self, fingerprint: &str) -> bool {
        let before = self.peers.len();
        self.peers.retain(|peer| peer.fingerprint != fingerprint);
        self.peers.len() != before
    }

    /// Decides a session request from `fingerprint` for `agent` in `cwd`.
    ///
    /// The working directory is resolved through symlinks, so a link inside
    /// an allowed folder can't lead out of it. A stored folder that no longer
    /// resolves to itself (it was replaced by a symlink) admits nothing.
    pub fn admit(
        &self,
        fingerprint: &str,
        agent: PeerAgent,
        cwd: &Path,
        now_unix: u64,
    ) -> Admission {
        let Some(peer) = self.get(fingerprint) else {
            return Admission::Refuse(RefuseReason::NoGrant);
        };
        if peer.tier == TrustTier::None {
            return Admission::Refuse(RefuseReason::NoGrant);
        }
        if peer.expires_at_unix.is_some_and(|expires| now_unix >= expires) {
            return Admission::Refuse(RefuseReason::Expired);
        }
        if !peer.agents.contains(&agent) {
            return Admission::Refuse(RefuseReason::AgentNotAllowed);
        }
        let Ok(cwd) = fs::canonicalize(cwd) else {
            return Admission::Refuse(RefuseReason::FolderNotAllowed);
        };
        let inside = peer.folders.iter().any(|folder| {
            cwd.starts_with(folder)
                && fs::canonicalize(folder).is_ok_and(|resolved| &resolved == folder)
        });
        if !inside {
            return Admission::Refuse(RefuseReason::FolderNotAllowed);
        }
        match peer.tier {
            TrustTier::Folders => Admission::Admit(cwd),
            TrustTier::Ask => Admission::Ask(cwd),
            TrustTier::None => Admission::Refuse(RefuseReason::NoGrant),
        }
    }
}

fn validate_fingerprint(fingerprint: &str) -> Result<(), PeerTrustError> {
    let valid = fingerprint.len() == FINGERPRINT_LEN
        && fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
    if valid { Ok(()) } else { Err(PeerTrustError::Invalid("invalid peer fingerprint")) }
}

fn validate_folder(folder: &Path) -> Result<(), PeerTrustError> {
    if !folder.is_absolute() {
        return Err(PeerTrustError::Invalid("allowed folders must be absolute paths"));
    }
    if !folder.components().any(|component| matches!(component, Component::Normal(_))) {
        return Err(PeerTrustError::Invalid("the filesystem root can't be an allowed folder"));
    }
    if folder.components().any(|component| matches!(component, Component::ParentDir)) {
        return Err(PeerTrustError::Invalid("allowed folders can't contain '..'"));
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let home_resolved = home.as_deref().and_then(|home| fs::canonicalize(home).ok());
    if home.iter().chain(home_resolved.iter()).any(|home| home.starts_with(folder)) {
        return Err(PeerTrustError::Invalid(
            "the home folder or a folder above it can't be an allowed folder",
        ));
    }
    Ok(())
}

/// The outcome recorded for one request.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "decision", content = "reason")]
pub enum AuditDecision {
    Admitted,
    Asked,
    Approved,
    Denied,
    Refused(RefuseReason),
}

impl From<&Admission> for AuditDecision {
    fn from(admission: &Admission) -> Self {
        match admission {
            Admission::Admit(_) => Self::Admitted,
            Admission::Ask(_) => Self::Asked,
            Admission::Refuse(reason) => Self::Refused(*reason),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditEntry {
    pub at_unix: u64,
    pub peer: String,
    /// The request's idempotency key, so an approval or denial can be
    /// matched to the request that asked.
    #[serde(default)]
    pub request_id: Option<String>,
    pub method: String,
    #[serde(default)]
    pub agent: Option<PeerAgent>,
    #[serde(default)]
    pub cwd: Option<PathBuf>,
    /// A peer-supplied field was cut to fit the line limit.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub truncated: bool,
    #[serde(flatten)]
    pub decision: AuditDecision,
}

/// Appends one entry to `state_root/peer-audit.jsonl` (owner-only). Fields a
/// peer controls are cut to fit instead of dropping the entry, so every
/// request leaves a line. The log rotates to `peer-audit.jsonl.1` once it
/// passes 4 MiB.
pub fn append_audit(state_root: &Path, entry: &AuditEntry) -> Result<(), PeerTrustError> {
    validate_fingerprint(&entry.peer)?;
    let mut entry = entry.clone();
    let mut line = serde_json::to_vec(&entry).map_err(PeerTrustError::Json)?;
    if line.len() >= MAX_AUDIT_LINE_BYTES {
        entry.truncated = true;
        entry.method = truncate(&entry.method);
        entry.request_id = entry.request_id.as_deref().map(truncate);
        entry.cwd = entry.cwd.as_deref().map(|cwd| PathBuf::from(truncate(&cwd.to_string_lossy())));
        line = serde_json::to_vec(&entry).map_err(PeerTrustError::Json)?;
    }
    line.push(b'\n');
    ensure_secure_directory(state_root, DirectoryAccess::ManagedOwnerOnly)?;
    let path = state_root.join(PEER_AUDIT_FILE);
    if fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.len() > MAX_AUDIT_FILE_BYTES) {
        fs::rename(&path, state_root.join(format!("{PEER_AUDIT_FILE}.1")))?;
    }
    let mut options = owner_only_options();
    options.append(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let mut file = options.open(&path)?;
    check_owner_file(&file)?;
    file.write_all(&line)?;
    file.sync_data()?;
    Ok(())
}

fn truncate(value: &str) -> String {
    if value.len() <= MAX_AUDIT_FIELD_BYTES {
        return value.to_owned();
    }
    let mut end = MAX_AUDIT_FIELD_BYTES;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

/// Reads the newest `limit` audit entries, oldest first. Unreadable lines are skipped.
pub fn read_audit(state_root: &Path, limit: usize) -> Result<Vec<AuditEntry>, PeerTrustError> {
    let file = match open_owner_file(&state_root.join(PEER_AUDIT_FILE)) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    let mut entries = std::collections::VecDeque::with_capacity(limit.min(1024));
    let mut reader = BufReader::new(file);
    let mut line = Vec::with_capacity(1024);
    loop {
        line.clear();
        // Read at most one line limit at a time, so a file without newlines
        // can't make this hold the whole log in memory.
        let read =
            (&mut reader).take(MAX_AUDIT_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line)?;
        if read == 0 {
            break;
        }
        if line.last() != Some(&b'\n') && line.len() > MAX_AUDIT_LINE_BYTES {
            skip_rest_of_line(&mut reader)?;
            continue;
        }
        let Ok(entry) = serde_json::from_slice::<AuditEntry>(line.trim_ascii_end()) else {
            continue;
        };
        if entries.len() == limit {
            entries.pop_front();
        }
        if limit > 0 {
            entries.push_back(entry);
        }
    }
    Ok(entries.into())
}

fn skip_rest_of_line(reader: &mut impl BufRead) -> io::Result<()> {
    loop {
        let buffer = reader.fill_buf()?;
        if buffer.is_empty() {
            return Ok(());
        }
        match buffer.iter().position(|byte| *byte == b'\n') {
            Some(index) => {
                reader.consume(index + 1);
                return Ok(());
            }
            None => {
                let length = buffer.len();
                reader.consume(length);
            }
        }
    }
}

fn owner_only_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    options
}

/// Opens a state file without following a final symlink and requires it to
/// be a regular file this user owns with no group or other access.
fn open_owner_file(path: &Path) -> io::Result<File> {
    let file = {
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
        }
        options.open(path)?
    };
    check_owner_file(&file)?;
    Ok(file)
}

/// Requires an open state file to be a regular file this user owns with no
/// group or other access.
fn check_owner_file(file: &File) -> io::Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "state path is not a file"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "state file must be owner-only and owned by this user",
            ));
        }
    }
    Ok(())
}

fn read_owner_file(path: &Path) -> io::Result<Vec<u8>> {
    let file = open_owner_file(path)?;
    let mut bytes = Vec::new();
    file.take(MAX_BOOK_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_BOOK_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "peer trust state is too large"));
    }
    Ok(bytes)
}
