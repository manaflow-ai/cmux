//! `cmux link sync push --socket PATH LOCAL REMOTE`: copies a folder (a git
//! working copy with its repository) to a Cloud machine's home through the
//! machine daemon's `fs-v1` ops (Move to Cloud, cmuxterm-hq#1874 slice 2).
//! `--socket` is the machine daemon's socket as this Mac reaches it (the
//! machine link's local socket); `REMOTE` is an absolute folder under the
//! machine's home. What goes is in [`local`]. `cmux link sync pull` brings
//! it back by a three-way merge against the push ([`pull`]).
//!
//! A manifest on the machine (`REMOTE/.git/cmux-sync.json` in a git
//! working copy, else `REMOTE/.cmux-sync.json`) records each pushed file's
//! SHA-256, permissions and the revision the machine gave it, and in git
//! the branch, HEAD commit and staged changes the push left
//! ([`git_back::GitBase`]). A file
//! whose hash, permissions and revision still match is not written again,
//! and a file the manifest lists but the folder no longer has is deleted
//! while the machine still has it as this push left it. Files the machine
//! made or changed itself are never deleted. This Mac keeps a copy of the
//! manifest ([`base`]); a pull trusts only that copy.
//!
//! Output: one JSON line on stdout, `{"ok":true,"written":N,"unchanged":N,
//! "deleted":N,"skipped":N,"bytes":N}` (a pull adds `fast_forwarded` and
//! `head`), exit 0; on failure `{"ok":false,"error":...,"error_code":...}`
//! on stdout (a pull's conflict adds `"conflicts":[paths]` under
//! `sync_conflict`), exit 1; bad usage exits 64. Unix only, like the link.

mod base;
mod git_back;
mod local;
mod names;
mod place;
mod pull;
mod remote;

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest as _, Sha256};

use local::{LocalFile, Source};
use remote::{Remote, RemoteEntry};

const USAGE: &str = "usage: cmux link sync push|pull --socket PATH LOCAL_FOLDER REMOTE_FOLDER";

/// What the machine holds of earlier pushes; this Mac keeps a copy
/// ([`base`]), which is what a pull trusts.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Manifest {
    version: u32,
    files: BTreeMap<String, Pushed>,
    /// The git state the push left; None outside git and from older pushes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    git: Option<git_back::GitBase>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct Pushed {
    sha256: String,
    permissions: u32,
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
    if matches!(args.first().map(String::as_str), Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return 0;
    }
    let Some((action, socket, local, remote)) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    if action == Action::Pull {
        return finish_pull(pull::pull(&socket, &local, &remote));
    }
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

/// Prints a pull's answer line and returns its exit code.
fn finish_pull(pulled: anyhow::Result<pull::Pulled>) -> i32 {
    let line = match pulled {
        Ok(pull::Pulled::Done(summary)) => {
            println!("{summary}");
            return 0;
        }
        Ok(pull::Pulled::Conflict(conflicts, reasons)) => {
            let mut error = format!(
                "{} changed both here and on the machine; nothing was brought back",
                conflicts.join(", ")
            );
            if !reasons.is_empty() {
                error = format!("{error} ({})", reasons.join("; "));
            }
            json!({ "ok": false, "error": error, "error_code": "sync_conflict",
                    "conflicts": conflicts })
        }
        Err(error) => json!({ "ok": false, "error": format!("{error:#}"),
                              "error_code": pull::failure_code(&error) }),
    };
    println!("{line}");
    1
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Action {
    Push,
    Pull,
}

fn parse(args: &[String]) -> Option<(Action, PathBuf, PathBuf, String)> {
    let [action, rest @ ..] = args else { return None };
    let action = match action.as_str() {
        "push" => Action::Push,
        "pull" => Action::Pull,
        _ => return None,
    };
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
    Some((action, socket?, PathBuf::from(local), remote.trim_end_matches('/').to_string()))
}

fn push(socket: &Path, local: &Path, remote_root: &str) -> anyhow::Result<Summary> {
    let local =
        std::fs::canonicalize(local).with_context(|| format!("cannot open {}", local.display()))?;
    let mut set = local::collect(&local)?;
    let manifest_name = if set.git { ".git/cmux-sync.json" } else { ".cmux-sync.json" };
    // The manifest's own name is never pushed over it.
    if set.files.remove(manifest_name).is_some() {
        set.skipped += 1;
    }
    let mut summary = Summary { skipped: set.skipped, ..Summary::default() };
    // What a pull compares the machine's branch and staged changes with.
    let git = if set.git { Some(git_back::base_of(&local)?) } else { None };
    let mut remote = Remote::connect(socket)?;
    remote.mkdir_all(remote_root)?;
    let manifest_path = format!("{remote_root}/{manifest_name}");
    let mut previous: Manifest = remote
        .read(&manifest_path)?
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    // A key that is not a plain relative path (empty, absolute, `.` or `..`
    // parts) names nothing this push made: it is dropped, never deleted.
    previous.files.retain(|relative, _| plain_relative(relative));
    let mut listings = Listings::default();

    // Deletes first, so a file that became a folder (or the reverse) is out
    // of the way. Only a file still as this push left it goes; one the
    // machine changed since stays.
    for (relative, pushed) in &previous.files {
        if set.files.contains_key(relative) {
            continue;
        }
        let target = format!("{remote_root}/{relative}");
        if listings.revision(&mut remote, &target)?.as_deref() == Some(pushed.revision.as_str()) {
            remote.delete(std::slice::from_ref(&target))?;
            summary.deleted += 1;
        }
        let (parent, name) = remote::split(&target)?;
        remote.delete(&[format!("{parent}/.{name}.cmux-sync-part")])?;
    }
    listings.clear();

    let mut made: BTreeSet<String> = BTreeSet::new();
    let mut next = Manifest { version: 1, files: BTreeMap::new(), git };
    for (relative, file) in &set.files {
        let target = format!("{remote_root}/{relative}");
        let (parent, _) = remote::split(&target)?;
        let sha256 = hash(file)?;
        if let Some(pushed) = previous.files.get(relative)
            && pushed.sha256 == sha256
            && pushed.permissions == file.permissions
            && listings.revision(&mut remote, &target)?.as_deref() == Some(pushed.revision.as_str())
        {
            summary.unchanged += 1;
            next.files.insert(relative.clone(), pushed.clone());
            continue;
        }
        if made.insert(parent.to_string()) {
            remote.mkdir_all(parent)?;
        }
        let revision = write(&mut remote, &target, file)?;
        summary.written += 1;
        summary.bytes += size(file)?;
        next.files
            .insert(relative.clone(), Pushed { sha256, permissions: file.permissions, revision });
    }

    let manifest = serde_json::to_vec(&next)?;
    remote
        .write(&manifest_path, &mut manifest.as_slice(), 0o600)
        .context("cannot save the sync manifest")?;
    // A pull's base is this copy, never the machine's.
    base::save(&local, remote_root, &next).context("cannot keep the sync record on this Mac")?;
    Ok(summary)
}

/// Writes `file` to `target`. An empty folder in the way (left by a folder
/// that became a file) is removed first; a folder with anything in it stays
/// and the write fails.
fn write(remote: &mut Remote, target: &str, file: &LocalFile) -> anyhow::Result<String> {
    if remote.kind(target)?.as_deref() == Some("dir")
        && remote.list(target)?.is_some_and(|entries| entries.is_empty())
    {
        remote.delete(&[target.to_string()])?;
    }
    let mut reader = open(file)?;
    remote.write(target, &mut reader, file.permissions)
}

/// A relative path of plain names: no empty, `.` or `..` part.
fn plain_relative(relative: &str) -> bool {
    !relative.is_empty() && relative.split('/').all(|name| !matches!(name, "" | "." | ".."))
}

/// Folder listings of the machine, fetched once per folder.
#[derive(Default)]
struct Listings(BTreeMap<String, Option<BTreeMap<String, RemoteEntry>>>);

impl Listings {
    /// The revision of the file at `target`; None when it is missing or not
    /// a file.
    fn revision(&mut self, remote: &mut Remote, target: &str) -> anyhow::Result<Option<String>> {
        let (parent, name) = remote::split(target)?;
        if !self.0.contains_key(parent) {
            let listing = remote.list(parent)?;
            self.0.insert(parent.to_string(), listing);
        }
        Ok(self.0[parent]
            .as_ref()
            .and_then(|entries| entries.get(name))
            .filter(|entry| entry.kind == "file")
            .and_then(|entry| entry.revision.clone()))
    }

    fn clear(&mut self) {
        self.0.clear();
    }
}

/// Opens `file` without following a symlink or blocking on a FIFO swapped
/// in since it was listed; anything but a regular file is refused.
fn open(file: &LocalFile) -> anyhow::Result<Box<dyn std::io::Read>> {
    Ok(match &file.source {
        Source::File(path) => {
            let opened = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(path)
                .with_context(|| format!("cannot read {}", path.display()))?;
            if !opened.metadata()?.is_file() {
                anyhow::bail!("{} is no longer a regular file", path.display());
            }
            Box::new(opened)
        }
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
