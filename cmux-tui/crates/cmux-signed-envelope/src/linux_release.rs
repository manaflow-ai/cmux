//! The signed Linux release file (cmuxterm-hq docs/design/linux-signed-packages.md section 2):
//! `files.cmux.com/cmux-tui/<commit>/release.json` for a published commit and
//! `files.cmux.com/cmux-tui/tree/<key>/release.json` for a published cmux-tui tree, both this
//! crate's envelope around a payload with purpose [`PURPOSE`] (CI signs them in
//! `cmux-tui-artifacts.yml` with `scripts/ci/cmux-machine-channel.py payload --purpose
//! linux-release`; `scripts/cmux-next/web-ota-pointer.py verify --purpose cmux-linux-release`
//! checks the same shape).
//!
//! [`verify`] opens the envelope with [`trusted_keys`] before it reads a field, then holds the
//! file to the place it was read from: a per-commit file must name that commit, a per-tree file
//! that tree, and [`Release::binary`] gives a file's URL only when it is exactly
//! `<prefix><name>-<target>` under the file's own prefix (`cmux-tui/<commit>/`, or
//! `cmux-tui/tree/<tree_key>/` when the payload names its tree), as `check_binary` does for the
//! Cloud machine channel, so a payload cannot send a reader to another host or another build.
//! A per-commit file is reached only by its commit, so it has no expiry to enforce.

use std::collections::BTreeMap;

use base64::Engine as _;
use serde::Deserialize;

use crate::Key;

/// The payload's `purpose`: the Cloud machine channel says `cmux-cloud-machine-update`, a web
/// update pointer names none, so none of them stands in for another.
pub const PURPOSE: &str = "cmux-linux-release";
/// The payload schema this reader knows.
pub const PAYLOAD_SCHEMA: u64 = 1;
/// Every file a release names lives under this prefix.
pub const FILES_PREFIX: &str = "https://files.cmux.com/cmux-tui/";
/// A cmux-tui build is about 160 MB; nothing a release names is near this.
pub const MAX_FILE_BYTES: u64 = 512 * 1024 * 1024;
/// A release file is a few kilobytes.
pub const MAX_RELEASE_BYTES: usize = 256 * 1024;

/// The keys a Linux release file may be signed with: `(id, base64 raw ed25519 key)`. Phase 1 of
/// the design signs with the web update key, so this list equals
/// Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json (the test
/// `keys_are_the_web_update_keys` keeps them equal). To rotate, add the next key here and ship
/// it before CI signs with it.
pub const KEYS: &[(&str, &str)] =
    &[("e5d7bbcacc70703d", "uroy2ajE6JWnMjkx3FNdn88SJN4DCMfLpqZjkwx45WY=")];

/// [`KEYS`], decoded.
pub fn trusted_keys() -> Vec<Key> {
    KEYS.iter()
        .filter_map(|(id, b64)| {
            let raw = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
            let raw: [u8; 32] = raw.try_into().ok()?;
            Some(((*id).to_owned(), raw))
        })
        .collect()
}

/// Where a release file was read from, and so what it must name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Place<'a> {
    /// `cmux-tui/<commit>/release.json`: the build's own file, or (phase 1b) a signed alias of
    /// the tree it shares, whose URLs are under `cmux-tui/tree/<tree_key>/`.
    Commit(&'a str),
    /// `cmux-tui/tree/<key>/release.json`: the tree's own file.
    Tree(&'a str),
}

/// One file of a release.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct File {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

#[derive(Deserialize)]
struct Payload {
    schema: u64,
    purpose: String,
    commit: String,
    #[serde(default)]
    tree_key: Option<String>,
    #[serde(default)]
    version: String,
    targets: BTreeMap<String, BTreeMap<String, File>>,
}

/// A verified release file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release {
    /// The commit that built it (for a tree's file, the commit that published the tree).
    pub commit: String,
    pub tree_key: Option<String>,
    pub version: String,
    prefix: String,
    targets: BTreeMap<String, BTreeMap<String, File>>,
}

fn lower_hex(text: &str, len: usize) -> bool {
    text.len() == len && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The release in `body`, read from `place`, when a `keys` signature covers it and it is a
/// Linux release file of that place; else why not.
pub fn verify(body: &[u8], keys: &[Key], place: Place<'_>) -> Result<Release, String> {
    if body.len() > MAX_RELEASE_BYTES {
        return Err(format!("the release file is {} bytes, over the limit", body.len()));
    }
    let payload = crate::open(body, keys)?;
    let payload: Payload = serde_json::from_slice(&payload)
        .map_err(|e| format!("the release payload does not parse: {e}"))?;
    if payload.schema != PAYLOAD_SCHEMA {
        return Err(format!("unknown release payload schema {}", payload.schema));
    }
    if payload.purpose != PURPOSE {
        return Err(format!("the payload is a {} file, not a Linux release", payload.purpose));
    }
    if !lower_hex(&payload.commit, 40) {
        return Err("the release names no commit".to_owned());
    }
    if let Some(key) = &payload.tree_key
        && !lower_hex(key, 40)
    {
        return Err("the release names a malformed tree key".to_owned());
    }
    let prefix = match place {
        Place::Commit(commit) => {
            if payload.commit != commit {
                return Err(format!(
                    "the release file of {commit} is for commit {}",
                    payload.commit
                ));
            }
            match &payload.tree_key {
                Some(key) => format!("{FILES_PREFIX}tree/{key}/"),
                None => format!("{FILES_PREFIX}{commit}/"),
            }
        }
        Place::Tree(key) => {
            if payload.tree_key.as_deref() != Some(key) {
                return Err(format!("the release file of tree {key} is not that tree's"));
            }
            format!("{FILES_PREFIX}tree/{key}/")
        }
    };
    Ok(Release {
        commit: payload.commit,
        tree_key: payload.tree_key,
        version: payload.version,
        prefix,
        targets: payload.targets,
    })
}

impl Release {
    /// File `name` (`cmux-tui`, `cmux-tui-hook`, …) for Rust `target`, checked: its URL is
    /// exactly `<this file's prefix><name>-<target>`, its sha256 lowercase hex and its size in
    /// range. A target or file the release does not list is an error, never a guess.
    pub fn binary(&self, target: &str, name: &str) -> Result<&File, String> {
        let file = self.targets.get(target).and_then(|files| files.get(name)).ok_or_else(|| {
            format!("the release of {} lists no {name} for {target}", self.commit)
        })?;
        let url = format!("{}{name}-{target}", self.prefix);
        if file.url != url {
            return Err(format!("{name}-{target}: the url is not {url}"));
        }
        if !lower_hex(&file.sha256, 64) {
            return Err(format!("{name}-{target}: the sha256 is not a sha256"));
        }
        if file.size == 0 || file.size > MAX_FILE_BYTES {
            return Err(format!("{name}-{target}: size {} is out of range", file.size));
        }
        Ok(file)
    }
}

#[cfg(test)]
#[path = "linux_release_tests.rs"]
mod tests;
