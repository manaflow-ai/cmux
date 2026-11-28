//! The rules of the app's undoable cookie clears (`CookieBackups.swift`, `CookieBackupKeys.swift`,
//! the record types of `WebKitDriver+Cookies.swift`): restore ids, the bound on backups, which
//! backups have expired, the History page's list. The same contract as the browser host's headless
//! backups (cmux-browser-host `cookie_backups.rs`).
//!
//! Stays in Swift: the files and their 0600/0700 modes, ChaChaPoly sealing (CryptoKit), the
//! Keychain item and the DEBUG key file, `SecRandomCopyBytes` (the 16 random bytes of an id), the
//! directory listing and file sizes, and JSON decoding of a decrypted record into the shapes
//! below. The app reads the facts, asks the op, and applies the answer.

use serde::{Deserialize, Serialize};

/// `CookieBackups.restorePrefix`.
pub const RESTORE_PREFIX: &str = "app:";
/// `CookieBackups.defaultMaxBackups`.
pub const DEFAULT_MAX_BACKUPS: usize = 50;
/// `CookieBackups.defaultMaxBytes`.
pub const DEFAULT_MAX_BYTES: usize = 64 * 1024 * 1024;
/// `CookieBackups.magic`: the first bytes of a backup file.
pub const MAGIC: &[u8] = b"CMUXCB1\n";
/// ChaChaPoly's nonce and tag, around the sealed record.
const SEAL_OVERHEAD: usize = 12 + 16;
/// The bundle id the app falls back to when it has none (or an empty one).
pub const DEFAULT_BUNDLE_ID: &str = "com.cmuxterm.app.next";

/// The bundle id to name the backup directory and key after: `bundle_id`, or the default when it
/// is nil or empty (`defaultDirectory`, `KeychainCookieBackupKey.init`).
pub fn bundle_name(bundle_id: Option<&str>) -> &str {
    bundle_id.filter(|id| !id.is_empty()).unwrap_or(DEFAULT_BUNDLE_ID)
}

/// The Keychain service of the backup key (`KeychainCookieBackupKey.service`).
pub fn key_service(bundle_id: Option<&str>) -> String {
    format!("{}.cookie-backup-key", bundle_name(bundle_id))
}

/// `app:<32 hex>` for the 16 random bytes `bytes` (`save`).
pub fn restore_id(bytes: &[u8; 16]) -> String {
    let mut id = String::from(RESTORE_PREFIX);
    for byte in bytes {
        id.push_str(&format!("{byte:02x}"));
    }
    id
}

/// The file name (`<hex>.bin`) of a restore id, or the refusal text (`fileURL`). The hex is 32
/// lowercase hex digits.
pub fn backup_file_name(restore_id: &str) -> Result<String, String> {
    let hex = restore_id.strip_prefix(RESTORE_PREFIX).unwrap_or("");
    if hex.chars().count() == 32
        && hex.chars().all(|c| c.is_ascii_digit() || matches!(c, 'a'..='f'))
    {
        Ok(format!("{hex}.bin"))
    } else {
        Err(format!("{restore_id} is not an app cookie restore id (app:<32 hex>)"))
    }
}

/// The restore id of a backup file named `<stem>.bin`.
pub fn restore_id_of_stem(stem: &str) -> String {
    format!("{RESTORE_PREFIX}{stem}")
}

/// Why a new backup of `plain_bytes` bytes would pass the bound, or None (`full`). `sizes` are
/// the sizes of the backup files now there.
pub fn full(sizes: &[u64], plain_bytes: u64, max_backups: usize, max_bytes: u64) -> Option<String> {
    let used: u64 = sizes.iter().sum();
    let next = plain_bytes + MAGIC.len() as u64 + SEAL_OVERHEAD as u64;
    if sizes.len() < max_backups && used + next <= max_bytes {
        return None;
    }
    let mib = used as f64 / 1_048_576.0;
    Some(format!(
        "cookie backups are full ({} backups, {:.1} MiB); restore a backup with cookies.restore \
         or ask the person to purge backups",
        sizes.len(),
        mib
    ))
}

/// Whether a backed-up cookie (`expires` in seconds since 1970, -1 or absent for a session
/// cookie) has passed its expiry (`CookieBackups.expired`).
pub fn expired(expires: Option<f64>, now: f64) -> bool {
    match expires {
        Some(expires) if expires > 0.0 => expires <= now,
        _ => false,
    }
}

/// A backup file as `pruneExpired` reads it: `cookies` is the `expires` of each cookie of the
/// record, or None when the file does not open (or has no `cookies`).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct PruneEntry {
    pub file: String,
    #[serde(default)]
    pub cookies: Option<Vec<Option<f64>>>,
}

/// The files `pruneExpired` deletes: every readable backup whose cookies all passed their own
/// expiry (a cookie without one keeps the backup; so does an unreadable file, left for the
/// person). A backup of no cookies is deleted (`allSatisfy` of none).
pub fn prune_selection(entries: &[PruneEntry], now: f64) -> Vec<String> {
    entries
        .iter()
        .filter(|entry| {
            entry.cookies.as_ref().is_some_and(|cookies| cookies.iter().all(|e| expired(*e, now)))
        })
        .map(|entry| entry.file.clone())
        .collect()
}

/// A backup file as `summaries` reads it. `record` is None when it does not open (or there is no
/// key); `created_at_ms` is the record's `createdAt` (0 when absent), `modified` the file's date
/// in seconds (`distantPast` when unknown).
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryEntry {
    pub stem: String,
    #[serde(default)]
    pub site: Option<String>,
    #[serde(default)]
    pub created_at_ms: Option<f64>,
    #[serde(default)]
    pub readable: bool,
    #[serde(default)]
    pub modified: f64,
}

/// One backup on the History page's list: never a cookie value (`CookieBackups.Summary`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub restore_id: String,
    /// The host whose cookies were cleared; None when the backup does not open with this Mac's
    /// key (it still counts toward the bound, so the person can delete it).
    pub site: Option<String>,
    /// Seconds since 1970.
    pub created_at: f64,
}

/// Every backup, newest first (`summaries`). An unreadable one is listed with no site and its
/// file's date; the sort is stable.
pub fn summaries(entries: &[SummaryEntry]) -> Vec<Summary> {
    let mut list: Vec<Summary> = entries
        .iter()
        .map(|entry| {
            let restore_id = restore_id_of_stem(&entry.stem);
            if entry.readable {
                Summary {
                    restore_id,
                    site: Some(entry.site.clone().unwrap_or_default()),
                    created_at: entry.created_at_ms.unwrap_or(0.0) / 1000.0,
                }
            } else {
                Summary { restore_id, site: None, created_at: entry.modified }
            }
        })
        .collect();
    list.sort_by(|a, b| b.created_at.total_cmp(&a.created_at));
    list
}

/// One backed-up cookie: every field `HTTPCookie` needs to make it again (`BackedUpCookie`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BackedUpCookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    /// Seconds since 1970; -1 for a session cookie.
    pub expires: f64,
    pub http_only: bool,
    pub secure: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub same_site: Option<String>,
}

/// What one backup file holds, encrypted (`CookieBackupRecord`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CookieBackupRecord {
    pub site: String,
    /// The `BrowserProfileID` UUID of the store the cookies came from.
    pub profile: String,
    /// Milliseconds since 1970.
    pub created_at: f64,
    pub cookies: Vec<BackedUpCookie>,
}

/// The `HTTPCookie` properties a backed-up cookie is made with (`BackedUpCookie.httpCookie`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CookieProperties {
    /// Set only for a persistent cookie (`expires > 0`).
    pub expires: Option<f64>,
    pub secure: bool,
    pub http_only: bool,
    /// `lax` or `strict`; any other `sameSite` sets no policy.
    pub same_site_policy: Option<&'static str>,
}

impl BackedUpCookie {
    /// `httpCookie`: which properties the cookie sets.
    pub fn properties(&self) -> CookieProperties {
        CookieProperties {
            expires: (self.expires > 0.0).then_some(self.expires),
            secure: self.secure,
            http_only: self.http_only,
            same_site_policy: match self.same_site.as_deref().map(str::to_lowercase).as_deref() {
                Some("lax") => Some("lax"),
                Some("strict") => Some("strict"),
                _ => None,
            },
        }
    }
}

/// What `cookies.restore` does with one backed-up cookie.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RestoreAction {
    /// Past its expiry: left out.
    Expired,
    /// The store has a cookie of the same name, domain and path (set since the clear): kept.
    Kept,
    /// Put back.
    Restore,
}

/// The restore plan of `cookies.restore`: per cookie, in order, its action. `existing` are the
/// `(name, domain, path)` of the cookies in the store now. (Swift counts `Restore` only when the
/// cookie makes an `HTTPCookie`; it counts the rest as here.)
pub fn restore_plan(
    cookies: &[BackedUpCookie],
    existing: &[(String, String, String)],
    now: f64,
) -> Vec<RestoreAction> {
    cookies
        .iter()
        .map(|cookie| {
            if cookie.expires > 0.0 && cookie.expires <= now {
                RestoreAction::Expired
            } else if existing.iter().any(|(name, domain, path)| {
                *name == cookie.name && *domain == cookie.domain && *path == cookie.path
            }) {
                RestoreAction::Kept
            } else {
                RestoreAction::Restore
            }
        })
        .collect()
}
