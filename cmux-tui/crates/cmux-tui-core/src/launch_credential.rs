//! Launch credentials (plans/cmux-next/identity.md section 2).
//!
//! `cmuxlc1.<kid>.<claims>.<mac>`: `claims` is base64url JSON, `mac` is
//! base64url(HMAC-SHA256(key[kid], "cmuxlc1.<kid>.<claims>")). The session
//! host is the only holder of the keys: it mints a credential into each
//! terminal child's environment and verifies the credentials that requests
//! present. A credential is attribution, not a sandbox: a same-uid process can
//! read another's environment and the key file (identity.md section 1).
//!
//! Keys live in `<session state>/identity/launch-keys.json` (directory 0700,
//! file 0600, owned by this user). A key file that another user owns, that is
//! not a plain file, or that group or others could read is never trusted: the
//! daemon makes new keys, so credentials made with a leaked key never verify.

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_local_auth::frontend_proof::hmac_sha256;
use serde::{Deserialize, Serialize};

/// The environment variable a terminal child receives its credential in.
pub const LAUNCH_CREDENTIAL_ENV: &str = "CMUX_LAUNCH_CREDENTIAL";
/// `identify` advertises it: requests may carry `credential`, and the
/// `credential.*` operations exist. A client sends a credential only then.
pub const LAUNCH_CREDENTIAL_CAPABILITY: &str = "launch-credential-v1";
/// Upper bound on a presented credential; longer input is refused.
pub const MAX_CREDENTIAL_BYTES: usize = 2048;
const PREFIX: &str = "cmuxlc1";
const KEY_BYTES: usize = 32;
const KEY_DIRECTORY: &str = "identity";
const KEY_FILE: &str = "launch-keys.json";
/// The longest ACP session or agent id a credential names.
const MAX_SUBJECT_BYTES: usize = 128;

/// A credential a request carries in its envelope. Its value never appears in
/// `Debug` output, and the envelope never serializes it.
#[derive(Clone, PartialEq, Eq)]
pub struct PresentedCredential(String);

impl PresentedCredential {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for PresentedCredential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("PresentedCredential(<redacted>)")
    }
}

impl<'de> Deserialize<'de> for PresentedCredential {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        if value.is_empty() || value.len() > MAX_CREDENTIAL_BYTES {
            return Err(serde::de::Error::custom(format!(
                "credential must have 1 to {MAX_CREDENTIAL_BYTES} bytes"
            )));
        }
        Ok(Self(value))
    }
}

/// What a launch credential says. Exactly one of `terminal` and
/// `acp_session` is set.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Claims {
    pub v: u8,
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acp_session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    pub iat: u64,
}

impl Claims {
    fn valid_shape(&self) -> bool {
        self.v == 1
            && !self.host.is_empty()
            && (self.terminal.is_some() != self.acp_session.is_some())
            && self.terminal.as_deref().is_none_or(valid_subject)
            && self.acp_session.as_deref().is_none_or(valid_subject)
            && self.agent.as_deref().is_none_or(valid_subject)
    }
}

/// An ACP session or agent id a credential may name: 1 to 128 bytes of
/// `[A-Za-z0-9._-]`, so it can never break the stored actor form.
pub(crate) fn valid_subject(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_SUBJECT_BYTES
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// Why a credential did not verify.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum VerifyError {
    /// Not a cmuxlc1 credential, or its claims do not parse.
    Malformed,
    /// Its key id is not known (dropped by rotation): the request counts as
    /// if it carried no credential.
    UnknownKey,
    /// The MAC does not match: tampered or forged.
    BadMac,
}

#[derive(Clone)]
struct LaunchKeys {
    current: String,
    keys: BTreeMap<String, [u8; KEY_BYTES]>,
}

/// The key file's JSON form: `{current: kid, keys: {kid: base64url}}`.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredKeys {
    current: String,
    keys: BTreeMap<String, String>,
}

impl LaunchKeys {
    fn fresh() -> anyhow::Result<Self> {
        let mut keys = BTreeMap::new();
        let kid = new_kid()?;
        keys.insert(kid.clone(), random_key()?);
        Ok(Self { current: kid, keys })
    }

    /// A new current key; only the previous current key stays besides it.
    fn rotated(&self) -> anyhow::Result<Self> {
        let mut keys = BTreeMap::new();
        if let Some(previous) = self.keys.get(&self.current) {
            keys.insert(self.current.clone(), *previous);
        }
        let kid = new_kid()?;
        keys.insert(kid.clone(), random_key()?);
        Ok(Self { current: kid, keys })
    }

    fn from_stored(stored: StoredKeys) -> Option<Self> {
        let mut keys = BTreeMap::new();
        for (kid, key) in stored.keys {
            let key: [u8; KEY_BYTES] = URL_SAFE_NO_PAD.decode(key).ok()?.try_into().ok()?;
            if !valid_kid(&kid) || key == [0; KEY_BYTES] {
                return None;
            }
            keys.insert(kid, key);
        }
        keys.contains_key(&stored.current).then_some(Self { current: stored.current, keys })
    }

    fn stored(&self) -> StoredKeys {
        StoredKeys {
            current: self.current.clone(),
            keys: self
                .keys
                .iter()
                .map(|(kid, key)| (kid.clone(), URL_SAFE_NO_PAD.encode(key)))
                .collect(),
        }
    }

    fn mint(&self, claims: &Claims) -> Option<String> {
        if !claims.valid_shape() {
            return None;
        }
        let key = self.keys.get(&self.current)?;
        let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).ok()?);
        let signed = format!("{PREFIX}.{}.{body}", self.current);
        let mac = URL_SAFE_NO_PAD.encode(hmac_sha256(key, signed.as_bytes()));
        Some(format!("{signed}.{mac}"))
    }

    fn verify(&self, credential: &str) -> Result<Claims, VerifyError> {
        if credential.len() > MAX_CREDENTIAL_BYTES {
            return Err(VerifyError::Malformed);
        }
        let mut parts = credential.split('.');
        let (Some(PREFIX), Some(kid), Some(body), Some(tag), None) =
            (parts.next(), parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(VerifyError::Malformed);
        };
        if !valid_kid(kid) || body.is_empty() || tag.is_empty() {
            return Err(VerifyError::Malformed);
        }
        let Some(key) = self.keys.get(kid) else { return Err(VerifyError::UnknownKey) };
        let signed = &credential[..PREFIX.len() + 1 + kid.len() + 1 + body.len()];
        let expected = URL_SAFE_NO_PAD.encode(hmac_sha256(key, signed.as_bytes()));
        if !cmux_local_auth::tokens_match(tag, &expected) {
            return Err(VerifyError::BadMac);
        }
        let json = URL_SAFE_NO_PAD.decode(body).map_err(|_| VerifyError::Malformed)?;
        let claims: Claims = serde_json::from_slice(&json).map_err(|_| VerifyError::Malformed)?;
        claims.valid_shape().then_some(claims).ok_or(VerifyError::Malformed)
    }
}

/// The launch keys of one session host.
pub(crate) struct LaunchIdentity {
    /// None only when the system gave no randomness: nothing is minted then
    /// and nothing verifies (never a guessable key).
    keys: Mutex<Option<LaunchKeys>>,
    /// None for an in-memory session: its keys last this process only.
    path: Option<PathBuf>,
    /// The idempotency key and key id of the last rotation, so a retry of the
    /// same request rotates once.
    last_rotation: Mutex<Option<(String, String)>>,
}

impl LaunchIdentity {
    /// Load the keys of the session whose state lives in `directory`, or
    /// make and save new ones (see the module docs for the trust rule).
    pub(crate) fn load(directory: Option<&Path>) -> Self {
        let path = directory.map(|directory| directory.join(KEY_DIRECTORY).join(KEY_FILE));
        let stored = path.as_deref().and_then(|path| match read_trusted(path) {
            Ok(keys) => keys,
            Err(reason) => {
                eprintln!("cmux-tui: launch key file not trusted ({reason}); making new keys");
                None
            }
        });
        let keys = stored.or_else(|| match LaunchKeys::fresh() {
            Ok(keys) => {
                if let Some(path) = path.as_deref()
                    && let Err(error) = write_keys(path, &keys)
                {
                    eprintln!("cmux-tui: launch keys not saved ({error}); they last this run only");
                }
                Some(keys)
            }
            Err(error) => {
                eprintln!("cmux-tui: no launch keys ({error}); terminals get no credential");
                None
            }
        });
        Self { keys: Mutex::new(keys), path, last_rotation: Mutex::new(None) }
    }

    pub(crate) fn mint(&self, claims: &Claims) -> Option<String> {
        self.keys.lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_ref()?.mint(claims)
    }

    /// With no keys every credential has an unknown key.
    pub(crate) fn verify(&self, credential: &str) -> Result<Claims, VerifyError> {
        match self.keys.lock().unwrap_or_else(std::sync::PoisonError::into_inner).as_ref() {
            Some(keys) => keys.verify(credential),
            None => Err(VerifyError::UnknownKey),
        }
    }

    /// Make a new current key, keep one previous key, save both. Returns the
    /// new key id and whether `idempotency_key` repeats the last rotation.
    pub(crate) fn rotate(&self, idempotency_key: &str) -> anyhow::Result<(String, bool)> {
        let mut last = self.last_rotation.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some((key, kid)) = last.as_ref()
            && key == idempotency_key
        {
            return Ok((kid.clone(), true));
        }
        let mut keys = self.keys.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let next = match keys.as_ref() {
            Some(current) => current.rotated()?,
            None => LaunchKeys::fresh()?,
        };
        if let Some(path) = self.path.as_deref() {
            write_keys(path, &next)?;
        }
        let kid = next.current.clone();
        *keys = Some(next);
        *last = Some((idempotency_key.to_string(), kid.clone()));
        Ok((kid, false))
    }
}

/// The stored keys when the file exists and may be trusted; `Ok(None)` when
/// there is no file; `Err` names why an existing file is not trusted.
fn read_trusted(path: &Path) -> Result<Option<LaunchKeys>, &'static str> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("unreadable"),
    };
    if !metadata.file_type().is_file() {
        return Err("not a plain file");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != crate::platform::effective_uid() {
            return Err("owned by another user");
        }
        if metadata.mode() & 0o077 != 0 {
            return Err("readable by group or others");
        }
    }
    let bytes = std::fs::read(path).map_err(|_| "unreadable")?;
    let stored: StoredKeys = serde_json::from_slice(&bytes).map_err(|_| "does not parse")?;
    LaunchKeys::from_stored(stored).map(Some).ok_or("invalid keys")
}

/// Write `keys` through a staged 0600 file and a rename, in a 0700
/// directory this user owns. A rename replaces a planted link or file.
fn write_keys(path: &Path, keys: &LaunchKeys) -> std::io::Result<()> {
    let directory = path.parent().ok_or_else(|| std::io::Error::other("no key directory"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt};
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(directory)?;
        let metadata = std::fs::symlink_metadata(directory)?;
        if !metadata.is_dir() || metadata.uid() != crate::platform::effective_uid() {
            return Err(std::io::Error::other("the key directory is not this user's"));
        }
    }
    #[cfg(not(unix))]
    std::fs::create_dir_all(directory)?;
    crate::platform::restrict_directory(directory)?;
    let staged = directory.join(format!("{KEY_FILE}.tmp.{}", std::process::id()));
    match std::fs::remove_file(&staged) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&staged)?;
        crate::platform::restrict_file(&staged)?;
        file.write_all(&serde_json::to_vec(&keys.stored()).map_err(std::io::Error::other)?)?;
        file.sync_all()?;
    }
    std::fs::rename(&staged, path)?;
    // A lost key file revokes every live credential: make the rename durable.
    crate::platform::sync_directory(directory)
}

fn random_key() -> anyhow::Result<[u8; KEY_BYTES]> {
    let mut key = [0u8; KEY_BYTES];
    getrandom::fill(&mut key).map_err(|_| anyhow::anyhow!("launch key randomness"))?;
    anyhow::ensure!(key != [0; KEY_BYTES], "launch key randomness gave zeros");
    Ok(key)
}

fn new_kid() -> anyhow::Result<String> {
    let mut suffix = [0u8; 6];
    getrandom::fill(&mut suffix).map_err(|_| anyhow::anyhow!("launch key id randomness"))?;
    Ok(format!("k{}", URL_SAFE_NO_PAD.encode(suffix)))
}

fn valid_kid(kid: &str) -> bool {
    !kid.is_empty()
        && kid.len() <= 32
        && kid.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}
