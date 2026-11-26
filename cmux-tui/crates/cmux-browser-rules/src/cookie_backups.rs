//! The rules of the app's undoable cookie clears (`CookieBackups`), out of the app's
//! CmuxNextBrowserAutomation Swift: the restore id and its file name, the bound a new backup
//! must stay inside, which backups have expired and the History page's list order.
//!
//! The contract (the same as the browser host's headless backups, cmux-browser-host
//! `cookie_backups.rs`): a backup lives until it is restored, the person deletes it, or every
//! cookie in it has passed its own expiry (a session cookie keeps it); at most
//! [`DEFAULT_MAX_BACKUPS`] backups or [`DEFAULT_MAX_BYTES`] of files, and a clear that would pass
//! that is refused before any cookie is deleted (no older backup is dropped to make room).
//!
//! What stays in Swift: the files (`<Application Support>/<bundle id>/CookieBackups/<32
//! hex>.bin`, 0600 in a 0700 directory), the random id bytes (`SecRandomCopyBytes`), the
//! ChaChaPoly sealing with the restore id as associated data, and the key
//! (`CookieBackupKeySource`: the Keychain item, or the DEBUG key file). Those are system calls and
//! crypto the app owns; none of them is a decision.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The prefix of an app restore id (`app:<32 hex>`).
pub const RESTORE_PREFIX: &str = "app:";
/// The most backups kept at once.
pub const DEFAULT_MAX_BACKUPS: usize = 50;
/// The most bytes of backup files kept at once.
pub const DEFAULT_MAX_BYTES: u64 = 64 * 1024 * 1024;
/// The bytes a backup file adds to its sealed record: the magic (`CMUXCB1\n`), the ChaChaPoly
/// nonce (12) and tag (16).
pub const FILE_OVERHEAD: u64 = 8 + 12 + 16;

/// `CookieBackups.full(plainBytes:)`: why a new backup of `plain_bytes` bytes would pass the
/// bound, given the sizes of the backup files there are; `None` when it fits.
///
/// ```
/// use cmux_browser_rules::cookie_backups::full;
/// assert_eq!(full(&[100], 10, 50, 1024), None);
/// assert!(full(&[1_048_576], 10, 50, 1_048_576).unwrap().starts_with("cookie backups are full (1 backups, 1.0 MiB)"));
/// ```
pub fn full(
    file_sizes: &[u64],
    plain_bytes: u64,
    max_backups: usize,
    max_bytes: u64,
) -> Option<String> {
    let used: u64 = file_sizes.iter().sum();
    let next = plain_bytes + FILE_OVERHEAD;
    if file_sizes.len() < max_backups && used + next <= max_bytes {
        return None;
    }
    // Display only: the MiB are rounded to one decimal.
    #[allow(clippy::cast_precision_loss)]
    let mib = used as f64 / 1_048_576.0;
    Some(format!(
        "cookie backups are full ({} backups, {mib:.1} MiB); restore a backup with \
         cookies.restore or ask the person to purge backups",
        file_sizes.len()
    ))
}

/// The restore id of the backup file `<hex>.bin`.
pub fn restore_id(hex: &str) -> String {
    format!("{RESTORE_PREFIX}{hex}")
}

/// `CookieBackups.fileURL`: the 32 lowercase hex digits naming the file of `restore_id`, or the
/// error (protocol text) for an id that is not an app restore id.
///
/// ```
/// use cmux_browser_rules::cookie_backups::file_hex;
/// let hex = "0123456789abcdef0123456789abcdef";
/// assert_eq!(file_hex(&format!("app:{hex}")), Ok(hex));
/// assert!(file_hex("app:0123456789ABCDEF0123456789ABCDEF").is_err());
/// ```
pub fn file_hex(restore_id: &str) -> Result<&str, String> {
    let hex = restore_id.strip_prefix(RESTORE_PREFIX).unwrap_or("");
    if hex.chars().count() == 32 && hex.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        Ok(hex)
    } else {
        Err(format!("{restore_id} is not an app cookie restore id (app:<32 hex>)"))
    }
}

/// `NSNumber.doubleValue` of a JSON value `JSONSerialization` made: numbers, and booleans
/// (they are `NSNumber`s too); `None` for anything else.
fn number(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(number) => number.as_f64(),
        Value::Bool(flag) => Some(if *flag { 1.0 } else { 0.0 }),
        _ => None,
    }
}

/// `CookieBackups.expired`: whether a backed-up cookie (`expires` in seconds since 1970, -1 for a
/// session cookie) has passed its expiry at `now`.
///
/// ```
/// use cmux_browser_rules::cookie_backups::expired;
/// use serde_json::json;
/// assert!(expired(&json!({"expires": 10}), 10.0));
/// assert!(!expired(&json!({"expires": -1}), 10.0));
/// assert!(!expired(&json!({}), 10.0));
/// ```
pub fn expired(cookie: &Value, now: f64) -> bool {
    match number(cookie.get("expires")) {
        Some(expires) if expires > 0.0 => expires <= now,
        _ => false,
    }
}

/// `CookieBackups.pruneExpired`'s test of one opened backup record: `Some(true)` when every
/// cookie in it passed its expiry (the backup is deleted; a backup of no cookies is too),
/// `None` when the record has no list of cookie objects (it is left for the person).
pub fn record_expired(record: &Value, now: f64) -> Option<bool> {
    let cookies = record.get("cookies")?.as_array()?;
    if !cookies.iter().all(Value::is_object) {
        return None;
    }
    Some(cookies.iter().all(|cookie| expired(cookie, now)))
}

/// One backup on the History page's list (`CookieBackups.Summary`): never a cookie value.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub restore_id: String,
    /// The host whose cookies were cleared; `None` when the backup does not open with this
    /// Mac's key (it still counts toward the bound, so the person can delete it).
    pub site: Option<String>,
    /// Seconds since 1970.
    pub created_at: f64,
}

/// A backup file as the app read it, for [`summaries`].
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BackupFile {
    /// The file name without `.bin`.
    pub hex: String,
    /// The opened record; `None` when it did not open.
    pub record: Option<Value>,
    /// The file's modification date (seconds since 1970), for one that did not open.
    pub modified: f64,
}

/// `CookieBackups.summaries`: every backup, newest first. An unreadable one is listed with no
/// site and its file's date; a readable one with its record's `site` (empty when it has none)
/// and `createdAt` (milliseconds) as seconds.
pub fn summaries(files: &[BackupFile]) -> Vec<Summary> {
    let mut list: Vec<Summary> = files
        .iter()
        .map(|file| match file.record.as_ref().filter(|record| record.is_object()) {
            Some(record) => Summary {
                restore_id: restore_id(&file.hex),
                site: Some(record.get("site").and_then(Value::as_str).unwrap_or("").to_owned()),
                created_at: number(record.get("createdAt")).unwrap_or(0.0) / 1000.0,
            },
            None => {
                Summary { restore_id: restore_id(&file.hex), site: None, created_at: file.modified }
            }
        })
        .collect();
    list.sort_by(|a, b| b.created_at.total_cmp(&a.created_at));
    list
}
