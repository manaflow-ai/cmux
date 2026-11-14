//! The access token the Mac's own Codex CLI keeps in its `auth.json` (Leo, 2026-11-05:
//! "claude/codex/antigravity/cursor/muse and those subscriptions should all be detectable /
//! many many existing apps can do this"), so a Mac already signed in to Codex gives its own
//! Cloud machines access with no new device login.
//!
//! Read only, never a second refresher: Codex's refresh token rotates, and a second holder
//! refreshing it would invalidate the Mac's copy and sign the person out of Codex on the Mac.
//! So this never runs Codex against the Mac's home, never refreshes, never writes, and returns
//! only the access token, the account and the expiry (the same access-only shape the holder
//! delivers). A token too close to its end is not offered; the private holder takes over.
//!
//! Only the file store is read (`cli_auth_credentials_store` unset or `"file"`): in keyring or
//! auto mode the file may be stale and the Keychain item is Codex's own, so nothing is offered.

use std::io::Read as _;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use base64::Engine as _;
use serde_json::Value;

use crate::types::Grant;

/// A token with less left than this (seconds) is not offered: the machine would need a renewal at once.
pub const MINIMUM_LIFETIME: f64 = 15.0 * 60.0;
/// `auth.json` is a few KiB; anything larger is not Codex's.
const SIZE_LIMIT: u64 = 64 * 1024;

/// The Codex home: `$CODEX_HOME` when set (a `~/` one under `user_home`; a relative one is
/// ignored), else `user_home/.codex`.
pub fn home(codex_home: Option<&str>, user_home: &Path) -> PathBuf {
    if let Some(raw) = codex_home.map(str::trim).filter(|raw| !raw.is_empty()) {
        let expanded = match raw.strip_prefix("~/") {
            Some(rest) => user_home.join(rest),
            None => PathBuf::from(raw),
        };
        if expanded.is_absolute() {
            return expanded;
        }
    }
    user_home.join(".codex")
}

/// The Mac's current Codex access in `home`, or none when there is none cmux may use: no
/// ChatGPT sign-in, an API key sign-in, keyring storage, a file that is not the person's private
/// regular file, or a token with less than [`MINIMUM_LIFETIME`] left. Blocking file IO.
pub fn read(home: &Path, now: f64) -> Option<Grant> {
    if !uses_file_store(&home.join("config.toml")) {
        return None;
    }
    grant(&private_file(&home.join("auth.json"), true)?, now)
}

/// The access-only grant in an `auth.json`'s bytes.
pub fn grant(auth_json: &[u8], now: f64) -> Option<Grant> {
    let root: Value = serde_json::from_slice(auth_json).ok()?;
    let root = root.as_object()?;
    // An API key sign-in is not a subscription; a mode other than ChatGPT is not this reader's.
    if root.get("OPENAI_API_KEY").and_then(Value::as_str).is_some_and(|key| !key.is_empty()) {
        return None;
    }
    if root.get("auth_mode").and_then(Value::as_str).is_some_and(|mode| mode != "chatgpt") {
        return None;
    }
    let tokens = root.get("tokens")?.as_object()?;
    let access = tokens.get("access_token")?.as_str()?;
    if access.is_empty() || access.len() >= 16_384 || !access.bytes().all(|b| b > 32 && b < 127) {
        return None;
    }
    let account = match tokens.get("account_id").and_then(Value::as_str) {
        Some(account) => account.to_owned(),
        None => account_claim(access)?,
    };
    if account.is_empty() {
        return None;
    }
    let expiry = expiry(access, now)?;
    if expiry - now < MINIMUM_LIFETIME {
        return None;
    }
    Some(Grant { access_token: access.to_owned(), account, expires_at: expiry })
}

/// Whether config.toml keeps Codex's credentials in `auth.json` (its default). No config.toml:
/// the default. One cmux cannot read: nothing is offered.
pub fn uses_file_store(config: &Path) -> bool {
    if let Err(error) = std::fs::symlink_metadata(config) {
        return error.kind() == std::io::ErrorKind::NotFound;
    }
    let Some(text) = private_file(config, false).and_then(|data| String::from_utf8(data).ok())
    else {
        return false;
    };
    for line in text.lines().filter(|line| !line.is_empty()) {
        let Some((key, value)) = line.split_once('=') else { continue };
        if key.is_empty() || value.is_empty() || key.trim() != "cli_auth_credentials_store" {
            continue;
        }
        let value = value.trim();
        // The text before a comment, or after a leading `#` (Swift's split dropped an empty part).
        let value = match value.split_once('#') {
            Some(("", after)) => after.split('#').next().unwrap_or_default(),
            Some((before, _)) => before,
            None => value,
        };
        return value.trim().trim_matches(|c| c == '"' || c == '\'') == "file";
    }
    true
}

/// A regular file of this user's, not a symlink, within the size limit; `require_private` also
/// requires no group or other access (Codex writes `auth.json` 0600).
pub fn private_file(path: &Path, require_private: bool) -> Option<Vec<u8>> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    if !metadata.is_file()
        || metadata.uid() != uid
        || (require_private && metadata.mode() & 0o077 != 0)
        || metadata.len() > SIZE_LIMIT
    {
        return None;
    }
    let mut data = Vec::new();
    file.take(SIZE_LIMIT + 1).read_to_end(&mut data).ok()?;
    (data.len() as u64 <= SIZE_LIMIT).then_some(data)
}

/// A JWT's claims (its middle part), when it has three parts.
fn claims(jwt: &str) -> Option<serde_json::Map<String, Value>> {
    let parts: Vec<&str> = jwt.split('.').filter(|part| !part.is_empty()).collect();
    let [_, payload, _] = parts.as_slice() else { return None };
    let mut payload = payload.replace('-', "+").replace('_', "/");
    while payload.len() % 4 != 0 {
        payload.push('=');
    }
    let data = base64::engine::general_purpose::STANDARD.decode(payload).ok()?;
    match serde_json::from_slice(&data).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

/// The token's expiry: a NumericDate within a year of now (a far or non-finite one is malformed).
fn expiry(jwt: &str, now: f64) -> Option<f64> {
    let exp = claims(jwt)?.get("exp")?.as_f64()?;
    (exp.is_finite() && exp > 0.0 && exp < now + 366.0 * 86_400.0).then_some(exp)
}

/// The ChatGPT account id in the access token's auth claim, for an `auth.json` without `account_id`.
fn account_claim(jwt: &str) -> Option<String> {
    let all = claims(jwt)?;
    let nested = all
        .get("https://api.openai.com/auth")
        .and_then(|auth| auth.get("chatgpt_account_id"))
        .and_then(Value::as_str);
    nested.or_else(|| all.get("chatgpt_account_id").and_then(Value::as_str)).map(str::to_owned)
}

#[cfg(test)]
#[path = "local_access_tests.rs"]
mod tests;
