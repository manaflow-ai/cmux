//! `cmux link sync push --socket PATH LOCAL REMOTE`: copies a folder (a git
//! working copy with its repository) to a Cloud machine's home through the
//! machine daemon's `fs-v1` ops (Move to Cloud, cmuxterm-hq#1874 slice 2).
//! `--socket` is the machine daemon's socket as this Mac reaches it (the
//! machine link's local socket); `REMOTE` is an absolute folder under the
//! machine's home. What goes is in [`local`].
//!
//! A manifest on the machine (`REMOTE/.git/cmux-sync.json` in a git
//! working copy, else `REMOTE/.cmux-sync.json`) records each pushed file's
//! SHA-256, executable bit and the revision the machine gave it. A file
//! whose hash, bit and revision still match is not written again, and a
//! file the manifest lists but the folder no longer has is deleted; files
//! the machine made itself are never touched.
//!
//! Output: one JSON line on stdout, `{"ok":true,"written":N,"unchanged":N,
//! "deleted":N,"skipped":N,"bytes":N}`, exit 0; on failure
//! `{"ok":false,"error":...,"error_code":...}` on stdout, exit 1; bad usage
//! exits 64.

mod local;
mod remote;

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read as _;
use std::path::{Path, PathBuf};

use anyhow::{Context as _, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest as _, Sha256};

use local::{LocalFile, Source};
use remote::{Remote, RemoteEntry};

const USAGE: &str = "usage: cmux link sync push --socket PATH LOCAL_FOLDER REMOTE_FOLDER";

/// What the machine holds of earlier pushes.
#[derive(Default, Serialize, Deserialize)]
struct Manifest {
    version: u32,
    files: BTreeMap<String, Pushed>,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
struct Pushed {
    sha256: String,
    executable: bool,
    revision: String,
}

#[derive(Default)]
struct Summary {
    written: u64,
    unchanged: u64,
    deleted: u64,
    skipped: u64,
    bytes: u64,
}

pub(super) fn run(args: &[String]) -> i32 {
    let Some((socket, local, remote)) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    match push(&socket, &local, &remote) {
        Ok(summary) => {
            println!(
                "{}",
                json!({
                    "ok": true,
                    "written": summary.written,
                    "unchanged": summary.unchanged,
                    "deleted": summary.deleted,
                    "skipped": summary.skipped,
                    "bytes": summary.bytes,
                })
            );
            0
        }
        Err(error) => {
            let code = remote::refusal_code(&error).unwrap_or("sync_failed").to_string();
            println!(
                "{}",
                json!({ "ok": false, "error": format!("{error:#}"), "error_code": code })
            );
            1
        }
    }
}

fn parse(args: &[String]) -> Option<(PathBuf, PathBuf, String)> {
    let [action, rest @ ..] = args else { return None };
    if action != "push" {
        return None;
    }
    let mut socket = None;
    let mut positional = Vec::new();
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--socket" => socket = Some(PathBuf::from(rest.next()?)),
            flag if flag.starts_with('-') => return None,
            value => positional.push(value),
        }
    }
    let [local, remote] = positional.as_slice() else { return None };
    if !remote.starts_with('/') {
        return None;
    }
    Some((socket?, PathBuf::from(local), remote.trim_end_matches('/').to_string()))
}

fn push(socket: &Path, local: &Path, remote_root: &str) -> anyhow::Result<Summary> {
    let local =
        std::fs::canonicalize(local).with_context(|| format!("cannot open {}", local.display()))?;
    let set = local::collect(&local)?;
    let mut summary = Summary { skipped: set.skipped, ..Summary::default() };
    let mut remote = Remote::connect(socket)?;
    remote.mkdir_all(remote_root)?;
    let manifest_path = format!(
        "{remote_root}/{}",
        if set.git { ".git/cmux-sync.json" } else { ".cmux-sync.json" }
    );
    let previous: Manifest = remote
        .read(&manifest_path)?
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();

    let mut listings: BTreeMap<String, Option<BTreeMap<String, RemoteEntry>>> = BTreeMap::new();
    let mut made: BTreeSet<String> = BTreeSet::new();
    let mut next = Manifest { version: 1, files: BTreeMap::new() };
    for (relative, file) in &set.files {
        let target = format!("{remote_root}/{relative}");
        let (parent, name) = remote::split(&target)?;
        let sha256 = hash(file)?;
        if let Some(pushed) = previous.files.get(relative)
            && pushed.sha256 == sha256
            && pushed.executable == file.executable
        {
            if !listings.contains_key(parent) {
                let listing = remote.list(parent)?;
                listings.insert(parent.to_string(), listing);
            }
            let current = listings[parent].as_ref().and_then(|entries| entries.get(name));
            if current.is_some_and(|entry| {
                entry.kind == "file" && entry.revision.as_deref() == Some(pushed.revision.as_str())
            }) {
                summary.unchanged += 1;
                next.files.insert(relative.clone(), pushed.clone());
                continue;
            }
        }
        if made.insert(parent.to_string()) {
            remote.mkdir_all(parent)?;
        }
        let mut reader = open(file)?;
        let revision = remote.write(&target, &mut reader, file.executable)?;
        summary.written += 1;
        summary.bytes += size(file)?;
        next.files
            .insert(relative.clone(), Pushed { sha256, executable: file.executable, revision });
    }

    let gone: Vec<String> = previous
        .files
        .keys()
        .filter(|relative| !set.files.contains_key(*relative))
        .map(|relative| format!("{remote_root}/{relative}"))
        .collect();
    remote.delete(&gone)?;
    summary.deleted = gone.len() as u64;

    let manifest = serde_json::to_vec(&next)?;
    remote
        .write(&manifest_path, &mut manifest.as_slice(), false)
        .map_err(|error| anyhow!("cannot save the sync manifest: {error:#}"))?;
    Ok(summary)
}

fn open(file: &LocalFile) -> anyhow::Result<Box<dyn std::io::Read>> {
    Ok(match &file.source {
        Source::File(path) => Box::new(
            std::fs::File::open(path).with_context(|| format!("cannot read {}", path.display()))?,
        ),
        Source::Bytes(bytes) => Box::new(std::io::Cursor::new(bytes.clone())),
    })
}

fn size(file: &LocalFile) -> anyhow::Result<u64> {
    Ok(match &file.source {
        Source::File(path) => std::fs::metadata(path)?.len(),
        Source::Bytes(bytes) => bytes.len() as u64,
    })
}

fn hash(file: &LocalFile) -> anyhow::Result<String> {
    let mut hasher = Sha256::new();
    let mut reader = open(file)?;
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}
