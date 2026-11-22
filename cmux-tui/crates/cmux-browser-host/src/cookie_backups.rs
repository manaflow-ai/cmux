//! Undoable cookie clearing (private data P2; Lawrence via ff, 2026-10-07:
//! every clear is easy to undo, and a backup is deleted only with the
//! person's confirmation). The host's own browsers (headless) keep the
//! cookies a `cookies.clear` deletes in an encrypted backup:
//!
//! - Where: `<state>/cookie-backups/<id>.bin`, mode 0600, in a 0700
//!   directory. `<state>` is `$CMUX_BROWSER_HOST_STATE_DIR`, else
//!   `$XDG_STATE_HOME/cmux/browser-host`, else
//!   `~/.local/state/cmux/browser-host` (Linux) or
//!   `~/Library/Application Support/cmux/browser-host` (macOS).
//! - Encryption: XChaCha20-Poly1305 with a 32-byte key in a separate file,
//!   `<state>/cookie-backup.key` (0600, made once from the OS random
//!   source); a fresh 24-byte nonce per backup; the backup id is the
//!   associated data, so a file renamed to another id does not open. Never
//!   synced, never logged; summaries carry no cookie values.
//! - Key trade-off: the key file sits next to the backups, in the same
//!   directory and readable by the same user. The encryption protects a
//!   backup that was copied away alone (a synced or archived file, a
//!   backup of the backups), NOT against a local attacker who runs as the
//!   same user: that attacker reads the key file too. A key held by the OS
//!   (macOS Keychain, Linux Secret Service) is a later choice for the app's
//!   profile owner (bead cx-pp5), not this host slice: a headless server or
//!   Cloud VM often has no keyring at all.
//! - Retention: until it is restored (`cookies.restore`), the person
//!   deletes it with a confirmation (`browser.cookieBackups.purge`), or every
//!   cookie in it has passed its own expiry (checked lazily at each clear,
//!   restore and listing; no timer). A backup that holds a session cookie
//!   (no expiry) stays until it is restored or purged.
//! - Bound: at most [`MAX_BACKUPS`] backups or [`MAX_BACKUP_BYTES`] of
//!   backup files per state directory, whichever comes first. A clear that
//!   would pass the bound is refused before any cookie is deleted, with an
//!   error that says to restore or purge backups; no backup is ever
//!   dropped to make room (an agent could otherwise push the undo of an
//!   earlier clear out with new clears).
//!
//! The restore id an agent gets is `host:<32 hex>` (128 bits from the OS
//! random source).

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use serde_json::{Value, json};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

/// The prefix of a restore id the host owns (`browser.data.restore` routes
/// by it).
pub const RESTORE_PREFIX: &str = "host:";
const MAGIC: &[u8] = b"CMUXCB1\n";
const KEY_FILE: &str = "cookie-backup.key";
const BACKUPS: &str = "cookie-backups";
const NONCE_LEN: usize = 24;

/// At most this many backups per state directory.
pub const MAX_BACKUPS: usize = 50;
/// At most this many bytes of backup files per state directory.
pub const MAX_BACKUP_BYTES: u64 = 64 * 1024 * 1024;

/// The encrypted cookie backups of one host state directory.
#[derive(Debug)]
pub struct CookieBackups {
    dir: PathBuf,
    max_backups: usize,
    max_bytes: u64,
}

fn random<const N: usize>() -> Result<[u8; N], String> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|e| format!("the OS random source failed: {e}"))?;
    Ok(bytes)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A restore id's file stem, if it is one of ours.
fn stem(restore_id: &str) -> Option<&str> {
    let id = restore_id.strip_prefix(RESTORE_PREFIX)?;
    (id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
        .then_some(id)
}

#[cfg(unix)]
fn create_private(path: &Path) -> io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
}

#[cfg(not(unix))]
fn create_private(path: &Path) -> io::Result<fs::File> {
    fs::OpenOptions::new().write(true).create_new(true).open(path)
}

#[cfg(unix)]
fn private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

#[cfg(not(unix))]
fn private_dir(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)
}

impl CookieBackups {
    /// The backups in `dir` (made 0700 if needed).
    pub fn open(dir: impl Into<PathBuf>) -> io::Result<CookieBackups> {
        let dir = dir.into();
        private_dir(&dir.join(BACKUPS))?;
        private_dir(&dir)?;
        Ok(CookieBackups { dir, max_backups: MAX_BACKUPS, max_bytes: MAX_BACKUP_BYTES })
    }

    /// The same store with other bounds (tests).
    pub fn with_limits(mut self, max_backups: usize, max_bytes: u64) -> CookieBackups {
        self.max_backups = max_backups;
        self.max_bytes = max_bytes;
        self
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The key, made once (a separate 0600 file).
    fn cipher(&self) -> Result<XChaCha20Poly1305, String> {
        let path = self.dir.join(KEY_FILE);
        let mut key = [0u8; 32];
        match fs::File::open(&path) {
            Ok(mut file) => {
                let mut bytes = Vec::new();
                file.read_to_end(&mut bytes).map_err(|e| format!("cookie backup key: {e}"))?;
                if bytes.len() != key.len() {
                    return Err("cookie backup key: the key file is damaged".into());
                }
                key.copy_from_slice(&bytes);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                key = random::<32>()?;
                match create_private(&path) {
                    Ok(mut file) => file
                        .write_all(&key)
                        .and_then(|()| file.sync_all())
                        .map_err(|e| format!("cookie backup key: {e}"))?,
                    // Another call made it first: use that one.
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                        return self.cipher();
                    }
                    Err(error) => return Err(format!("cookie backup key: {error}")),
                }
            }
            Err(error) => return Err(format!("cookie backup key: {error}")),
        }
        Ok(XChaCha20Poly1305::new((&key).into()))
    }

    /// Why one more backup of `plain_len` bytes of JSON does not fit (the
    /// bound), or None. Expired backups are not pruned here.
    pub fn full(&self, plain_len: usize) -> Option<String> {
        let ids = self.ids();
        let used: u64 = ids
            .iter()
            .filter_map(|id| fs::metadata(self.path(stem(id)?)).ok())
            .map(|meta| meta.len())
            .sum();
        // The file: magic, nonce, the sealed JSON and its 16-byte tag.
        let file_len = (MAGIC.len() + NONCE_LEN + plain_len + 16) as u64;
        if ids.len() < self.max_backups && used.saturating_add(file_len) <= self.max_bytes {
            return None;
        }
        Some(format!(
            "cookie backups are full ({} of {} backups, {used} of {} bytes), so nothing was cleared; \
             restore a backup (context.restoreCookies(restoreId)) or ask the person to purge backups \
             (browser.cookieBackups.purge) first",
            ids.len(),
            self.max_backups,
            self.max_bytes,
        ))
    }

    fn path(&self, stem: &str) -> PathBuf {
        self.dir.join(BACKUPS).join(format!("{stem}.bin"))
    }

    /// Writes `record` (`{site, store, createdAt, cookies}`) and returns its
    /// restore id. The file is complete before the id is returned. Refused
    /// (nothing written, nothing dropped) when the store is full.
    pub fn save(&self, record: &Value) -> Result<String, String> {
        let plain = serde_json::to_vec(record).map_err(|e| e.to_string())?;
        if let Some(full) = self.full(plain.len()) {
            return Err(full);
        }
        let cipher = self.cipher()?;
        let stem = hex(&random::<16>()?);
        let nonce = random::<NONCE_LEN>()?;
        let sealed = cipher
            .encrypt(XNonce::from_slice(&nonce), Payload { msg: &plain, aad: stem.as_bytes() })
            .map_err(|_| "cookie backup: encryption failed".to_owned())?;
        let path = self.path(&stem);
        let mut file = create_private(&path).map_err(|e| format!("cookie backup: {e}"))?;
        let written = file
            .write_all(MAGIC)
            .and_then(|()| file.write_all(&nonce))
            .and_then(|()| file.write_all(&sealed))
            .and_then(|()| file.sync_all());
        if let Err(error) = written {
            let _ = fs::remove_file(&path);
            return Err(format!("cookie backup: {error}"));
        }
        Ok(format!("{RESTORE_PREFIX}{stem}"))
    }

    /// The record of `restore_id`.
    pub fn load(&self, restore_id: &str) -> Result<Value, String> {
        let stem = stem(restore_id).ok_or_else(|| format!("{restore_id:?} is not a restore id"))?;
        let bytes = match fs::read(self.path(stem)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(format!(
                    "no cookie backup {restore_id} (it was restored, deleted or expired)"
                ));
            }
            Err(error) => return Err(format!("cookie backup: {error}")),
        };
        let body = bytes
            .strip_prefix(MAGIC)
            .filter(|body| body.len() > NONCE_LEN)
            .ok_or("cookie backup: the file is damaged")?;
        let (nonce, sealed) = body.split_at(NONCE_LEN);
        let plain = self
            .cipher()?
            .decrypt(XNonce::from_slice(nonce), Payload { msg: sealed, aad: stem.as_bytes() })
            .map_err(|_| "cookie backup: the file does not open with this host's key".to_owned())?;
        serde_json::from_slice(&plain).map_err(|e| format!("cookie backup: {e}"))
    }

    pub fn remove(&self, restore_id: &str) -> Result<(), String> {
        let stem = stem(restore_id).ok_or_else(|| format!("{restore_id:?} is not a restore id"))?;
        match fs::remove_file(self.path(stem)) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("cookie backup: {error}")),
        }
    }

    /// The restore ids of every backup.
    pub fn ids(&self) -> Vec<String> {
        let Ok(entries) = fs::read_dir(self.dir.join(BACKUPS)) else { return Vec::new() };
        let mut ids: Vec<String> = entries
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name().into_string().ok()?;
                let id = format!("{RESTORE_PREFIX}{}", name.strip_suffix(".bin")?);
                stem(&id).is_some().then_some(id)
            })
            .collect();
        ids.sort();
        ids
    }

    /// What each backup holds, without a cookie value: `{restoreId, site,
    /// cookies, createdAt}`. Expired backups are removed first.
    pub fn list(&self, now_secs: f64) -> Vec<Value> {
        self.prune_expired(now_secs);
        self.ids()
            .into_iter()
            .filter_map(|id| {
                let record = self.load(&id).ok()?;
                Some(json!({
                    "restoreId": id,
                    "site": record["site"],
                    "cookies": record["cookies"].as_array().map_or(0, Vec::len),
                    "createdAt": record["createdAt"],
                }))
            })
            .collect()
    }

    /// Removes every backup whose cookies have all passed their own expiry
    /// (a session cookie never does); the number removed.
    pub fn prune_expired(&self, now_secs: f64) -> usize {
        let mut removed = 0;
        for id in self.ids() {
            let Ok(record) = self.load(&id) else { continue };
            let cookies = record["cookies"].as_array().cloned().unwrap_or_default();
            if cookies.iter().all(|cookie| expired(cookie, now_secs)) && self.remove(&id).is_ok() {
                removed += 1;
            }
        }
        removed
    }
}

/// Whether a `Storage.getCookies` cookie has passed its own expiry.
pub fn expired(cookie: &Value, now_secs: f64) -> bool {
    cookie["session"] != json!(true)
        && cookie["expires"].as_f64().is_some_and(|expires| expires > 0.0 && expires <= now_secs)
}

/// This machine's host state directory.
pub fn default_dir() -> Option<PathBuf> {
    let var =
        |name: &str| std::env::var_os(name).filter(|value| !value.is_empty()).map(PathBuf::from);
    if let Some(dir) = var("CMUX_BROWSER_HOST_STATE_DIR") {
        return Some(dir);
    }
    if cfg!(target_os = "macos") {
        return var("HOME").map(|home| home.join("Library/Application Support/cmux/browser-host"));
    }
    var("XDG_STATE_HOME")
        .map(|state| state.join("cmux/browser-host"))
        .or_else(|| var("HOME").map(|home| home.join(".local/state/cmux/browser-host")))
}

/// The backups of this process's host state directory, opened once.
pub fn shared() -> Result<Arc<CookieBackups>, String> {
    static SHARED: OnceLock<Result<Arc<CookieBackups>, String>> = OnceLock::new();
    SHARED
        .get_or_init(|| {
            let dir = default_dir().ok_or("no host state directory (HOME is not set)")?;
            CookieBackups::open(&dir)
                .map(Arc::new)
                .map_err(|e| format!("cookie backups in {}: {e}", dir.display()))
        })
        .clone()
}

/// Seconds since the epoch.
pub fn now_secs() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

#[cfg(test)]
#[path = "cookie_backups_tests.rs"]
mod tests;
