//! `cmux link start-chat project`: a chat's folder reaches its Cloud machine as a projection
//! instead of a copy (projected folders, stage 3). This Mac sends only a stat-only manifest of
//! the folder; the machine mounts it (`projfs.mount`) and asks for bytes as it reads them, which
//! `project-serve` ([`super::projected_serve`]) answers.
//!
//! `project --key K --account A --machine ID --socket PATH --local FOLDER [--subpath SUB]
//! --work-root R...` (the arguments `copy` takes, meaning the same):
//!
//! 1. walks FOLDER with the copy's own walk and skip rules, looking at every file and opening
//!    none (`sync_cli::stat_listing`);
//! 2. builds and encodes the manifest (`cmux_projfs::Builder`);
//! 3. picks the chat's folder on the machine as `copy` does (`<root>/chats/<key>/<8hex>/
//!    <name>-<fnv6>`), with the helper's state folder beside it (`<root>/chats/<key>/<8hex>/
//!    .projfs`, inside the work root and outside the mounted folder);
//! 4. sends the manifest there (`fs.mkdir`, `fs.write` in parts) and asks `projfs.mount`;
//! 5. keeps this Mac's copy of the manifest and a record of the mount in this Mac's state
//!    folder, beside the start-chat ledger: `cloud-start-chat/projected/<mount>/` holds
//!    `record.json`, `manifest.cmpf` and `rewritten.json` (the git files the copy rewrites,
//!    served as rewritten). The folder appears whole or not at all (written aside, renamed).
//!
//! It prints one JSON line: `{"ok":true,"mode":"projected","mount","machine_path","folder",
//! "entries","bytes","skipped","ms":{"walk","encode","upload","mount","total"}}`, or on any
//! failure `{"ok":false,"code","message","fallback":"copy"}` with exit 1, leaving nothing mounted
//! and no record on this Mac.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use cmux_projfs::{Builder, Manifest, Stat};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::super::sync_cli::{self, ListedKind, Listing, Times};
use super::{Flags, PERMISSION_DENIED, StartCopy, join, too_broad};

/// The name of a mount's record in its folder.
pub(super) const RECORD: &str = "record.json";
/// The name of this Mac's copy of a mount's manifest.
pub(super) const MANIFEST: &str = "manifest.cmpf";
/// The name of the rewritten git files of a mount (path to base64).
pub(super) const REWRITTEN: &str = "rewritten.json";

/// What this Mac keeps about one projected folder (`record.json`).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct Record {
    pub mount: String,
    pub account: String,
    pub machine: String,
    /// The folder on this Mac the projection shows.
    pub local_root: String,
    /// The chat's folder on the machine (the mounted folder, or `subpath` in it).
    pub machine_path: String,
    /// The mounted folder on the machine.
    pub folder: String,
    /// The helper's state folder on the machine.
    pub state_dir: String,
    /// The socket that reaches the machine's daemon from this Mac.
    pub socket: String,
    /// When it was mounted, in milliseconds since the Unix epoch.
    pub made_at: u64,
}

/// `project`, `project-serve` and `project-pull`; `None` on bad usage.
pub(super) fn cli(action: &str, flags: &Flags, ledger: &Path) -> Option<Value> {
    let base = ledger.parent()?.join("projected");
    match action {
        "project" => StartCopy::of(flags).map(|copy| start(&copy, &base)),
        "project-pull" => pull::cli(flags, &base),
        _ => super::projected_serve::cli(flags, &base),
    }
}

/// `project-pull`: the machine's edits back to this Mac.
#[path = "projected_pull.rs"]
mod pull;

/// A refusal in this command's shape: the App copies the folder instead.
pub(super) fn refused(code: &str, message: impl std::fmt::Display) -> Value {
    json!({"ok": false, "code": code, "message": message.to_string(), "fallback": "copy"})
}

/// The mount id of a send's projection in `place` (`chats/<key>/<8hex>`): plain characters,
/// at most 47 of them.
pub(super) fn mount_id(key: &str, place: &str) -> String {
    let id = place.rsplit('/').next().unwrap_or_default();
    format!("p-{}-{id}", key.to_lowercase())
}

fn ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

fn now_ns() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|since| i64::try_from(since.as_nanos()).ok())
        .unwrap_or_default()
}

/// Runs `project` for `copy`, keeping its record under `base`.
fn start(copy: &StartCopy, base: &Path) -> Value {
    let started = Instant::now();
    if too_broad(&copy.local, std::env::var_os("HOME").map(PathBuf::from).as_deref()) {
        let why = format!("{} is too broad for a Cloud machine; pick a project folder", copy.local);
        return refused("folder_too_broad", why);
    }
    let listing = match sync_cli::stat_listing(Path::new(&copy.local)) {
        Ok(listing) => listing,
        Err(error) => return refused("walk_failed", format!("{error:#}")),
    };
    let t_walk = ms(started);
    let encoding = Instant::now();
    let made_at = now_ns();
    let built = build(Path::new(&copy.local), &listing, made_at)
        .and_then(|(manifest, rewritten)| Ok((manifest.encode()?, manifest, rewritten)));
    let (bytes, manifest, rewritten) = match built {
        Ok(built) => built,
        Err(error) => return refused("manifest_failed", error),
    };
    let t_encode = ms(encoding);
    let place = copy.fresh_place();
    let mount = mount_id(&copy.key, &place);
    let staging = base.join(format!(".{mount}.part"));
    let answer = stage(&staging, &bytes, &rewritten).map_err(|error| {
        refused("record_failed", format!("cannot keep the manifest on this Mac: {error}"))
    });
    let answer = answer.and_then(|()| {
        let sent = Sent { mount: &mount, place: &place, staging: &staging, base };
        sent.mount_on_a_root(copy, &manifest, (t_walk, t_encode, started))
    });
    match answer {
        Ok(done) => done,
        Err(failure) => {
            let _ = std::fs::remove_dir_all(&staging);
            failure
        }
    }
}

/// The manifest of `listing` (a walk of `root`) and the rewritten files it serves: every
/// folder on the way to a listed path, with its own stat; git's rewritten files dated `made_at`.
pub(super) fn build(
    root: &Path,
    listing: &Listing,
    made_at: i64,
) -> Result<(Manifest, BTreeMap<String, Vec<u8>>), cmux_projfs::ManifestError> {
    let folder_stat = |path: &Path| {
        std::fs::symlink_metadata(path)
            .ok()
            .filter(std::fs::Metadata::is_dir)
            .map(|meta| sync_cli::times_of(&meta))
            .map_or_else(|| Stat::dir(0o755, 0, 0), |t| Stat::dir(t.mode, t.mtime_ns, t.ctime_ns))
    };
    let mut builder = Builder::new(&root.to_string_lossy());
    builder.root_stat(folder_stat(root))?;
    let folders: BTreeSet<&str> = listing
        .entries
        .iter()
        .flat_map(|entry| {
            entry.path.match_indices('/').filter_map(|(slash, _)| entry.path.get(..slash))
        })
        .collect();
    for folder in folders {
        builder.add(folder, folder_stat(&root.join(folder)))?;
    }
    let mut rewritten = BTreeMap::new();
    for entry in &listing.entries {
        let Times { mode, size, mtime_ns, ctime_ns } = entry.times;
        let stat = match &entry.kind {
            ListedKind::File => Stat::file(mode, size, mtime_ns, ctime_ns),
            ListedKind::Withheld => {
                Stat { withheld: true, ..Stat::file(mode, size, mtime_ns, ctime_ns) }
            }
            ListedKind::Link(target) => Stat::symlink(target, mtime_ns, ctime_ns),
            ListedKind::Rewritten(bytes) => {
                rewritten.insert(entry.path.clone(), bytes.clone());
                Stat::file(mode, size, made_at, made_at)
            }
        };
        builder.add(&entry.path, stat)?;
    }
    builder.add_skipped(listing.skipped);
    Ok((builder.build()?, rewritten))
}

/// Writes a mount's files into `dir` (made, private): the manifest and the rewritten files.
pub(super) fn stage(
    dir: &Path,
    manifest: &[u8],
    rewritten: &BTreeMap<String, Vec<u8>>,
) -> std::io::Result<()> {
    let _ = std::fs::remove_dir_all(dir);
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    write_private(&dir.join(MANIFEST), manifest)?;
    let encoded: BTreeMap<&str, String> = rewritten
        .iter()
        .map(|(path, bytes)| {
            (path.as_str(), base64::engine::general_purpose::STANDARD.encode(bytes))
        })
        .collect();
    write_private(&dir.join(REWRITTEN), &serde_json::to_vec(&encoded)?)
}

/// Writes `bytes` to `path` whole or not at all: to a name of its own beside it, synced, then
/// renamed over it.
pub(super) fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let part = path.with_extension(format!("{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(&part, path)
}

/// A projection whose files are staged on this Mac, going to the machine.
struct Sent<'a> {
    mount: &'a str,
    place: &'a str,
    staging: &'a Path,
    base: &'a Path,
}

impl Sent<'_> {
    /// Sends the manifest and mounts it under the first work root this machine's user may
    /// write (as `copy` tries them), then keeps the record. `times`: the walk's and the
    /// encoding's milliseconds, and when the command started.
    fn mount_on_a_root(
        &self,
        copy: &StartCopy,
        manifest: &Manifest,
        times: (u64, u64, Instant),
    ) -> Result<Value, Value> {
        let (t_walk, t_encode, started) = times;
        let mut last = refused("upload_failed", "no work root to send the manifest to");
        for root in &copy.work_roots {
            let (folder, chat) = copy.remote(root, self.place);
            let state = join(&join(root, self.place), ".projfs");
            let uploading = Instant::now();
            match send(&copy.socket, &self.staging.join(MANIFEST), &folder, &state) {
                Ok(()) => {}
                Err((code, message)) => {
                    let next = code == PERMISSION_DENIED;
                    last = refused(&code, message);
                    if next {
                        continue;
                    }
                    return Err(last);
                }
            }
            let t_upload = ms(uploading);
            let mounting = Instant::now();
            let mounted = mount(&copy.socket, self.mount, &folder, &state)?;
            let t_mount = ms(mounting);
            let record = Record {
                mount: self.mount.to_owned(),
                account: copy.account.clone(),
                machine: copy.machine.clone(),
                local_root: copy.local.clone(),
                machine_path: chat.clone(),
                folder: folder.clone(),
                state_dir: state.clone(),
                socket: copy.socket.display().to_string(),
                made_at: u64::try_from(now_ns() / 1_000_000).unwrap_or_default(),
            };
            if let Err(error) = self.keep(&record) {
                let _ = unmount(&copy.socket, &folder, &state);
                return Err(refused("record_failed", format!("cannot keep the record: {error}")));
            }
            return Ok(json!({
                "ok": true,
                "mode": "projected",
                "mount": self.mount,
                "machine_path": chat,
                "folder": folder,
                "entries": manifest.len(),
                "bytes": manifest.total_bytes(),
                "skipped": manifest.skipped(),
                "helper": mounted,
                "ms": {
                    "walk": t_walk, "encode": t_encode, "upload": t_upload, "mount": t_mount,
                    "total": ms(started),
                },
            }));
        }
        Err(last)
    }

    /// Writes the record into the staged folder and moves the folder into place.
    fn keep(&self, record: &Record) -> std::io::Result<()> {
        write_private(&self.staging.join(RECORD), &serde_json::to_vec_pretty(record)?)?;
        let target = self.base.join(self.mount);
        let _ = std::fs::remove_dir_all(&target);
        std::fs::rename(self.staging, &target)
    }
}

/// The machine's code and message of a failed request.
fn failure(error: &anyhow::Error, fallback: &str) -> (String, String) {
    let code = sync_cli::refusal_code(error).unwrap_or(fallback).to_owned();
    (code, format!("{error:#}"))
}

/// Sends the manifest at `local` into `state` on the machine and makes the folder `folder`.
fn send(socket: &Path, local: &Path, folder: &str, state: &str) -> Result<(), (String, String)> {
    sync_cli::copy_file(socket, local, &join(state, MANIFEST))
        .map_err(|error| failure(&error, "upload_failed"))?;
    let (parent, name) = folder.rsplit_once('/').unwrap_or(("/", folder));
    let made = sync_cli::machine_call(socket, "fs.mkdir", json!({"path": parent, "name": name}));
    match made {
        Ok(_) => Ok(()),
        Err(error) if sync_cli::refusal_code(&error) == Some("fs.exists") => Ok(()),
        Err(error) => Err(failure(&error, "upload_failed")),
    }
}

/// `projfs.mount`: the helper's ready line, or the refusal in this command's shape.
fn mount(socket: &Path, mount: &str, folder: &str, state: &str) -> Result<Value, Value> {
    let params = json!({
        "mount": mount, "manifest": join(state, MANIFEST), "at": folder, "state": state,
    });
    let line = sync_cli::machine_call(socket, "projfs.mount", params).map_err(|error| {
        let (code, message) = failure(&error, "mount_failed");
        refused(&code, message)
    })?;
    if line.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(line);
    }
    let code = line.get("code").and_then(Value::as_str).unwrap_or("mount_failed");
    let message = line.get("message").and_then(Value::as_str).unwrap_or("the mount was refused");
    Err(refused(code, message))
}

/// `projfs.unmount` of a mount whose record could not be kept.
fn unmount(socket: &Path, folder: &str, state: &str) -> anyhow::Result<Value> {
    sync_cli::machine_call(socket, "projfs.unmount", json!({"at": folder, "state": state}))
}

#[cfg(test)]
#[path = "projected_tests.rs"]
mod tests;
