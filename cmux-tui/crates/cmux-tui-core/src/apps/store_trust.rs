//! Store packages cmux signed: the `Verified` tier (mirror.rs).
//!
//! A store package (`AppPlatform/store/<name>`, written by
//! scripts/cmux-next/sync-app-runtime.sh) is `Verified` only when it carries
//! [`SIGNATURE_FILE`], a signed envelope (`cmux-signed-envelope`) by a
//! [`trusted_keys`] key whose payload says [`PURPOSE`], names the package's
//! id and version, and lists every file of the package with its SHA-256,
//! nothing missing and nothing extra. A name or a manifest field alone never
//! makes a package `Verified`: an unsigned, mis-signed or changed package
//! stays `Unverified`.
//!
//! The keys are the store's own (`store-keys.json`, CI secret
//! `CMUX_STORE_SIGNING_KEY`), never the web update channel's: a web update
//! pointer or Cloud machine channel file does not open here, and a store
//! signature does not open there. With no key in the file (a build CI did
//! not sign), every store package is `Unverified`.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

use cmux_signed_envelope::Key;
use serde::Deserialize;
use sha2::{Digest as _, Sha256};

/// The signature file at the top of a signed store package.
pub const SIGNATURE_FILE: &str = "STORE.sig";

/// The payload purpose of a store package signature.
pub const PURPOSE: &str = "cmux-store-package";

/// The payload schema [`verify`] reads.
pub const SCHEMA: u64 = 1;

/// The largest signature file read.
const SIGNATURE_MAX_BYTES: u64 = 1024 * 1024;

/// The most files a signed package may hold.
const MAX_FILES: usize = 4096;

/// The store signing keys (`web-ota-pointer.py --keys` format). To add or
/// rotate one, add its public half here and ship it before CI signs with it.
const KEYS_JSON: &str = include_str!("store-keys.json");

#[derive(Deserialize)]
struct Payload {
    schema: u64,
    purpose: String,
    id: String,
    version: String,
    files: BTreeMap<String, String>,
}

/// The keys a store package may be signed with.
pub fn trusted_keys() -> Vec<Key> {
    #[cfg(test)]
    if let Some(keys) = tests::TEST_KEYS.with(|keys| keys.borrow().clone()) {
        return keys;
    }
    static KEYS: OnceLock<Vec<Key>> = OnceLock::new();
    KEYS.get_or_init(|| cmux_signed_envelope::keys_from_json(KEYS_JSON)).clone()
}

/// Whether the package in `dir` is the store package `id` at `version` as a
/// `keys` key signed it; else why not.
pub fn verify(dir: &Path, id: &str, version: &str, keys: &[Key]) -> Result<(), String> {
    let path = dir.join(SIGNATURE_FILE);
    let meta = std::fs::symlink_metadata(&path).map_err(|_| format!("no {SIGNATURE_FILE}"))?;
    if !meta.is_file() || meta.len() > SIGNATURE_MAX_BYTES {
        return Err(format!("{SIGNATURE_FILE} is not a signature file"));
    }
    let body = std::fs::read(&path).map_err(|e| format!("{SIGNATURE_FILE}: {e}"))?;
    let bytes = cmux_signed_envelope::open(&body, keys)?;
    let payload: Payload =
        serde_json::from_slice(&bytes).map_err(|e| format!("the payload does not parse: {e}"))?;
    if payload.schema != SCHEMA {
        return Err(format!("unknown payload schema {}", payload.schema));
    }
    if payload.purpose != PURPOSE {
        return Err(format!("the payload is for {}, not a store package", payload.purpose));
    }
    if payload.id != id || payload.version != version {
        return Err(format!(
            "the signature is {}@{}'s, not {id}@{version}'s",
            payload.id, payload.version
        ));
    }
    let mut files = BTreeMap::new();
    walk(dir, "", &mut files)?;
    if files.len() != payload.files.len() || !files.keys().eq(payload.files.keys()) {
        return Err("the package's files are not the signed files".to_owned());
    }
    for (name, path) in &files {
        let have = sha256_file(path)?;
        if payload.files.get(name) != Some(&have) {
            return Err(format!("{name} is not the signed file"));
        }
    }
    Ok(())
}

/// Every regular file under `dir` but the top [`SIGNATURE_FILE`], by its
/// `/`-separated relative name. A symlink or any other kind of entry fails.
fn walk(
    dir: &Path,
    prefix: &str,
    files: &mut BTreeMap<String, std::path::PathBuf>,
) -> Result<(), String> {
    let entries = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("{}: {e}", dir.display()))?;
        let name = entry.file_name();
        let name = name.to_str().ok_or("a file name is not UTF-8")?;
        let rel = format!("{prefix}{name}");
        if rel == SIGNATURE_FILE {
            continue;
        }
        let kind = entry.file_type().map_err(|e| format!("{rel}: {e}"))?;
        if kind.is_dir() {
            walk(&entry.path(), &format!("{rel}/"), files)?;
        } else if kind.is_file() {
            files.insert(rel, entry.path());
        } else {
            return Err(format!("{rel} is not a regular file"));
        }
        if files.len() > MAX_FILES {
            return Err("the package holds too many files".to_owned());
        }
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!("{:x}", Sha256::digest(&bytes)))
}

#[cfg(test)]
#[path = "store_trust_tests.rs"]
pub(super) mod tests;
