//! `cmux link memory pull|propose|push`: the person's agent memory and
//! instructions follow them to every machine (plans/cloud/
//! agent-memory-follows-user.md in cmuxterm-hq, step 3).
//!
//! - `pull` brings the head (the accepted manifest) to this machine: each
//!   carried file is merged three ways against the manifest this machine last
//!   synced, with link sync's line merge (diff3; overlapping edits keep this
//!   machine's file and put the merge beside it as `NAME.cmux-sync-conflict`).
//!   A machine's start runs it before any session starts.
//! - `propose` sends what changed here since the last sync as a patch against
//!   that revision. It never moves the head: only the person's acceptance does.
//!   A machine's turn end and pause run it, and the Mac runs it when a carried
//!   file changes.
//! - `push` is a pull and then a propose, so the proposal is based on the head
//!   as it is now and applies as is once accepted.
//!
//! Revocation fences everything by generation. Before anything else, a pull
//! that finds the head gone, or at a newer generation than the files this
//! machine carries, deletes every carried file (an agent's later edit too) and
//! writes back each original that a carried file replaced. A failed check
//! exits non-zero, so no session starts.
//!
//! Every read, write, move-aside, restore and delete in the home runs as the
//! agent user (`--user`: the thread's filesystem uid on Linux) and walks from
//! a folder descriptor one name at a time with `O_NOFOLLOW` ([`place::Dir`]).
//! A link planted anywhere on the way is refused and the operation stops. The
//! record of what was carried (path and hash) and the originals' bytes stay
//! with the caller (`cmux-vm-agent`, root) under `--record`
//! (`/var/lib/cmux/agent-home/` as root), owner-only, outside the agent
//! user's reach.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read as _;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::Arc;

use anyhow::{Context as _, bail};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest as _, Sha256};

use super::merge;
use super::place::{self, Dir, Entry};

/// Largest carried file: memory notes and instructions are small.
pub(super) const FILE_MAX: u64 = 1024 * 1024;

/// The record folder when the caller is root (`cmux-vm-agent`).
pub(super) const ROOT_RECORD: &str = "/var/lib/cmux/agent-home";

/// One carried file in a manifest: its content hash and permissions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Item {
    pub sha256: String,
    pub mode: u32,
}

/// Carried files by their path under the home.
pub(super) type Manifest = BTreeMap<String, Item>;

/// The accepted head.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub(super) struct Accepted {
    pub revision: u64,
    pub manifest: Manifest,
}

/// What a head read answers: the revocation generation, and the head when
/// there is one (none: the setting is off or the person revoked it).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub(super) struct HeadRead {
    pub generation: u64,
    pub head: Option<Accepted>,
}

/// A device's proposal: a patch (an entry to add or change, or `None` to
/// remove it) against the revision it last pulled.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(super) struct Proposal {
    pub device: String,
    pub generation: u64,
    pub base_revision: u64,
    pub patch: BTreeMap<String, Option<Item>>,
}

/// The per-person head (`AgentHome`). Nothing here moves it: a device only
/// reads it, stores blobs and proposes.
pub(super) trait Head {
    fn read(&self) -> anyhow::Result<HeadRead>;
    fn blob(&self, generation: u64, sha256: &str) -> anyhow::Result<Option<Vec<u8>>>;
    fn put_blob(&self, generation: u64, bytes: &[u8]) -> anyhow::Result<String>;
    fn propose(&self, proposal: &Proposal) -> anyhow::Result<String>;
    /// Whether the head keeps each file's permissions. A folder head does;
    /// the `AgentHome` service carries text only, and every file it holds
    /// reads `0o644`, so there a mode alone is never a change.
    fn keeps_modes(&self) -> bool {
        true
    }
    /// Whether a proposal to this head may carry `key` (the service refuses
    /// a whole proposal over one path it does not take).
    fn takes(&self, _key: &str) -> bool {
        true
    }
    /// Accepts this device's own proposal `id`, based on `base_revision`,
    /// when this device is the person's own (Leo, 2026-11-27, of the Accept
    /// in Session Info: "get rid of it"): the new head revision. `None`: the
    /// proposal waits for the person (a machine never accepts).
    fn accept_own(&self, _id: &str, _base_revision: u64) -> anyhow::Result<Option<u64>> {
        Ok(None)
    }
}

/// A head kept in a folder: `head.json`, `blobs/g<generation>/<sha256>`,
/// `proposals/<id>.json`. Tests use it, and a person can point machines at a
/// shared folder (`--head DIR`); `--head https://HOST` is the `AgentHome`
/// service ([`http::HttpHead`]).
pub(super) struct DirHead {
    pub root: PathBuf,
}

impl DirHead {
    fn blob_path(&self, generation: u64, sha256: &str) -> anyhow::Result<PathBuf> {
        if sha256.len() != 64 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            bail!("not a blob hash: {sha256}");
        }
        Ok(self.root.join("blobs").join(format!("g{generation}")).join(sha256))
    }

    fn write_json(path: &Path, value: &impl Serialize) -> anyhow::Result<()> {
        let part = path.with_extension(format!("part-{}", std::process::id()));
        std::fs::write(&part, serde_json::to_vec_pretty(value)?)?;
        std::fs::rename(&part, path)?;
        Ok(())
    }

    /// The person accepts proposal `id` (what the `AgentHome` acceptance
    /// does): applied to the head when it is at the proposal's base, refused
    /// otherwise. Only the head's owner calls this, never the CLI.
    #[cfg(test)]
    pub(super) fn accept(&self, id: &str) -> anyhow::Result<u64> {
        let proposal: Proposal = serde_json::from_slice(&std::fs::read(
            self.root.join("proposals").join(format!("{id}.json")),
        )?)?;
        let mut read = self.read()?;
        if proposal.generation != read.generation {
            bail!("the proposal is from generation {}", proposal.generation);
        }
        let mut head = read.head.take().context("no head")?;
        if head.revision != proposal.base_revision {
            bail!("the head moved: {} != {}", head.revision, proposal.base_revision);
        }
        for (key, item) in proposal.patch {
            match item {
                Some(item) => head.manifest.insert(key, item),
                None => head.manifest.remove(&key),
            };
        }
        head.revision += 1;
        let revision = head.revision;
        read.head = Some(head);
        Self::write_json(&self.root.join("head.json"), &read)?;
        Ok(revision)
    }

    /// Sets the head (tests): `None` revokes it, and every write bumps the
    /// generation when asked.
    #[cfg(test)]
    pub(super) fn set(&self, generation: u64, head: Option<Accepted>) -> anyhow::Result<()> {
        std::fs::create_dir_all(&self.root)?;
        Self::write_json(&self.root.join("head.json"), &HeadRead { generation, head })
    }
}

impl Head for DirHead {
    fn read(&self) -> anyhow::Result<HeadRead> {
        match std::fs::read(self.root.join("head.json")) {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes).context("head.json")?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(HeadRead::default()),
            Err(error) => Err(error.into()),
        }
    }

    fn blob(&self, generation: u64, sha256: &str) -> anyhow::Result<Option<Vec<u8>>> {
        match std::fs::read(self.blob_path(generation, sha256)?) {
            Ok(bytes) => Ok((sha256_hex(&bytes) == sha256).then_some(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    fn put_blob(&self, generation: u64, bytes: &[u8]) -> anyhow::Result<String> {
        let sha256 = sha256_hex(bytes);
        let path = self.blob_path(generation, &sha256)?;
        if !path.exists() {
            std::fs::create_dir_all(path.parent().context("blob folder")?)?;
            let part = path.with_extension(format!("part-{}", std::process::id()));
            std::fs::write(&part, bytes)?;
            std::fs::rename(&part, &path)?;
        }
        Ok(sha256)
    }

    fn propose(&self, proposal: &Proposal) -> anyhow::Result<String> {
        let read = self.read()?;
        if proposal.generation != read.generation || read.head.is_none() {
            bail!("refused: the proposal's generation {} is not the head's", proposal.generation);
        }
        let folder = self.root.join("proposals");
        std::fs::create_dir_all(&folder)?;
        let bytes = serde_json::to_vec(proposal)?;
        let id: String = sha256_hex(&bytes).chars().take(16).collect();
        Self::write_json(&folder.join(format!("{id}.json")), proposal)?;
        Ok(id)
    }
}

/// What this machine carries, kept by the caller (root on a Cloud machine).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub(super) struct Record {
    /// The generation every carried file was written under.
    pub generation: u64,
    /// The head revision last synced, and its manifest (every merge's base).
    pub revision: u64,
    pub base: Manifest,
    /// Each file a pull wrote: the hash it wrote, and the original it
    /// replaced (its bytes under `originals/<sha256>`), if any.
    pub carried: BTreeMap<String, Carried>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Carried {
    pub sha256: String,
    pub original: Option<Item>,
}

/// The record's folder: owner-only, never a link, never in the agent's home.
pub(super) struct RecordStore {
    pub root: PathBuf,
}

impl RecordStore {
    fn open(&self) -> anyhow::Result<()> {
        use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
        for dir in [self.root.clone(), self.root.join("originals")] {
            match std::fs::symlink_metadata(&dir) {
                Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => {
                    bail!("{} is not a folder: refused", dir.display())
                }
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
                }
                Err(error) => return Err(error.into()),
            }
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }

    fn write_private(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        let part = path.with_extension(format!("part-{}", std::process::id()));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&part)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&part, path)?;
        Ok(())
    }

    pub(super) fn load(&self) -> anyhow::Result<Record> {
        self.open()?;
        match std::fs::read(self.root.join("record.json")) {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes).context("record.json")?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Record::default()),
            Err(error) => Err(error.into()),
        }
    }

    pub(super) fn save(&self, record: &Record) -> anyhow::Result<()> {
        Self::write_private(&self.root.join("record.json"), &serde_json::to_vec_pretty(record)?)
    }

    fn keep_original(&self, bytes: &[u8]) -> anyhow::Result<String> {
        let sha256 = sha256_hex(bytes);
        Self::write_private(&self.root.join("originals").join(&sha256), bytes)?;
        Ok(sha256)
    }

    fn original(&self, sha256: &str) -> anyhow::Result<Vec<u8>> {
        let bytes = std::fs::read(self.root.join("originals").join(sha256))?;
        if sha256_hex(&bytes) != sha256 {
            bail!("the kept original {sha256} does not match its hash");
        }
        Ok(bytes)
    }

    fn drop_original(&self, sha256: &str) {
        let _ = std::fs::remove_file(self.root.join("originals").join(sha256));
    }
}

/// The agent user's home, opened by descriptor.
pub(super) struct Home {
    root: Dir,
}

/// One file as it is in the home now.
#[derive(Clone)]
pub(super) struct Local {
    pub bytes: Vec<u8>,
    pub item: Item,
}

impl Home {
    fn read(&self, relative: &str) -> anyhow::Result<Option<Local>> {
        let Some((dir, name)) = place::parent_of(&self.root, relative)
            .with_context(|| format!("{relative}: a folder on the way is not a folder"))?
        else {
            return Ok(None);
        };
        match dir.entry(&name)? {
            Entry::Missing => Ok(None),
            Entry::File { mode } => {
                let mut bytes = Vec::new();
                dir.open_file(&name)?.take(FILE_MAX + 1).read_to_end(&mut bytes)?;
                if bytes.len() as u64 > FILE_MAX {
                    bail!("{relative} is over {FILE_MAX} bytes");
                }
                let sha256 = sha256_hex(&bytes);
                Ok(Some(Local { bytes, item: Item { sha256, mode: mode & 0o777 } }))
            }
            _ => bail!("{relative} is not a regular file here: refused"),
        }
    }

    fn write(&self, relative: &str, bytes: &[u8], mode: u32) -> anyhow::Result<()> {
        let (folders, name) = relative.rsplit_once('/').unwrap_or(("", relative));
        let mut at: Option<Dir> = None;
        for part in folders.split('/').filter(|part| !part.is_empty()) {
            let next = at
                .as_ref()
                .unwrap_or(&self.root)
                .child_or_make(part)
                .with_context(|| format!("{relative}: {part} on the way is not a folder"))?;
            at = Some(next);
        }
        at.as_ref()
            .unwrap_or(&self.root)
            .replace_file(name, bytes, carried_mode(mode))
            .with_context(|| format!("writing {relative}"))
    }

    fn remove(&self, relative: &str) -> anyhow::Result<()> {
        let Some((dir, name)) = place::parent_of(&self.root, relative)
            .with_context(|| format!("{relative}: a folder on the way is not a folder"))?
        else {
            return Ok(());
        };
        dir.remove_file(&name).with_context(|| format!("removing {relative}"))
    }

    /// The carried files present here (the allowlist), never through a link.
    fn scan(&self) -> anyhow::Result<BTreeSet<String>> {
        let mut found = self.scan_all()?;
        found.retain(|relative| carried(relative));
        Ok(found)
    }

    /// Every regular file under the allowlisted places, before any name check
    /// (`plan` names each one it refuses), never through a link.
    fn scan_all(&self) -> anyhow::Result<BTreeSet<String>> {
        let mut found = BTreeSet::new();
        for file in ROOT_FILES {
            if let Some((dir, name)) = place::parent_of(&self.root, file)?
                && matches!(dir.entry(&name)?, Entry::File { .. })
            {
                found.insert((*file).to_string());
            }
        }
        for folder in TREES {
            walk(&self.root, folder, &mut found)?;
        }
        if let Some(projects) =
            place::parent_of(&self.root, ".claude/projects/x")?.map(|(dir, _)| dir)
        {
            for slug in projects.names()? {
                let Some(slug) = slug.to_str() else { continue };
                if matches!(projects.entry(slug)?, Entry::Dir) {
                    walk(&self.root, &format!(".claude/projects/{slug}/memory"), &mut found)?;
                }
            }
        }
        Ok(found)
    }
}

fn walk(root: &Dir, folder: &str, found: &mut BTreeSet<String>) -> anyhow::Result<()> {
    let Some((parent, name)) = place::parent_of(root, folder).ok().flatten() else {
        return Ok(());
    };
    if !matches!(parent.entry(&name)?, Entry::Dir) {
        return Ok(());
    }
    let mut stack = vec![(folder.to_string(), parent.child(&name)?.context(folder.to_string())?)];
    while let Some((path, dir)) = stack.pop() {
        for name in dir.names()? {
            let Some(name) = name.to_str() else { continue };
            let relative = format!("{path}/{name}");
            match dir.entry(name)? {
                Entry::File { .. } => {
                    found.insert(relative);
                }
                Entry::Dir if found.len() < 10_000 => {
                    if let Some(child) = dir.child(name)? {
                        stack.push((relative, child));
                    }
                }
                _ => {}
            }
        }
    }
    Ok(())
}

/// Single files carried from the home.
const ROOT_FILES: &[&str] = &[".claude/CLAUDE.md", ".codex/AGENTS.md", ".gemini/GEMINI.md"];
/// Folders carried whole.
const TREES: &[&str] = &[".claude/agents", ".claude/commands", ".claude/skills", ".codex/prompts"];
/// Longest carried path, in bytes.
pub(super) const PATH_MAX: usize = 512;

/// Whether `relative` (a path under the home) is a carried file: on the
/// allowlist, a plain relative path, and not named like a secret.
pub(super) fn carried(relative: &str) -> bool {
    refusal(relative).is_none()
}

/// Why `relative` is never carried, by its path alone; `None` when it is.
/// A path is checked as it is, never cleaned up into an allowed one.
pub(super) fn refusal(relative: &str) -> Option<&'static str> {
    use unicode_normalization::UnicodeNormalization as _;
    let parts: Vec<&str> = relative.split('/').collect();
    if relative.is_empty()
        || relative.len() > PATH_MAX
        || relative.starts_with('/')
        || parts.iter().any(|part| part.is_empty() || *part == "." || *part == "..")
        || relative.chars().any(|c| c.is_control() || c == '\\')
        || !relative.nfc().eq(relative.chars())
    {
        return Some("path form");
    }
    let name = parts.last().copied().unwrap_or_default().to_ascii_lowercase();
    if merge::is_conflict_file(&name) || name.ends_with(".cmux-sync-part") {
        return Some("sync side file");
    }
    if secret_name(&name) {
        return Some("credential name");
    }
    let allowed = ROOT_FILES.contains(&relative)
        || TREES.iter().any(|tree| relative.starts_with(&format!("{tree}/")))
        || matches!(parts.as_slice(), [".claude", "projects", _, "memory", _, ..]);
    (!allowed).then_some("not on the allowlist")
}

/// A file name (lowercased) that credentials, harness settings or history
/// use: never carried, wherever it sits.
fn secret_name(name: &str) -> bool {
    [
        ".env",
        ".pem",
        ".key",
        ".p12",
        "credential",
        "secret",
        "token",
        "auth.json",
        "id_rsa",
        "id_ed25519",
        "id_ecdsa",
        "id_dsa",
        "netrc",
        ".npmrc",
        ".pypirc",
        "oauth_creds",
        "history.jsonl",
        "config.toml",
    ]
    .iter()
    .any(|word| name.contains(word))
        || (name.starts_with("settings") && name.ends_with(".json"))
}

/// The permissions a carried file gets: the owner always reads and writes,
/// and nothing beyond rwx.
fn carried_mode(mode: u32) -> u32 {
    (mode & 0o755) | 0o600
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Who and where one run acts.
pub(super) struct Ctx<'a> {
    pub home: PathBuf,
    /// The agent user's (uid, gid) every home access runs as (root callers).
    pub user: Option<(u32, u32)>,
    pub record: RecordStore,
    pub head: &'a dyn Head,
    pub device: String,
    /// A Cloud machine (`cmux-vm-agent` runs it as root): a file it already
    /// had where a carried one lands is an original, kept aside and replaced.
    /// On the person's own Mac it is theirs, and merges like any change.
    pub machine: bool,
    /// Tests: runs before each home access with its path, to race it.
    #[cfg(test)]
    pub race: Option<RaceHook>,
}

/// Tests: the hook `Ctx::race` runs.
#[cfg(test)]
pub(crate) type RaceHook = Arc<dyn Fn(&str) + Send + Sync>;

impl Ctx<'_> {
    /// Runs `f` on the home as the agent user, in a thread of its own whose
    /// filesystem uid and gid are the agent's (Linux): the kernel checks every
    /// access as that user, and root's override is gone for that thread.
    fn as_agent<R: Send>(
        &self,
        f: impl FnOnce(&Home, &dyn Fn(&str)) -> anyhow::Result<R> + Send,
    ) -> anyhow::Result<R> {
        let home = self.home.clone();
        let user = self.user;
        #[cfg(test)]
        let race = self.race.clone();
        std::thread::scope(|scope| {
            scope
                .spawn(move || {
                    if let Some((uid, gid)) = user {
                        set_fs_ids(uid, gid)?;
                    }
                    let home = Home {
                        root: Dir::open(&home)
                            .with_context(|| format!("{} is not a folder", home.display()))?,
                    };
                    #[cfg(test)]
                    let hook = move |relative: &str| {
                        if let Some(race) = &race {
                            race(relative);
                        }
                    };
                    #[cfg(not(test))]
                    let hook = |_: &str| {};
                    f(&home, &hook)
                })
                .join()
                .map_err(|_| anyhow::anyhow!("the home writer panicked"))?
        })
    }
}

#[cfg(target_os = "linux")]
fn set_fs_ids(uid: u32, gid: u32) -> anyhow::Result<()> {
    // SAFETY: plain syscalls on this thread's own credentials; each answers
    // the previous id, and a second call with the same id confirms it.
    unsafe {
        libc::setfsgid(gid);
        libc::setfsuid(uid);
        if libc::setfsgid(gid) as u32 != gid || libc::setfsuid(uid) as u32 != uid {
            bail!("could not act as uid {uid}");
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn set_fs_ids(uid: u32, _gid: u32) -> anyhow::Result<()> {
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } == uid {
        return Ok(());
    }
    bail!("--user is Linux only; run as that user here")
}

/// What one run did, printed as JSON.
#[derive(Debug, Default, Serialize)]
pub(super) struct Outcome {
    pub revision: Option<u64>,
    pub generation: u64,
    pub written: Vec<String>,
    pub deleted: Vec<String>,
    pub restored: Vec<String>,
    pub merged: Vec<String>,
    pub conflicts: Vec<String>,
    pub kept_local: Vec<String>,
    pub proposal: Option<String>,
    pub proposed: Vec<String>,
    /// A person's push: the head revision their own device accepted its
    /// proposal at.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accepted_revision: Option<u64>,
}

/// Deletes every carried file and writes back each original it replaced.
fn revoke_local(ctx: &Ctx<'_>, record: &mut Record, out: &mut Outcome) -> anyhow::Result<()> {
    let mut originals = BTreeMap::new();
    for (relative, carried) in &record.carried {
        if let Some(original) = &carried.original {
            originals
                .insert(relative.clone(), (ctx.record.original(&original.sha256)?, original.mode));
        }
    }
    let carried: Vec<String> = record.carried.keys().cloned().collect();
    let (deleted, restored) = ctx.as_agent(|home, race| {
        let (mut deleted, mut restored) = (Vec::new(), Vec::new());
        for relative in &carried {
            race(relative);
            match originals.get(relative) {
                Some((bytes, mode)) => {
                    home.write(relative, bytes, *mode)?;
                    restored.push(relative.clone());
                }
                None => {
                    home.remove(relative)?;
                    deleted.push(relative.clone());
                }
            }
        }
        Ok((deleted, restored))
    })?;
    for carried in record.carried.values() {
        if let Some(original) = &carried.original {
            ctx.record.drop_original(&original.sha256);
        }
    }
    record.carried.clear();
    record.base.clear();
    record.revision = 0;
    out.deleted.extend(deleted);
    out.restored.extend(restored);
    Ok(())
}

/// What one key's merge decided.
enum Step {
    Write { bytes: Vec<u8>, mode: u32 },
    Remove,
    Conflict { bytes: Vec<u8> },
    Keep,
}

/// `pull`: fences by generation, then merges the head into the home.
pub(super) fn pull(ctx: &Ctx<'_>) -> anyhow::Result<Outcome> {
    let read = ctx.head.read().context("reading the head")?;
    let mut record = ctx.record.load()?;
    let mut out = Outcome { generation: read.generation, ..Outcome::default() };
    let stale = record.generation != read.generation || read.head.is_none();
    if stale && (!record.carried.is_empty() || !record.base.is_empty()) {
        revoke_local(ctx, &mut record, &mut out)?;
    }
    record.generation = read.generation;
    let Some(head) = read.head else {
        ctx.record.save(&record)?;
        return Ok(out);
    };
    for key in head.manifest.keys() {
        if !carried(key) {
            bail!("the head carries {key}, which is not a carried path: refused");
        }
    }
    let keys: BTreeSet<String> = record.base.keys().chain(head.manifest.keys()).cloned().collect();
    let keys_in: Vec<String> = keys.iter().cloned().collect();
    let local: BTreeMap<String, Local> = ctx.as_agent(|home, race| {
        let mut local = BTreeMap::new();
        for key in &keys_in {
            race(key);
            if let Some(found) = home.read(key)? {
                local.insert(key.clone(), found);
            }
        }
        Ok(local)
    })?;

    let mut steps: BTreeMap<String, Step> = BTreeMap::new();
    for key in &keys {
        let base = record.base.get(key);
        let theirs = head.manifest.get(key);
        let ours = local.get(key);
        let ours_item = ours.map(|local| &local.item);
        let first = ctx.machine && base.is_none() && !record.carried.contains_key(key);
        let step = if ours_item.map(|item| &item.sha256) == theirs.map(|item| &item.sha256) {
            Step::Keep
        } else if first || ours_item.map(|item| &item.sha256) == base.map(|item| &item.sha256) {
            match theirs {
                Some(item) => {
                    Step::Write { bytes: fetch(ctx, read.generation, item)?, mode: item.mode }
                }
                None => Step::Remove,
            }
        } else if theirs.map(|item| &item.sha256) == base.map(|item| &item.sha256) {
            out.kept_local.push(key.clone());
            Step::Keep
        } else {
            match (base, ours, theirs) {
                (Some(base), Some(ours), Some(theirs)) => {
                    let theirs_bytes = fetch(ctx, read.generation, theirs)?;
                    let base_bytes = ctx.head.blob(read.generation, &base.sha256)?;
                    match base_bytes.and_then(|base| merge3(&base, &ours.bytes, &theirs_bytes)) {
                        Some(Ok(bytes)) => {
                            out.merged.push(key.clone());
                            Step::Write { bytes, mode: ours.item.mode }
                        }
                        Some(Err(bytes)) => Step::Conflict { bytes },
                        None => Step::Conflict { bytes: theirs_bytes },
                    }
                }
                // Both added it, differently: this machine's stays, the
                // head's goes beside it.
                (None, Some(_), Some(theirs)) => {
                    Step::Conflict { bytes: fetch(ctx, read.generation, theirs)? }
                }
                // Changed on one side and deleted on the other: the change wins.
                (_, None, Some(theirs)) => {
                    Step::Write { bytes: fetch(ctx, read.generation, theirs)?, mode: theirs.mode }
                }
                _ => {
                    out.kept_local.push(key.clone());
                    Step::Keep
                }
            }
        };
        steps.insert(key.clone(), step);
    }

    // Originals: a file this machine already had where a carried one lands
    // is kept before the first write and comes back on revocation.
    let mut originals: BTreeMap<String, Item> = BTreeMap::new();
    for (key, step) in &steps {
        if matches!(step, Step::Write { .. })
            && !record.carried.contains_key(key)
            && let Some(local) = local.get(key)
        {
            let sha256 = ctx.record.keep_original(&local.bytes)?;
            originals.insert(key.clone(), Item { sha256, mode: local.item.mode });
        }
    }
    let restore: BTreeMap<String, (Vec<u8>, u32)> = steps
        .iter()
        .filter(|(_, step)| matches!(step, Step::Remove))
        .filter_map(|(key, _)| {
            let original = record.carried.get(key)?.original.as_ref()?;
            Some(
                ctx.record
                    .original(&original.sha256)
                    .map(|bytes| (key.clone(), (bytes, original.mode))),
            )
        })
        .collect::<anyhow::Result<_>>()?;
    let expected: BTreeMap<String, Option<String>> =
        local.iter().map(|(key, local)| (key.clone(), Some(local.item.sha256.clone()))).collect();

    let applied = ctx.as_agent(|home, race| {
        let mut applied: Vec<(String, &'static str, Option<String>)> = Vec::new();
        for (key, step) in &steps {
            if matches!(step, Step::Keep) {
                continue;
            }
            race(key);
            // The file must still be what the plan read; one an agent changed
            // meanwhile is left for the next sync.
            let now = home.read(key)?.map(|local| local.item.sha256);
            if now != expected.get(key).cloned().flatten() {
                applied.push((key.clone(), "skipped", None));
                continue;
            }
            match step {
                Step::Write { bytes, mode } => {
                    home.write(key, bytes, *mode)?;
                    applied.push((key.clone(), "written", Some(sha256_hex(bytes))));
                }
                Step::Remove => match restore.get(key) {
                    Some((bytes, mode)) => {
                        home.write(key, bytes, *mode)?;
                        applied.push((key.clone(), "restored", None));
                    }
                    None => {
                        home.remove(key)?;
                        applied.push((key.clone(), "deleted", None));
                    }
                },
                Step::Conflict { bytes } => {
                    let side = merge::write_conflict(&home.root, key, bytes)?;
                    applied.push((side, "conflict", None));
                }
                Step::Keep => {}
            }
        }
        Ok(applied)
    })?;

    for (key, what, sha256) in applied {
        match what {
            "written" => {
                let original = record
                    .carried
                    .get(&key)
                    .and_then(|carried| carried.original.clone())
                    .or_else(|| originals.get(&key).cloned());
                record
                    .carried
                    .insert(key.clone(), Carried { sha256: sha256.unwrap_or_default(), original });
                out.written.push(key);
            }
            "restored" | "deleted" => {
                if let Some(original) =
                    record.carried.remove(&key).and_then(|carried| carried.original)
                {
                    ctx.record.drop_original(&original.sha256);
                }
                if what == "restored" { out.restored.push(key) } else { out.deleted.push(key) }
            }
            "conflict" => out.conflicts.push(key),
            _ => out.kept_local.push(key),
        }
    }
    // An original kept for a write that did not happen is not needed.
    for (key, original) in &originals {
        if record.carried.get(key).and_then(|carried| carried.original.as_ref()) != Some(original) {
            ctx.record.drop_original(&original.sha256);
        }
    }
    record.revision = head.revision;
    record.base = head.manifest;
    out.revision = Some(record.revision);
    ctx.record.save(&record)?;
    Ok(out)
}

fn fetch(ctx: &Ctx<'_>, generation: u64, item: &Item) -> anyhow::Result<Vec<u8>> {
    ctx.head
        .blob(generation, &item.sha256)?
        .with_context(|| format!("the head has no blob {} in generation {generation}", item.sha256))
}

/// diff3 of three texts: `Ok` merged, `Err` with conflict markers, `None`
/// when one is binary.
fn merge3(base: &[u8], ours: &[u8], theirs: &[u8]) -> Option<Result<Vec<u8>, Vec<u8>>> {
    if [base, ours, theirs].iter().any(|bytes| bytes.contains(&0)) {
        return None;
    }
    let mut options = diffy::MergeOptions::new();
    options.set_conflict_style(diffy::ConflictStyle::Diff3);
    Some(options.merge_bytes(base, ours, theirs))
}

/// `propose`: sends what changed here since the last sync.
pub(super) fn propose(ctx: &Ctx<'_>) -> anyhow::Result<Outcome> {
    let read = ctx.head.read().context("reading the head")?;
    let record = ctx.record.load()?;
    let mut out = Outcome { generation: read.generation, ..Outcome::default() };
    let Some(head) = read.head else { bail!("no head: the setting is off or was revoked") };
    if record.generation != read.generation {
        bail!("this machine carries generation {}; pull first", record.generation);
    }
    let base = record.base.clone();
    let local: BTreeMap<String, Local> = ctx.as_agent(|home, race| {
        let mut keys = home.scan()?;
        keys.extend(base.keys().cloned());
        let mut local = BTreeMap::new();
        for key in keys {
            race(&key);
            if let Some(found) = home.read(&key)? {
                local.insert(key, found);
            }
        }
        Ok(local)
    })?;
    let modes = ctx.head.keeps_modes();
    let same = |held: Option<&Item>, found: &Item| {
        held.is_some_and(|held| if modes { held == found } else { held.sha256 == found.sha256 })
    };
    let mut patch = BTreeMap::new();
    for (key, found) in &local {
        if !ctx.head.takes(key) {
            continue;
        }
        // Unchanged since the last sync, or already what the head holds.
        if !same(record.base.get(key), &found.item) && !same(head.manifest.get(key), &found.item) {
            ctx.head.put_blob(read.generation, &found.bytes)?;
            patch.insert(key.clone(), Some(found.item.clone()));
        }
    }
    for key in record.base.keys() {
        if !local.contains_key(key) && head.manifest.contains_key(key) && ctx.head.takes(key) {
            patch.insert(key.clone(), None);
        }
    }
    out.revision = Some(record.revision);
    if patch.is_empty() {
        return Ok(out);
    }
    out.proposed = patch.keys().cloned().collect();
    let base_revision = record.revision;
    out.proposal = Some(ctx.head.propose(&Proposal {
        device: ctx.device.clone(),
        generation: read.generation,
        base_revision,
        patch,
    })?);
    Ok(out)
}

/// `push`: a pull, then a propose against the head it pulled. On the
/// person's own device the head accepts that proposal at once, and a second
/// pull records the head it made.
pub(super) fn push(ctx: &Ctx<'_>) -> anyhow::Result<Outcome> {
    let pulled = pull(ctx)?;
    let mut out = propose(ctx)?;
    if let Some(id) = out.proposal.clone()
        && let Some(revision) = ctx.head.accept_own(&id, out.revision.unwrap_or_default())?
    {
        out.accepted_revision = Some(revision);
        out.revision = pull(ctx)?.revision;
    }
    out.written = pulled.written;
    out.deleted = pulled.deleted;
    out.restored = pulled.restored;
    out.merged = pulled.merged;
    out.conflicts = pulled.conflicts;
    Ok(out)
}

const USAGE: &str = "usage: cmux link memory pull|propose|push --head https://HOST|DIR [--home DIR] [--record DIR] [--user NAME|UID] [--device NAME]\n       cmux link memory plan [--home DIR] [--folder DIR]... [--ledger FILE] [--json]";

fn user_ids(name: &str) -> anyhow::Result<(u32, u32, PathBuf)> {
    let c = std::ffi::CString::new(name)?;
    // SAFETY: getpwnam/getpwuid answer a static record or null; read at once.
    let entry = unsafe {
        match name.parse::<u32>() {
            Ok(uid) => libc::getpwuid(uid),
            Err(_) => libc::getpwnam(c.as_ptr()),
        }
    };
    if entry.is_null() {
        bail!("no user {name}");
    }
    // SAFETY: a non-null passwd record from libc.
    let entry = unsafe { &*entry };
    // SAFETY: pw_dir is a C string in that record.
    let home = unsafe { std::ffi::CStr::from_ptr(entry.pw_dir) };
    Ok((entry.pw_uid, entry.pw_gid, PathBuf::from(home.to_string_lossy().into_owned())))
}

fn hostname() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: a buffer of its length.
    if unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } != 0 {
        return "unknown".to_string();
    }
    let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    String::from_utf8_lossy(buffer.get(..end).unwrap_or_default()).into_owned()
}

/// `cmux link memory ...`: one JSON line on stdout; exit 2 on a usage error,
/// 1 on a refusal or failure (a machine's start then starts no session).
pub(crate) fn run(args: &[String]) -> i32 {
    if matches!(args.first().map(String::as_str), None | Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return i32::from(args.is_empty()) * 2;
    }
    match run_inner(args) {
        Ok(value) => {
            println!("{value}");
            0
        }
        Err(error) if error.to_string().starts_with("usage") => {
            eprintln!("{error}");
            2
        }
        Err(error) => {
            println!("{}", json!({"ok": false, "error": format!("{error:#}")}));
            1
        }
    }
}

fn run_inner(args: &[String]) -> anyhow::Result<serde_json::Value> {
    let verb = args.first().map(String::as_str).unwrap_or_default();
    if verb == "plan" {
        return plan::run(args.get(1..).unwrap_or_default());
    }
    if !matches!(verb, "pull" | "propose" | "push") {
        bail!("{USAGE}");
    }
    let mut flags: BTreeMap<&str, &str> = BTreeMap::new();
    let mut rest = args.iter().skip(1);
    while let Some(flag) = rest.next() {
        let name = flag.as_str();
        if !matches!(name, "--head" | "--home" | "--record" | "--user" | "--device") {
            bail!("{USAGE}");
        }
        let value = rest.next().with_context(|| format!("usage: {name} needs a value"))?;
        flags.insert(name, value);
    }
    let head_arg = flags
        .get("--head")
        .map(|head| (*head).to_string())
        .or_else(|| std::env::var("CMUX_AGENT_HOME_HEAD").ok().filter(|head| !head.is_empty()))
        .context("no head: pass --head https://HOST (the AgentHome service) or --head DIR, or set CMUX_AGENT_HOME_HEAD")?;
    let (user, user_home) = match flags.get("--user") {
        Some(name) => {
            let (uid, gid, home) = user_ids(name)?;
            (Some((uid, gid)), Some(home))
        }
        None => (None, None),
    };
    let home = flags
        .get("--home")
        .map(PathBuf::from)
        .or(user_home)
        .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
        .context("no home folder")?;
    // SAFETY: geteuid has no preconditions.
    let root = unsafe { libc::geteuid() } == 0;
    let record = match flags.get("--record") {
        Some(record) => PathBuf::from(record),
        None if root => PathBuf::from(ROOT_RECORD),
        None => cmux_tui_core::platform::workspace_state_dir()
            .context("no state folder; pass --record DIR")?
            .join("agent-home"),
    };
    if root && user.is_none() && !flags.contains_key("--user") && record == Path::new(ROOT_RECORD) {
        bail!("usage: as root, name the agent user with --user");
    }
    let dir_head;
    let http_head;
    let head: &dyn Head = if http::is_url(&head_arg) {
        let origin = http::origin_of(&head_arg)?;
        // The person named this host (`--head` or the environment).
        cmux_egress::allow_named(&origin);
        let capability =
            std::env::var("CMUX_AGENT_HOME_CAPABILITY").ok().filter(|value| !value.is_empty());
        http_head = http::HttpHead::new(&origin, &agent_home_token()?, capability.as_deref())?;
        &http_head
    } else {
        dir_head = DirHead { root: PathBuf::from(&head_arg) };
        &dir_head
    };
    let ctx = Ctx {
        home,
        user,
        record: RecordStore { root: record },
        head,
        device: flags.get("--device").map(|device| (*device).to_string()).unwrap_or_else(hostname),
        machine: root,
        #[cfg(test)]
        race: None,
    };
    let outcome = match verb {
        "pull" => pull(&ctx)?,
        "propose" => propose(&ctx)?,
        _ => push(&ctx)?,
    };
    let mut value = serde_json::to_value(outcome)?;
    if let Some(object) = value.as_object_mut() {
        object.insert("ok".into(), json!(true));
        object.insert("verb".into(), json!(verb));
    }
    Ok(value)
}

/// The bearer token for the `AgentHome` service: `CMUX_AGENT_HOME_TOKEN`,
/// else `CMUX_CLOUD_ACCESS_TOKEN`, else the signed-in cmux login's.
fn agent_home_token() -> anyhow::Result<String> {
    for name in ["CMUX_AGENT_HOME_TOKEN", "CMUX_CLOUD_ACCESS_TOKEN"] {
        if let Ok(token) = std::env::var(name)
            && !token.trim().is_empty()
        {
            return Ok(token.trim().to_string());
        }
    }
    crate::cli::app_access_token().map_err(|error| {
        anyhow::anyhow!(
            "no AgentHome token: set CMUX_AGENT_HOME_TOKEN or sign in to cmux ({error})"
        )
    })
}

#[path = "memory_plan.rs"]
mod plan;

#[path = "memory_http.rs"]
pub(crate) mod http;

#[cfg(test)]
#[path = "memory_tests.rs"]
mod tests;
