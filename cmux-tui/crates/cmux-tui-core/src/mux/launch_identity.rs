//! Launch credentials (plans/cmux-next/identity.md section 2). The session
//! host is the only holder of the launch keys: it mints one credential per
//! terminal into the child's environment and verifies credentials that
//! requests present. Keys live in `<session state>/identity/launch-keys.json`
//! (directory 0700, file 0600) and never leave this process.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use cmux_local_auth::Actor;
use cmux_local_auth::launch_credential::{Claims, LaunchKeys, VerifyError};

use super::*;

/// The environment variable a terminal child receives its credential in.
pub const LAUNCH_CREDENTIAL_ENV: &str = "CMUX_LAUNCH_CREDENTIAL";

const KEY_DIRECTORY: &str = "identity";
const KEY_FILE: &str = "launch-keys.json";

/// The launch keys of one session host.
pub(crate) struct LaunchIdentity {
    /// None only when the system gave no randomness: nothing is minted then,
    /// and nothing verifies (never a guessable key).
    keys: Mutex<Option<LaunchKeys>>,
    #[cfg_attr(not(test), allow(dead_code))]
    path: Option<PathBuf>,
}

/// What a presented credential means for one request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CredentialCheck {
    /// It verified and names a live subject of this session.
    Verified(Actor),
    /// Its key id is unknown (dropped by rotation): treat the request as if
    /// it carried no credential. Secret release refuses this case.
    UnknownKey,
    /// Tampered, malformed, for another session, or for a closed terminal:
    /// refuse the request. The reason is a stable word.
    Refused(&'static str),
}

impl LaunchIdentity {
    /// Load the keys from `directory`, or make and save new ones. A missing
    /// directory (an in-memory session) keeps the keys in memory. A file that
    /// does not parse is replaced: credentials minted under it then have an
    /// unknown key and fall back, they are never accepted.
    pub(crate) fn load(directory: Option<&Path>) -> Self {
        let path = directory.map(|directory| directory.join(KEY_DIRECTORY).join(KEY_FILE));
        let stored = path.as_deref().and_then(read_keys);
        let keys = match stored {
            Some(keys) => Some(keys),
            None => match random_key() {
                Ok(key) => {
                    let keys = LaunchKeys::new(&new_kid(), key);
                    if let Some(path) = path.as_deref()
                        && let Err(error) = write_keys(path, &keys)
                    {
                        eprintln!(
                            "cmux-tui: launch keys were not saved ({error}); they last this run only"
                        );
                    }
                    Some(keys)
                }
                Err(error) => {
                    eprintln!("cmux-tui: no launch keys ({error}); terminals get no credential");
                    None
                }
            },
        };
        Self { keys: Mutex::new(keys), path }
    }

    fn mint(&self, claims: &Claims) -> Option<String> {
        self.keys.lock().unwrap().as_ref()?.mint(claims)
    }

    /// With no keys every credential has an unknown key: it falls back,
    /// it is never accepted.
    fn verify(&self, credential: &str) -> Result<Claims, VerifyError> {
        match self.keys.lock().unwrap().as_ref() {
            Some(keys) => keys.verify(credential),
            None => Err(VerifyError::UnknownKey),
        }
    }

    /// Make a new current key and keep one previous key.
    // `credential.rotate` (slice 3b) is the production caller.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn rotate(&self) -> anyhow::Result<String> {
        let mut keys = self.keys.lock().unwrap();
        let kid = new_kid();
        let key = random_key()?;
        let next = match keys.as_ref() {
            Some(current) => {
                let mut next = current.clone();
                next.rotate(&kid, key);
                next
            }
            None => LaunchKeys::new(&kid, key),
        };
        if let Some(path) = self.path.as_deref() {
            write_keys(path, &next)?;
        }
        *keys = Some(next);
        Ok(kid)
    }
}

impl Mux {
    /// The credential a new terminal's child receives, or None when minting
    /// fails (the terminal then starts without one and its calls are
    /// attributed by pid ancestry or to the user).
    pub(crate) fn mint_terminal_credential(&self, terminal: &TerminalPublicId) -> Option<String> {
        let claims = Claims {
            v: 1,
            host: self.session_public_id().as_str().to_owned(),
            terminal: Some(terminal.as_str().to_owned()),
            acp_session: None,
            agent: None,
            iat: unix_seconds(),
        };
        self.launch_identity.mint(&claims)
    }

    /// Check a credential a request presents. Liveness reads mux state only
    /// (never the registry), so callers run it before `commit_state` takes
    /// its locks.
    pub(crate) fn check_launch_credential(&self, credential: &str) -> CredentialCheck {
        let claims = match self.launch_identity.verify(credential) {
            Ok(claims) => claims,
            Err(VerifyError::UnknownKey) => return CredentialCheck::UnknownKey,
            Err(VerifyError::Malformed) => return CredentialCheck::Refused("credential_malformed"),
            Err(VerifyError::BadMac) => return CredentialCheck::Refused("credential_invalid"),
        };
        if claims.host != self.session_public_id().as_str() {
            return CredentialCheck::Refused("credential_foreign_host");
        }
        let live = match (&claims.terminal, &claims.acp_session) {
            (Some(terminal), None) => TerminalPublicId::parse(terminal.clone())
                .ok()
                .is_some_and(|terminal| self.terminal_resource_surface(&terminal).is_some()),
            // ACP sessions are minted for acpmux (slice 4), which owns their
            // liveness; none is minted yet, so none is live.
            _ => false,
        };
        if !live {
            return CredentialCheck::Refused("credential_closed");
        }
        match Actor::from_claims(&claims) {
            Some(actor) => CredentialCheck::Verified(actor),
            None => CredentialCheck::Refused("credential_malformed"),
        }
    }

    /// The actor of one request. `local` is true on the local Unix socket,
    /// the only transport that may present a launch credential. No
    /// credential (or an empty one, or one with a dropped key) is the local
    /// user; a refused credential refuses the request.
    pub(crate) fn request_actor(
        &self,
        local: bool,
        credential: Option<&str>,
    ) -> Result<Actor, ResourceError> {
        // `validation.invalid` on field `credential`, reason `credential_*`:
        // the request is refused before any owner sees it, never retried
        // as the user.
        let refuse =
            |reason: &'static str| ResourceError::validation_invalid(Some("credential"), reason);
        let Some(credential) = credential.filter(|credential| !credential.is_empty()) else {
            return Ok(Actor::local_user());
        };
        if !local {
            return Err(refuse("credential_not_local"));
        }
        match self.check_launch_credential(credential) {
            CredentialCheck::Verified(actor) => Ok(actor),
            CredentialCheck::UnknownKey => Ok(Actor::local_user()),
            CredentialCheck::Refused(reason) => Err(refuse(reason)),
        }
    }

    /// Rotate the launch keys (local user only; the caller checks).
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn rotate_launch_keys(&self) -> anyhow::Result<String> {
        self.launch_identity.rotate()
    }
}

fn unix_seconds() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_secs()).unwrap_or(0)
}

fn random_key() -> anyhow::Result<[u8; 32]> {
    let mut key = [0u8; 32];
    getrandom::fill(&mut key).map_err(|_| anyhow::anyhow!("launch key randomness"))?;
    Ok(key)
}

fn new_kid() -> String {
    let mut suffix = [0u8; 4];
    let _ = getrandom::fill(&mut suffix);
    let suffix: String = suffix.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("k{}-{suffix}", unix_seconds())
}

fn read_keys(path: &Path) -> Option<LaunchKeys> {
    let bytes = std::fs::read(path).ok()?;
    let keys: LaunchKeys = serde_json::from_slice(&bytes).ok()?;
    keys.is_valid().then_some(keys)
}

/// Write `keys` with 0600 through a temporary file and a rename, in a 0700
/// directory.
fn write_keys(path: &Path, keys: &LaunchKeys) -> std::io::Result<()> {
    let directory = path.parent().ok_or_else(|| std::io::Error::other("no key directory"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(directory)?;
        // A directory left with wider bits is narrowed again.
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(not(unix))]
    std::fs::create_dir_all(directory)?;
    let staged = directory.join(format!("{KEY_FILE}.tmp.{}", std::process::id()));
    // A stale staged file (or a link planted there) is removed, and the new
    // one must be created here: its mode is then ours, never inherited.
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
        file.write_all(&serde_json::to_vec(keys).map_err(std::io::Error::other)?)?;
        file.sync_all()?;
    }
    std::fs::rename(&staged, path)?;
    // Make the rename durable: a lost key file revokes every live credential.
    #[cfg(unix)]
    std::fs::File::open(directory)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
#[path = "launch_identity_tests.rs"]
mod tests;
