//! The per-workspace remote of a folder with no remote (RFD 0066, "What to build next" 7):
//! the way back for a project that has nowhere to push. RFD 0063 has every agent VM push its
//! work in progress to a ref outside `refs/heads`; a folder that reached the VM as a copy (not
//! git, only inside a working copy, no commit, no remote) has no remote to hold that ref, so
//! the VM pushes to a place of ours instead, one per workspace, and the laptop's Bring Back
//! reads from there, so it works with the VM paused, deleted or lost.
//!
//! - **Name.** A workspace's remote is the store prefix `workspaces/<workspace>/git/`
//!   ([`Name`]). It holds one bundle per pushed turn (`bundles/<seq>-<tip>.bundle`, each thin
//!   against the one before it, the first against the base) and `tip.json` ([`Tip`]), the list
//!   of them, written last, so a reader never sees a bundle that is not whole.
//! - **Record.** This Mac keeps, per folder, the workspace, its base (the snapshot commit the
//!   VM started from: [`super::snapshot`] once it lands) and the last tip it fetched:
//!   `<state>/link-workspace-remote/<sha256 of folder>.json` ([`Record`]).
//! - **Turn-end push** ([`turn_end`]). At the end of each agent turn (and before it pauses)
//!   the VM commits its working tree with a scratch index (its own index, HEAD and refs are
//!   untouched; ignored files, untracked secrets and nested repositories are left out, as the
//!   seed export leaves them), on top of the store's tip (else the base), bundles only what is
//!   new and puts the bundle, then the tip. `refs/cmux-wip/work` ([`WIP_REF`]) keeps the
//!   commit out of gc; it moves only once the store has the bundle, so a failed upload is sent
//!   again by the next turn.
//! - **Fetch** ([`fetch`]). The laptop reads `tip.json`, fetches each bundle past its record's
//!   tip into its own repository (the person's object store or our scratch one), checking every
//!   object, and lands the work on `refs/cmux-wip/back` ([`BACK_REF`]) as a fast-forward, never
//!   on the person's branches. Applying it file by file is piece 8.
//!
//! Off by default: [`ENV`] (`CMUX_LINK_WORKSPACE_REMOTE=1`) turns the turn-end push on. The
//! store it writes to needs infrastructure that is not built ([`Unwired`]): a cmux-platform
//! endpoint for per-workspace objects under the person's R2 prefix and a store credential the
//! VM can hold (RFD 0066 gaps: "upload from a VM to the store was not measured by anyone yet",
//! RFD 0067's lane). Until then [`DirStore`] (a folder; `--store-dir`) stands in for tests and
//! drills.
//!
//! `cmux link seed workspace-remote record|push|fetch` ([`run`]) prints one JSON line.

use std::io::Write as _;
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use anyhow::{Context as _, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest as _, Sha256};

use super::git;
use super::plan::FallbackCode;
use super::secrets;

/// The switch for the turn-end push (off by default).
pub(crate) const ENV: &str = "CMUX_LINK_WORKSPACE_REMOTE";

/// Whether the VM pushes at turn end ([`ENV`] is `1` or `true`).
pub(crate) fn enabled() -> bool {
    matches!(std::env::var(ENV).ok().as_deref(), Some("1" | "true"))
}

/// The VM's ref of its newest pushed work-in-progress commit (outside `refs/heads`).
pub(crate) const WIP_REF: &str = "refs/cmux-wip/work";
/// The laptop's ref the fetched work lands on.
pub(crate) const BACK_REF: &str = "refs/cmux-wip/back";

/// Why the store is not reachable yet: what has to be built first.
pub(crate) const NOT_WIRED: &str = "the per-workspace store is not built yet: it needs a \
     cmux-platform endpoint for workspace objects under the person's R2 prefix and a store \
     credential the VM can hold (RFD 0066 piece 7; pass --store-dir to use a folder)";

/// The fixed identity of a turn commit.
const NAME: &str = "cmux turn";
const EMAIL: &str = "turn@cmux.invalid";

/// Whether a folder whose seed plan fell back with `code` reaches the VM with no remote it can
/// push to, so its work comes back through the per-workspace remote. A folder with a remote
/// (GitHub or not) keeps RFD 0063's ref on that remote.
pub(crate) fn needs_workspace_remote(code: FallbackCode) -> bool {
    matches!(
        code,
        FallbackCode::NotGit
            | FallbackCode::NotTop
            | FallbackCode::NoCommit
            | FallbackCode::NoRemote
    )
}

/// A workspace's remote: its place in the store.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Name {
    workspace: String,
}

impl Name {
    /// The remote of `workspace` (letters, digits, `.`, `_`, `-`; 1 to 128; not starting with
    /// `.`), so the prefix never climbs out of `workspaces/`.
    pub(crate) fn new(workspace: &str) -> anyhow::Result<Self> {
        let fits = (1..=128).contains(&workspace.len())
            && !workspace.starts_with('.')
            && workspace.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte));
        if !fits {
            bail!("{workspace:?} is not a workspace id");
        }
        Ok(Self { workspace: workspace.to_string() })
    }

    pub(crate) fn workspace(&self) -> &str {
        &self.workspace
    }

    /// `workspaces/<workspace>/git/`.
    pub(crate) fn prefix(&self) -> String {
        format!("workspaces/{}/git/", self.workspace)
    }

    /// The store key of `tip.json`.
    pub(crate) fn tip_key(&self) -> String {
        format!("{}tip.json", self.prefix())
    }

    /// The store key of the `seq`th bundle, ending at commit `tip`.
    pub(crate) fn bundle_key(&self, seq: u64, tip: &str) -> String {
        format!("{}bundles/{seq:08}-{tip}.bundle", self.prefix())
    }
}

/// One pushed turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Pushed {
    pub key: String,
    /// The commit the bundle is thin against (the base for the first).
    pub since: String,
    /// The turn's commit.
    pub tip: String,
    pub bytes: u64,
}

/// `tip.json`: the workspace remote's bundles in order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Tip {
    pub base: String,
    pub bundles: Vec<Pushed>,
}

impl Tip {
    /// The newest pushed commit, else the base.
    pub(crate) fn head(&self) -> &str {
        self.bundles.last().map_or(&self.base, |pushed| &pushed.tip)
    }
}

/// The per-workspace store: whole objects by key.
pub(crate) trait Store {
    /// Copies the object at `key` to `dest`; false when there is none.
    fn get(&self, key: &str, dest: &Path) -> anyhow::Result<bool>;
    /// Puts the file at `from` at `key`, replacing any object there.
    fn put(&self, key: &str, from: &Path) -> anyhow::Result<()>;
}

/// The store as a folder: tests, drills and a local stand-in until [`Unwired`] is built.
pub(crate) struct DirStore(pub PathBuf);

impl Store for DirStore {
    fn get(&self, key: &str, dest: &Path) -> anyhow::Result<bool> {
        match std::fs::copy(self.0.join(key), dest) {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error).with_context(|| format!("cannot read {key}")),
        }
    }

    fn put(&self, key: &str, from: &Path) -> anyhow::Result<()> {
        let path = self.0.join(key);
        let dir = path.parent().context("no store folder")?;
        std::fs::create_dir_all(dir).with_context(|| format!("cannot make {}", dir.display()))?;
        let part = path.with_extension(format!("{}.part", std::process::id()));
        std::fs::copy(from, &part).with_context(|| format!("cannot write {key}"))?;
        std::fs::rename(&part, &path).with_context(|| format!("cannot write {key}"))
    }
}

/// The real store, not built yet ([`NOT_WIRED`]).
pub(crate) struct Unwired;

impl Store for Unwired {
    fn get(&self, _key: &str, _dest: &Path) -> anyhow::Result<bool> {
        Err(anyhow!(NOT_WIRED))
    }

    fn put(&self, _key: &str, _from: &Path) -> anyhow::Result<()> {
        Err(anyhow!(NOT_WIRED))
    }
}

/// The store's `tip.json` of `name`; None before the first push.
pub(crate) fn read_tip(store: &dyn Store, name: &Name) -> anyhow::Result<Option<Tip>> {
    let scratch = tempfile::tempdir().context("cannot make a scratch folder")?;
    let path = scratch.path().join("tip.json");
    if !store.get(&name.tip_key(), &path)? {
        return Ok(None);
    }
    let bytes = std::fs::read(&path)?;
    let tip: Tip = serde_json::from_slice(&bytes)
        .with_context(|| format!("{} is not a workspace remote's tip", name.tip_key()))?;
    Ok(Some(tip))
}

/// What a turn-end push did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "pushed", rename_all = "snake_case")]
pub(crate) enum TurnEnd {
    /// [`ENV`] is off.
    Off,
    /// The working tree is as the store's tip has it.
    Unchanged { tip: String },
    /// One bundle went up.
    Sent { seq: u64, tip: String, since: String, bytes: u64, left_out: Vec<String> },
}

/// The turn-end push of the VM's `folder` (a git working copy, as every VM folder is) to the
/// remote `name`, whose first push builds on `base`. `on` is [`enabled`] outside tests.
pub(crate) fn turn_end(
    folder: &Path,
    name: &Name,
    base: &str,
    store: &dyn Store,
    on: bool,
) -> anyhow::Result<TurnEnd> {
    if !on {
        return Ok(TurnEnd::Off);
    }
    let tip = read_tip(store, name)?;
    if let Some(tip) = &tip
        && tip.base != base
    {
        bail!("the workspace remote builds on {}, not {base}", tip.base);
    }
    let since = tip.as_ref().map_or(base, Tip::head).to_string();
    let since_commit = git::text(git::at(folder).args([
        "rev-parse",
        "-q",
        "--verify",
        &format!("{since}^{{commit}}"),
    ]))
    .map_err(|why| anyhow!("{since} is not in {}: {why}", folder.display()))?;

    let scratch = tempfile::tempdir().context("cannot make a scratch folder")?;
    let (tree, left_out) = work_tree(folder, scratch.path())?;
    let since_tree =
        git::text(git::at(folder).args(["rev-parse", &format!("{since_commit}^{{tree}}")]))
            .map_err(|why| anyhow!(why))?;
    if tree == since_tree {
        return Ok(TurnEnd::Unchanged { tip: since_commit });
    }
    let seq = tip.as_ref().map_or(0, |tip| tip.bundles.len() as u64) + 1;
    let commit = git::text(
        git::at(folder)
            .env("GIT_AUTHOR_NAME", NAME)
            .env("GIT_AUTHOR_EMAIL", EMAIL)
            .env("GIT_COMMITTER_NAME", NAME)
            .env("GIT_COMMITTER_EMAIL", EMAIL)
            .args(["commit-tree", &tree, "-p", &since_commit, "-m", &format!("cmux turn {seq}")]),
    )
    .map_err(|why| anyhow!("cannot commit the turn: {why}"))?;

    // The bundle needs a ref; a scratch one, so WIP_REF moves only once the store has it.
    let pending = "refs/cmux-wip/pending";
    git::text(git::at(folder).args(["update-ref", pending, &commit]))
        .map_err(|why| anyhow!("cannot record the turn: {why}"))?;
    let bundle = scratch.path().join("turn.bundle");
    let bundled = git::text(
        git::at(folder)
            .args(["bundle", "create", "-q"])
            .arg(&bundle)
            .args([pending, &format!("^{since_commit}")]),
    );
    if let Err(why) = bundled {
        let _ = git::text(git::at(folder).args(["update-ref", "-d", pending]));
        bail!("cannot bundle the turn: {why}");
    }
    let bytes = std::fs::metadata(&bundle)?.len();
    let key = name.bundle_key(seq, &commit);
    let mut next = tip.unwrap_or_else(|| Tip { base: base.to_string(), bundles: Vec::new() });
    next.bundles.push(Pushed {
        key: key.clone(),
        since: since_commit.clone(),
        tip: commit.clone(),
        bytes,
    });
    let tip_file = scratch.path().join("tip.json");
    std::fs::write(&tip_file, serde_json::to_vec(&next)?)?;
    let sent = store.put(&key, &bundle).and_then(|()| store.put(&name.tip_key(), &tip_file));
    let _ = git::text(git::at(folder).args(["update-ref", "-d", pending]));
    sent?;
    git::text(git::at(folder).args(["update-ref", WIP_REF, &commit]))
        .map_err(|why| anyhow!("cannot keep the turn's commit: {why}"))?;
    Ok(TurnEnd::Sent { seq, tip: commit, since: since_commit, bytes, left_out })
}

/// The tree of `folder`'s working copy as `git add -A` sees it, made in a scratch index in
/// `scratch` (the folder's own index untouched), without untracked secrets and nested
/// repositories; and the paths left out.
fn work_tree(folder: &Path, scratch: &Path) -> anyhow::Result<(String, Vec<String>)> {
    let index = scratch.join("index");
    let own = git::text(git::at(folder).args([
        "rev-parse",
        "--path-format=absolute",
        "--git-path",
        "index",
    ]))
    .map_err(|why| anyhow!("{} is not a git working copy: {why}", folder.display()))?;
    match std::fs::copy(&own, &index) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).with_context(|| format!("cannot read {own}")),
    }
    let untracked =
        git::output(git::at(folder).args(["ls-files", "-z", "--others", "--exclude-standard"]))
            .map_err(|why| anyhow!(why))?;
    let mut left_out = Vec::new();
    for raw in untracked.split(|byte| *byte == 0).filter(|raw| !raw.is_empty()) {
        // git names a nested repository whole (`dir/`) and never descends into it.
        let nested = raw.ends_with(b"/");
        if nested || secrets::reason(folder, raw).is_some() {
            left_out.push(String::from_utf8_lossy(raw).trim_end_matches('/').to_string());
        }
    }
    // Left out by pathspec, so `add` never opens a nested repository (one with no commit is an
    // error to it) or reads a secret.
    let mut add = git::at(folder);
    add.env("GIT_INDEX_FILE", &index)
        .args(["add", "-A", "--", "."])
        .args(left_out.iter().map(|path| format!(":(exclude,literal){path}")));
    git::text(&mut add).map_err(|why| anyhow!("cannot read the working tree: {why}"))?;
    let tree = git::text(git::at(folder).env("GIT_INDEX_FILE", &index).arg("write-tree"))
        .map_err(|why| anyhow!("cannot write the turn's tree: {why}"))?;
    Ok((tree, left_out))
}

/// What a fetch did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Fetched {
    /// The newest commit now on [`BACK_REF`]; None when nothing was ever pushed.
    pub tip: Option<String>,
    /// Bundles fetched this time.
    pub fetched: usize,
}

/// Fetches the remote `name`'s bundles past `after` (the last tip this Mac fetched; None for
/// all) into the repository at `repo` (a working copy or a bare one, holding the base) and
/// lands the newest on [`BACK_REF`] as a fast-forward.
pub(crate) fn fetch(
    repo: &Path,
    name: &Name,
    after: Option<&str>,
    store: &dyn Store,
) -> anyhow::Result<Fetched> {
    let Some(tip) = read_tip(store, name)? else {
        return Ok(Fetched { tip: None, fetched: 0 });
    };
    let start = match after {
        None => 0,
        Some(after) if after == tip.base => 0,
        Some(after) => match tip.bundles.iter().position(|pushed| pushed.tip == after) {
            Some(index) => index + 1,
            None => bail!("{after} is not on the workspace remote"),
        },
    };
    let scratch = tempfile::tempdir().context("cannot make a scratch folder")?;
    let mut fetched = 0;
    for pushed in tip.bundles.iter().skip(start) {
        let path = scratch.path().join("turn.bundle");
        if !store.get(&pushed.key, &path)? {
            bail!("{} is missing from the workspace remote", pushed.key);
        }
        let spec = format!("refs/cmux-wip/pending:{BACK_REF}");
        git::text(
            git::at(repo)
                .args(["-c", "transfer.fsckObjects=true", "-c", "fetch.fsckObjects=true"])
                .args(["fetch", "-q", "--no-tags", "--no-write-fetch-head"])
                .arg(&path)
                .arg(&spec),
        )
        .map_err(|why| anyhow!("cannot fetch {}: {why}", pushed.key))?;
        let landed =
            git::text(git::at(repo).args(["rev-parse", BACK_REF])).map_err(|why| anyhow!(why))?;
        if landed != pushed.tip {
            bail!("{} landed {landed}, not {}", pushed.key, pushed.tip);
        }
        fetched += 1;
    }
    Ok(Fetched { tip: tip.bundles.last().map(|pushed| pushed.tip.clone()), fetched })
}

/// This Mac's record of a folder's workspace remote.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Record {
    pub workspace: String,
    /// The commit the VM started from.
    pub base: String,
    /// The last tip fetched from the remote.
    #[serde(default)]
    pub fetched: Option<String>,
}

fn record_path(state: &Path, local: &Path) -> PathBuf {
    let name: String = Sha256::digest(local.as_os_str().as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    state.join("link-workspace-remote").join(format!("{name}.json"))
}

/// The record of `local` under the state folder `state`; None when there is none.
pub(crate) fn load(state: &Path, local: &Path) -> anyhow::Result<Option<Record>> {
    let path = record_path(state, local);
    match std::fs::read(&path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .with_context(|| format!("{} is not a workspace remote record", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("cannot read {}", path.display())),
    }
}

/// Keeps `record` for `local` under `state` (0600, its folder 0700, written whole).
pub(crate) fn save(state: &Path, local: &Path, record: &Record) -> anyhow::Result<()> {
    let path = record_path(state, local);
    let dir = path.parent().context("no state folder")?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .with_context(|| format!("cannot make {}", dir.display()))?;
    let part = path.with_extension(format!("{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)
        .with_context(|| format!("cannot write {}", part.display()))?;
    file.write_all(&serde_json::to_vec(record)?)?;
    file.sync_all()?;
    std::fs::rename(&part, &path).with_context(|| format!("cannot write {}", path.display()))
}

const USAGE: &str = "usage: cmux link seed workspace-remote record --local FOLDER --workspace ID --base SHA\n       \
     cmux link seed workspace-remote push --folder FOLDER --workspace ID --base SHA [--store-dir DIR]\n       \
     cmux link seed workspace-remote fetch --local FOLDER --repo REPO [--store-dir DIR]";

/// `cmux link seed workspace-remote ...`: one JSON line on stdout; 0, 1 on failure, 64 on bad
/// usage. `push` is the VM's turn-end hook: with [`ENV`] off it answers `"pushed":"off"`, 0.
pub(crate) fn run(args: &[String]) -> i32 {
    let Some((action, flags)) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let flag =
        |name: &str| flags.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str());
    let store: Box<dyn Store> = match flag("--store-dir") {
        Some(dir) => Box::new(DirStore(PathBuf::from(dir))),
        None => Box::new(Unwired),
    };
    let answer = match (action.as_str(), flag("--workspace"), flag("--base")) {
        ("record", Some(workspace), Some(base)) => {
            flag("--local").map(|local| record(local, workspace, base))
        }
        ("push", Some(workspace), Some(base)) => flag("--folder").map(|folder| {
            Name::new(workspace).and_then(|name| {
                turn_end(Path::new(folder), &name, base, store.as_ref(), enabled())
                    .map(|done| serde_json::to_value(done).unwrap_or_default())
            })
        }),
        ("fetch", None, None) => match (flag("--local"), flag("--repo")) {
            (Some(local), Some(repo)) => Some(fetch_recorded(local, repo, store.as_ref())),
            _ => None,
        },
        _ => None,
    };
    let Some(answer) = answer else {
        eprintln!("{USAGE}");
        return 64;
    };
    match answer {
        Ok(mut line) => {
            if let Some(object) = line.as_object_mut() {
                object.insert("ok".into(), json!(true));
            }
            println!("{line}");
            0
        }
        Err(error) => {
            let code = if error.to_string() == NOT_WIRED { "store_not_wired" } else { "failed" };
            println!("{}", json!({"ok": false, "code": code, "why": format!("{error:#}")}));
            1
        }
    }
}

fn state_dir() -> anyhow::Result<PathBuf> {
    cmux_tui_core::platform::workspace_state_dir()
        .context("this Mac has no state folder to keep the workspace remote record in")
}

fn record(local: &str, workspace: &str, base: &str) -> anyhow::Result<serde_json::Value> {
    let name = Name::new(workspace)?;
    let local = std::path::absolute(local)?;
    save(
        &state_dir()?,
        &local,
        &Record { workspace: workspace.into(), base: base.into(), fetched: None },
    )?;
    Ok(json!({"workspace": workspace, "prefix": name.prefix()}))
}

fn fetch_recorded(local: &str, repo: &str, store: &dyn Store) -> anyhow::Result<serde_json::Value> {
    let state = state_dir()?;
    let local = std::path::absolute(local)?;
    let Some(mut kept) = load(&state, &local)? else {
        bail!("{} has no workspace remote record", local.display());
    };
    let name = Name::new(&kept.workspace)?;
    let fetched = fetch(Path::new(repo), &name, kept.fetched.as_deref(), store)?;
    if fetched.fetched > 0 {
        kept.fetched = fetched.tip.clone();
        save(&state, &local, &kept)?;
    }
    Ok(serde_json::to_value(fetched)?)
}

fn parse(args: &[String]) -> Option<(String, Vec<(String, String)>)> {
    let (action, rest) = args.split_first()?;
    if rest.len() % 2 != 0 {
        return None;
    }
    let known = ["--local", "--folder", "--workspace", "--base", "--store-dir", "--repo"];
    let flags = rest
        .chunks(2)
        .map(|pair| match pair {
            [flag, value] => known.contains(&flag.as_str()).then(|| (flag.clone(), value.clone())),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()?;
    Some((action.clone(), flags))
}

#[cfg(test)]
#[path = "workspace_remote_tests.rs"]
mod tests;
