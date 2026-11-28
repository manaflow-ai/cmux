//! Web updates (plans/cmux-next/web-ota.md): the decisions the app's
//! `CmuxNextUpdater/WebUpdates` made in Swift. The app keeps the I/O it owns
//! (the download, `tar`, the moves), the signature check (CryptoKit over the
//! envelope: the trust root stays the OS's crypto) and the swap's safe point
//! (`WebSwapGate`, a few lines a page per look, cheaper than a call); the
//! pointer's, the tree's and the archive's checks are here.
//!
//! The ops (`call`, through `updater::call`):
//!
//! - `web_updates.read_pointer` `{payload, channel}` → `{"pointer": {...}}` or
//!   `{"refusal": {kind, detail?}}`: a signed payload (UTF-8 JSON) read as a
//!   pointer of `channel`, checked field by field. `pointer` uses the payload's
//!   own keys (`committed_at`, `published_at`), with a malformed `cas` dropped.
//! - `web_updates.tree_digest` `{root}` → `{"digest"}` or `{"refusal"}`:
//!   web-bundle-key.py's `--outputs` digest of an unpacked tree. Blocking.
//! - `web_updates.archive_digest` `{file}` → `{size, sha256}` or `{"refusal"}`:
//!   an archive's size and SHA-256, refused past [`MAXIMUM_SIZE`]. Blocking.

use super::{OpError, de};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// The largest archive the app downloads.
pub const MAXIMUM_SIZE: i64 = 200 << 20;

/// web-bundle-key.py OUTPUTS, in its order (the app's `WebUpdateTree.outputs`).
pub const OUTPUTS: [&str; 5] = [
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
    "Resources/markdown-viewer/webviews-app",
    "Native/OptChat/optchat-chief/inspector/index.html",
];
const IGNORED_NAMES: [&str; 1] = [".DS_Store"];

/// Why a web update was not taken (the app's `WebUpdateRefusal`, the cases
/// decided here).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "detail", rename_all = "camelCase")]
pub enum Refusal {
    Malformed(String),
    WrongChannel(String),
    Integrity(String),
}

/// `cas`: a manifest and a pack under `prefix` on the archive's host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cas {
    pub prefix: String,
    pub manifest: String,
    pub pack: String,
}

impl Cas {
    /// Two 64-hex ids and a relative folder of lowercase words (no `..`, no host).
    pub fn is_valid(&self) -> bool {
        let Some(folder) = self.prefix.strip_suffix('/') else { return false };
        is_hex(&self.manifest, 64)
            && is_hex(&self.pack, 64)
            && folder.split('/').all(|part| {
                !part.is_empty()
                    && part
                        .bytes()
                        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            })
    }
}

/// One channel's pointer, as the payload names it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pointer {
    pub channel: String,
    pub key: String,
    pub archive: String,
    pub sha256: String,
    pub size: i64,
    pub outputs: String,
    pub abi: i64,
    pub commit: String,
    pub committed_at: i64,
    pub published_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cas: Option<Cas>,
}

impl Pointer {
    fn validate(&self) -> Result<(), Refusal> {
        let bad = |what: &str| Err(Refusal::Malformed(what.to_owned()));
        if !is_hex(&self.key, 64) || !is_hex(&self.sha256, 64) || !is_hex(&self.outputs, 64) {
            return bad("bad digest");
        }
        if self.archive != format!("web-bundles-{}.tar.gz", self.sha256) {
            return bad("archive name");
        }
        if !(1..=MAXIMUM_SIZE).contains(&self.size) {
            return bad(&format!("size {}", self.size));
        }
        if !is_hex(&self.commit, 40) || self.abi <= 0 || self.committed_at <= 0 {
            return bad("commit or abi");
        }
        Ok(())
    }
}

/// A signed payload read as `channel`'s pointer. The signature over `payload`
/// was checked by the caller.
pub fn read_pointer(payload: &str, channel: &str) -> Result<Pointer, Refusal> {
    let malformed = || Refusal::Malformed("not a pointer payload".to_owned());
    let mut body: serde_json::Map<String, Value> =
        serde_json::from_str(payload).map_err(|_| malformed())?;
    if body.get("schema").and_then(Value::as_i64) != Some(1) {
        return Err(malformed());
    }
    // A malformed `cas` never refuses the pointer: the archive is the floor.
    let cas = body
        .remove("cas")
        .and_then(|v| serde_json::from_value::<Cas>(v).ok())
        .filter(Cas::is_valid);
    let mut pointer: Pointer =
        serde_json::from_value(Value::Object(body)).map_err(|_| malformed())?;
    pointer.cas = cas;
    if pointer.channel != channel {
        return Err(Refusal::WrongChannel(pointer.channel));
    }
    pointer.validate()?;
    Ok(pointer)
}

fn is_hex(text: &str, count: usize) -> bool {
    text.len() == count && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

enum Kind {
    File,
    Directory,
    Missing,
}

fn kind(path: &Path) -> Result<Kind, Refusal> {
    let name = || path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let Ok(meta) = fs::symlink_metadata(path) else { return Ok(Kind::Missing) };
    let ty = meta.file_type();
    if ty.is_symlink() {
        return Err(Refusal::Integrity(format!("link {}", name())));
    }
    if ty.is_dir() {
        return Ok(Kind::Directory);
    }
    if ty.is_file() {
        return Ok(Kind::File);
    }
    Err(Refusal::Integrity(format!("special file {}", name())))
}

/// os.walk order: a folder's files by name (bytes), then each subfolder by name.
fn walk(directory: &Path, relative: &str, files: &mut Vec<String>) -> Result<(), Refusal> {
    let unreadable = || Refusal::Integrity(format!("unreadable {relative}"));
    let mut names: Vec<_> = fs::read_dir(directory)
        .map_err(|_| unreadable())?
        .filter_map(|e| e.ok().map(|e| e.file_name()))
        .collect();
    names.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    let mut directories = Vec::new();
    for name in names {
        let text = name.to_string_lossy().into_owned();
        match kind(&directory.join(&name))? {
            Kind::File if !IGNORED_NAMES.contains(&text.as_str()) => {
                files.push(format!("{relative}/{text}"))
            }
            Kind::Directory => directories.push(text),
            Kind::File | Kind::Missing => {}
        }
    }
    for name in directories {
        walk(&directory.join(&name), &format!("{relative}/{name}"), files)?;
    }
    Ok(())
}

/// The `--outputs` digest of the tree at `root`. Refuses a link or any other
/// non-regular file, which an archive never holds.
pub fn tree_digest(root: &Path) -> Result<String, Refusal> {
    let mut hash = Sha256::new();
    for top in OUTPUTS {
        let base = root.join(top);
        let mut files = Vec::new();
        match kind(&base)? {
            Kind::File => files.push(top.to_owned()),
            Kind::Directory => walk(&base, top, &mut files)?,
            Kind::Missing => {
                hash.update(format!("missing {top}\n"));
                continue;
            }
        }
        if files.is_empty() {
            hash.update(format!("empty {top}\n"));
        }
        for rel in files {
            let data = fs::read(root.join(&rel))
                .map_err(|_| Refusal::Integrity(format!("unreadable {rel}")))?;
            hash.update(format!("{rel}\0{}\n", hex(&Sha256::digest(&data))));
        }
    }
    Ok(hex(&hash.finalize()))
}

/// An archive's size and SHA-256, refused past [`MAXIMUM_SIZE`].
pub fn archive_digest(file: &Path) -> Result<(i64, String), Refusal> {
    let mut handle =
        fs::File::open(file).map_err(|_| Refusal::Integrity("unreadable archive".to_owned()))?;
    let mut hash = Sha256::new();
    let mut size: i64 = 0;
    let mut chunk = vec![0u8; 1 << 20];
    loop {
        let n = match handle.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        size += n as i64;
        if size > MAXIMUM_SIZE {
            return Err(Refusal::Integrity("archive too large".to_owned()));
        }
        hash.update(&chunk[..n]);
    }
    Ok((size, hex(&hash.finalize())))
}

fn refusal(r: Refusal) -> Value {
    json!({ "refusal": r })
}

/// The web update ops.
pub fn call(op: &str, request: &Value) -> Result<Value, OpError> {
    #[derive(Deserialize)]
    struct ReadPointer {
        payload: String,
        channel: String,
    }
    #[derive(Deserialize)]
    struct Root {
        root: PathBuf,
    }
    #[derive(Deserialize)]
    struct Archive {
        file: PathBuf,
    }
    Ok(match op {
        "web_updates.read_pointer" => {
            let ReadPointer { payload, channel } = de(request)?;
            match read_pointer(&payload, &channel) {
                Ok(pointer) => json!({ "pointer": pointer }),
                Err(r) => refusal(r),
            }
        }
        "web_updates.tree_digest" => {
            let Root { root } = de(request)?;
            match tree_digest(&root) {
                Ok(digest) => json!({ "digest": digest }),
                Err(r) => refusal(r),
            }
        }
        "web_updates.archive_digest" => {
            let Archive { file } = de(request)?;
            match archive_digest(&file) {
                Ok((size, sha256)) => json!({ "size": size, "sha256": sha256 }),
                Err(r) => refusal(r),
            }
        }
        _ => return Err(OpError::Unknown),
    })
}

#[cfg(test)]
#[path = "web_updates_tests.rs"]
mod tests;
