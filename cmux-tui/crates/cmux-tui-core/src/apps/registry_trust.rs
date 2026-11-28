//! The extension registry's two signed files (extensions DESIGN.md section
//! 11: "our signature over the source hash and the built hash. Revocation is
//! a signed list the app checks; a revoked extension is turned off with the
//! reason").
//!
//! Both are `cmux-signed-envelope` files signed by a [`trusted_keys`] key,
//! the registry's own (`registry-keys.json`), never the store's or the web
//! update channel's; each payload names its own `purpose`, so one kind never
//! opens as the other.
//!
//! - A registry entry ([`ENTRY_PURPOSE`]): an extension's id and version,
//!   the repository and commit it was built from (the commit is the source
//!   hash), and the sha256 `cmux ext pack` gives that commit (the built
//!   hash). `cmux ext pack --entry FILE` rebuilds and compares against it.
//! - The revocation list ([`REVOCATIONS_PURPOSE`]): built hashes cmux
//!   turned off, each with its reason. The daemon reads it from
//!   `<state>/apps/`[`REVOCATIONS_FILE`] on every catalog load and refuses
//!   an installed extension whose recorded build (`origin.sha256` in the
//!   `ext add` marker) is listed. A list that does not open (no key, a bad
//!   signature, another purpose) revokes nothing.
//!
//! With no key in `registry-keys.json` (no registry key exists yet), every
//! entry is refused and no list opens.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

use cmux_signed_envelope::Key;
use serde::Deserialize;

/// The payload purpose of a registry entry.
pub const ENTRY_PURPOSE: &str = "cmux-extension-entry";
/// The payload purpose of the revocation list.
pub const REVOCATIONS_PURPOSE: &str = "cmux-extension-revocations";
/// The payload schema both kinds use.
pub const SCHEMA: u64 = 1;
/// The revocation list's file name in `<state>/apps`.
pub const REVOCATIONS_FILE: &str = "revocations.sig";
/// The marker `cmux ext dev` and `ext add` leave in an installed copy.
pub const MARKER: &str = ".cmux-ext-dev.json";

/// The largest signed file read.
pub(super) const MAX_BYTES: u64 = 4 * 1024 * 1024;

/// The registry signing keys (`web-ota-pointer.py --keys` format). To add or
/// rotate one, add its public half here and ship it before the registry
/// signs with it.
const KEYS_JSON: &str = include_str!("registry-keys.json");

/// The keys a registry entry or revocation list may be signed with.
pub fn trusted_keys() -> Vec<Key> {
    #[cfg(test)]
    if let Some(keys) = tests::TEST_KEYS.with(|keys| keys.borrow().clone()) {
        return keys;
    }
    static KEYS: OnceLock<Vec<Key>> = OnceLock::new();
    KEYS.get_or_init(|| cmux_signed_envelope::keys_from_json(KEYS_JSON)).clone()
}

/// A signed registry entry, opened.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Entry {
    pub id: String,
    pub version: String,
    /// `OWNER/REPO` on GitHub.
    pub repository: String,
    /// The commit it was built from: the source hash.
    pub commit: String,
    /// The sha256 of `cmux ext pack` at that commit: the built hash.
    pub sha256: String,
}

/// One revoked build.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Revoked {
    /// The built hash.
    pub sha256: String,
    /// The extension it was, for the message.
    #[serde(default)]
    pub id: Option<String>,
    pub reason: String,
}

/// The revocation list, opened.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Revocations {
    /// Higher is newer; a fetcher keeps the highest it has seen.
    pub sequence: u64,
    by_hash: BTreeMap<String, Revoked>,
}

#[derive(Deserialize)]
struct Header {
    schema: u64,
    purpose: String,
}

#[derive(Deserialize)]
struct EntryPayload {
    #[serde(flatten)]
    entry: Entry,
}

#[derive(Deserialize)]
struct RevocationsPayload {
    sequence: u64,
    revoked: Vec<Revoked>,
}

/// The payload of `body` as `purpose`, when a `keys` key signed it.
fn open_as<T: serde::de::DeserializeOwned>(
    body: &[u8],
    keys: &[Key],
    purpose: &str,
) -> Result<T, String> {
    if keys.is_empty() {
        return Err("this build trusts no registry key".to_owned());
    }
    let bytes = cmux_signed_envelope::open(body, keys)?;
    let header: Header =
        serde_json::from_slice(&bytes).map_err(|e| format!("the payload does not parse: {e}"))?;
    if header.schema != SCHEMA {
        return Err(format!("unknown payload schema {}", header.schema));
    }
    if header.purpose != purpose {
        return Err(format!("the payload is for {}, not {purpose}", header.purpose));
    }
    serde_json::from_slice(&bytes).map_err(|e| format!("the payload does not parse: {e}"))
}

fn is_sha256(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| b.is_ascii_hexdigit())
}

/// The registry entry in `body`, when a `keys` key signed it; else why not.
pub fn open_entry(body: &[u8], keys: &[Key]) -> Result<Entry, String> {
    let EntryPayload { mut entry } = open_as(body, keys, ENTRY_PURPOSE)?;
    if !is_sha256(&entry.sha256) {
        return Err(format!("the entry's sha256 {} is not a sha256", entry.sha256));
    }
    entry.sha256.make_ascii_lowercase();
    Ok(entry)
}

/// The revocation list in `body`, when a `keys` key signed it; else why not.
pub fn open_revocations(body: &[u8], keys: &[Key]) -> Result<Revocations, String> {
    let payload: RevocationsPayload = open_as(body, keys, REVOCATIONS_PURPOSE)?;
    let mut by_hash = BTreeMap::new();
    for mut revoked in payload.revoked {
        if !is_sha256(&revoked.sha256) {
            return Err(format!("{} is not a sha256", revoked.sha256));
        }
        revoked.sha256.make_ascii_lowercase();
        by_hash.insert(revoked.sha256.clone(), revoked);
    }
    Ok(Revocations { sequence: payload.sequence, by_hash })
}

/// Reads a signed file of at most [`MAX_BYTES`]; `None` when there is none.
pub fn read_signed(path: &Path) -> Option<Result<Vec<u8>, String>> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return Some(Err(format!("{} is not a signed file", path.display())));
    }
    Some(std::fs::read(path).map_err(|e| format!("{}: {e}", path.display())))
}

impl Revocations {
    /// The list at `<apps_dir>/`[`REVOCATIONS_FILE`] when `keys` open it;
    /// `None` when there is none, it does not open, or it is empty, so a
    /// load with nothing revoked reads no marker.
    pub fn load(apps_dir: &Path, keys: &[Key]) -> Option<Revocations> {
        let body = read_signed(&apps_dir.join(REVOCATIONS_FILE))?.ok()?;
        open_revocations(&body, keys).ok().filter(|list| !list.by_hash.is_empty())
    }

    /// The entry revoking `sha256`, if any.
    pub fn get(&self, sha256: &str) -> Option<&Revoked> {
        self.by_hash.get(&sha256.to_ascii_lowercase())
    }

    /// `Err(why)` when the build the package in `dir` records (`origin.sha256`
    /// in its [`MARKER`]) is revoked; `Ok` for one that records none.
    pub fn check(&self, dir: &Path) -> Result<(), String> {
        let Some(sha256) = recorded_sha256(dir) else { return Ok(()) };
        match self.get(&sha256) {
            None => Ok(()),
            Some(revoked) => Err(format!(
                "{}revoked by cmux: {} (build {sha256})",
                revoked.id.as_deref().map(|id| format!("{id}: ")).unwrap_or_default(),
                revoked.reason
            )),
        }
    }
}

/// The built hash `ext add` recorded for the copy in `dir`.
pub fn recorded_sha256(dir: &Path) -> Option<String> {
    let raw = std::fs::read(dir.join(MARKER)).ok()?;
    let marker: serde_json::Value = serde_json::from_slice(&raw).ok()?;
    marker.pointer("/origin/sha256")?.as_str().filter(|s| is_sha256(s)).map(str::to_owned)
}

#[cfg(test)]
#[path = "registry_trust_tests.rs"]
pub(super) mod tests;
