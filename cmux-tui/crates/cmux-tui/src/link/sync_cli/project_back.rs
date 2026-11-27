//! Bring Back over a projected folder (RFD 0007; Leo: "each chat gets its own copy-on-write layer
//! over the projection so nothing touches the person's files until it comes back"). What the
//! agent wrote sits in the projection's upper layer on the machine; this brings it here in
//! O(edits):
//!
//! 1. the machine's listing of the upper layer and whiteouts (`projection.layer`, no bytes),
//!    with the dependency, cache and build folders the agent made (`node_modules`, a Cargo
//!    `target`) counted, not listed: they stay on the machine (`kept_on_machine` in the summary);
//! 2. this Mac's stat of each path they touch, against the manifest the session started from
//!    (kept here by `serve`, [`record`]), planned by [`cmux_projection::way_back::plan`]: writes,
//!    deletes, mode changes and named conflicts. New paths this Mac's git ignores stay there;
//! 3. only the files the plan writes or names come over (`projection.files`, in batches of
//!    bounded paths and bytes), and the upper's
//!    `.git` files of each repository go through the HEAD and index three-way
//!    ([`super::git_back::plan_from_layer`]), never copied as files;
//! 4. one transaction here ([`super::place`]): every file replaced or deleted is checked to be
//!    still the one planned (its SHA-256 taken at plan time), and any failure puts back what
//!    changed. A conflict's machine version is written beside this Mac's file
//!    (`NAME.cmux-sync-conflict`, [`super::merge::write_conflict`]); this Mac's is never replaced.
//!    A git conflict stops everything before a file changes.
//! 5. Only once all of that applied does the machine free the projection: brought back at the
//!    mark it read (`projection.brought_back`; `projection.drop` on a machine whose listing has no
//!    mark): unmount, delete the upper layer and cache. This Mac then stops the folder's server.
//!    An upper layer the agent wrote to since it was read stays on the machine, mounted again on
//!    the next dial (`edited_since` in the summary), and so does this Mac's record of it.
//!
//! ```text
//! cmux link project back --socket S --at REMOTE FOLDER [--keep]
//! cmux link project release --socket S --at REMOTE FOLDER [--why archived|deleted]
//! ```

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead as _, BufReader, Read as _, Seek as _, Write as _};
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context as _, bail};
use cmux_projection::layer::{self, Layer};
use cmux_projection::manifest::{Kind, Manifest};
use cmux_projection::way_back::{self, MacStat, Plan};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::local::{self, GitDirs};
use super::place::{self, Dir, Expected, Transaction};
use super::pull::Staging;
use super::{Back, git_back, merge, names};

/// How long a Bring Back dial waits for the machine's answer line.
const ANSWER_WAIT: Duration = Duration::from_secs(120);
/// The name a folder is asked about by in `git check-ignore` (never made).
const PROBE: &str = ".cmux-ignore-probe";
/// The largest single file Bring Back takes.
const MAX_FILE: u64 = 64 * 1024 * 1024 * 1024;

/// What `serve` keeps for Bring Back: which folder a projection is, and its manifest beside it
/// (`<name>.manifest`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Recorded {
    pub name: String,
    pub remote: String,
    pub local: PathBuf,
}

fn records_dir() -> anyhow::Result<PathBuf> {
    cmux_tui_core::platform::workspace_state_dir()
        .map(|dir| dir.join("link-sync").join("projections"))
        .context("this Mac has no state folder")
}

/// Keeps projection `name`'s manifest (`encoded`) and folders for Bring Back.
pub(crate) fn record(name: &str, remote: &str, local: &Path, encoded: &[u8]) -> anyhow::Result<()> {
    let dir = records_dir()?;
    std::fs::create_dir_all(&dir)?;
    let manifest = dir.join(format!("{name}.manifest"));
    let temp = dir.join(format!(".{name}.manifest.{}", std::process::id()));
    std::fs::write(&temp, encoded)?;
    std::fs::rename(&temp, &manifest)?;
    let recorded =
        Recorded { name: name.to_owned(), remote: remote.to_owned(), local: local.to_path_buf() };
    std::fs::write(dir.join(format!("{name}.json")), serde_json::to_vec(&recorded)?)?;
    Ok(())
}

/// The projection recorded for `local` at `remote`, when that folder is projected.
pub(crate) fn recorded(local: &Path, remote: &str) -> Option<Recorded> {
    records_at(local, remote).ok()?.next()
}

fn records_at(local: &Path, remote: &str) -> anyhow::Result<impl Iterator<Item = Recorded>> {
    let local = std::fs::canonicalize(local)?;
    let remote = remote.trim_end_matches('/').to_owned();
    let entries = std::fs::read_dir(records_dir()?)?;
    Ok(entries.filter_map(move |entry| {
        let path = entry.ok()?.path();
        if path.extension()? != "json" {
            return None;
        }
        let found: Recorded = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
        (found.remote.trim_end_matches('/') == remote && found.local == local).then_some(found)
    }))
}

/// A notification recipient is a session ID. A projection is named by its start key or by
/// the caller of `serve --name`. Only an explicit projection name can disambiguate shared paths.
fn detach_record(
    records: impl Iterator<Item = Recorded>,
    name: Option<&str>,
) -> anyhow::Result<Recorded> {
    let mut matches = records.filter(|record| name.is_none_or(|name| name == record.name));
    let record = matches.next().context("no matching projection record")?;
    anyhow::ensure!(
        matches.next().is_none(),
        "several projections use this folder; pass --name with the projection to detach"
    );
    Ok(record)
}

fn forget(name: &str) {
    if let Ok(dir) = records_dir() {
        let _ = std::fs::remove_file(dir.join(format!("{name}.manifest")));
        let _ = std::fs::remove_file(dir.join(format!("{name}.json")));
    }
}

/// `back --socket S --at REMOTE FOLDER [--keep]`: Bring Back of a projected folder; `--keep`
/// leaves the projection on the machine (the bench runs it twice).
pub(crate) fn back_command(args: &[String]) -> anyhow::Result<Value> {
    let (mut socket, mut at, mut folder, mut keep) = (None, None, None, false);
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--socket" => socket = words.next().map(PathBuf::from),
            "--at" => at = words.next().cloned(),
            "--keep" => keep = true,
            other if other.starts_with("--") => bail!("unknown flag {other}"),
            other => folder = Some(PathBuf::from(other)),
        }
    }
    let socket = socket.context("--socket is required")?;
    let at = at.context("--at is required")?;
    let folder = folder.context("the folder is required")?;
    let found = recorded(&folder, &at)
        .with_context(|| format!("{} is not a projected folder at {at}", folder.display()))?;
    match bring_back(&socket, &found, keep) {
        Back::Done(summary) => Ok(summary),
        Back::Conflict(conflicts, reasons) => Ok(json!({
            "ok": false,
            "error": format!("{}: nothing was brought back ({})", conflicts.join(", "),
                             reasons.join("; ")),
            "error_code": "sync_conflict",
            "conflicts": conflicts,
        })),
        Back::Failed { code, error } => {
            Ok(json!({"ok": false, "error": error, "error_code": code}))
        }
    }
}

/// `release --socket S --at REMOTE FOLDER [--why archived|deleted]`: the chat is archived or
/// deleted, so nothing will bring its edits back: the machine ends the projection and frees its
/// state (`projection.release`), and this Mac stops the folder's server and forgets it.
pub(crate) fn release_command(args: &[String]) -> anyhow::Result<Value> {
    let (mut socket, mut at, mut folder, mut why) = (None, None, None, "archived".to_owned());
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--socket" => socket = words.next().map(PathBuf::from),
            "--at" => at = words.next().cloned(),
            "--why" => why = words.next().cloned().context("--why needs archived or deleted")?,
            other if other.starts_with("--") => bail!("unknown flag {other}"),
            other => folder = Some(PathBuf::from(other)),
        }
    }
    anyhow::ensure!(matches!(why.as_str(), "archived" | "deleted"), "--why is archived or deleted");
    let socket = socket.context("--socket is required")?;
    let at = at.context("--at is required")?;
    let folder = folder.context("the folder is required")?;
    let found = recorded(&folder, &at)
        .with_context(|| format!("{} is not a projected folder at {at}", folder.display()))?;
    let line = json!({"cmd": "projection.release", "name": found.name, "why": why});
    match dial_answer(&socket, &line)? {
        Ok(answer) => {
            let _ = super::project::stop_server(&found.remote);
            forget(&found.name);
            Ok(json!({"ok": true, "released": true,
                      "freed_bytes": field(&answer, "/data/freed_bytes")}))
        }
        Err(answer) => Ok(json!({"ok": false, "error": field(&answer, "/error"),
                                 "error_code": field(&answer, "/error_code")})),
    }
}

/// `cmux link project detach --socket S --at REMOTE [--name NAME] [--chat ID] FOLDER`: the folder was removed
/// from its chat. The machine seals and unmounts it, keeping its edits (`projection.detach`); this
/// Mac stops serving it but keeps its record, so Bring Back (`cmux link project back`) or Discard
/// still finds it.
pub(crate) fn detach_command(args: &[String]) -> anyhow::Result<Value> {
    let (mut socket, mut at, mut folder, mut chat, mut name) = (None, None, None, None, None);
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--socket" => socket = words.next().map(PathBuf::from),
            "--at" => at = words.next().cloned(),
            "--name" => {
                name = Some(words.next().cloned().context("--name needs a projection name")?)
            }
            "--chat" => chat = Some(words.next().cloned().context("--chat needs a chat id")?),
            other if other.starts_with("--") => bail!("unknown flag {other}"),
            other => folder = Some(PathBuf::from(other)),
        }
    }
    let socket = socket.context("--socket is required")?;
    let at = at.context("--at is required")?;
    let folder = folder.context("the folder is required")?;
    let found = detach_record(records_at(&folder, &at)?, name.as_deref())
        .with_context(|| format!("selecting the projection of {} at {at}", folder.display()))?;
    let mut line = json!({"cmd": "projection.detach", "name": found.name});
    if let Some(chat) = chat {
        line["chat"] = Value::String(chat);
    }
    match dial_answer(&socket, &line)? {
        Ok(answer) => {
            // The mount is gone, so nothing reads through the server; the record stays.
            let _ = super::project::stop_recorded_server(&socket, &found);
            Ok(json!({"ok": true, "detached": true, "mark": field(&answer, "/data/mark"),
                      "was_mounted": field(&answer, "/data/was_mounted")}))
        }
        Err(answer) => Ok(json!({"ok": false, "error": field(&answer, "/error"),
                                 "error_code": field(&answer, "/error_code")})),
    }
}

/// Bring Back of the projected folder `found` (module docs). `keep`: leave the projection on the
/// machine afterwards.
pub(in crate::link) fn bring_back(socket: &Path, found: &Recorded, keep: bool) -> Back {
    match run(socket, found, keep) {
        Ok(back) => back,
        Err(error) => Back::Failed { code: "sync_failed".into(), error: format!("{error:#}") },
    }
}

/// One `projection.layer` answer: the listing's size, the mark, the listing.
struct Listing {
    bytes: u64,
    /// The upper layer as the machine read it: what `projection.brought_back` frees.
    mark: Option<String>,
    layer: Layer,
}

/// The folders `prune` left on the machine, and the answer's totals of them.
#[derive(Default)]
struct KeptOnMachine {
    pruned: Vec<layer::Pruned>,
    totals: Value,
}

/// The machine's listing of `name`'s upper layer; with `prune`, its dependency and cache
/// folders as counts instead (a machine from before `prune` lists them all, and none come back
/// counted).
fn layer_of(socket: &Path, name: &str, prune: bool) -> anyhow::Result<(Listing, KeptOnMachine)> {
    let (answer, mut reader) =
        dial(socket, &json!({"cmd": "projection.layer", "name": name, "prune": prune}), &[])?;
    let bytes =
        field(&answer, "/data/bytes").as_u64().context("the machine sent no listing size")?;
    let mark = field(&answer, "/data/mark").as_str().map(str::to_owned);
    let mut raw = Vec::new();
    (&mut reader).take(bytes).read_to_end(&mut raw)?;
    anyhow::ensure!(raw.len() as u64 == bytes, "the machine's listing ended early");
    let layer = Layer::decode(&raw)?;
    let mut kept = KeptOnMachine::default();
    if let Some(more) = field(&answer, "/data/pruned_bytes").as_u64() {
        let mut raw = Vec::new();
        (&mut reader).take(more).read_to_end(&mut raw)?;
        anyhow::ensure!(raw.len() as u64 == more, "the machine's pruned list ended early");
        kept.pruned = Layer::decode_pruned(&raw)?;
        kept.totals = field(&answer, "/data/kept_on_machine").clone();
    }
    Ok((Listing { bytes, mark, layer }, kept))
}

/// The most paths one `projection.files` dial asks for.
const BATCH_PATHS: usize = 4096;
/// The most listed bytes one `projection.files` dial asks for (one larger file goes alone).
const BATCH_BYTES: u64 = 256 * 1024 * 1024;

/// `paths` in order, cut into runs of at most [`BATCH_PATHS`] paths and [`BATCH_BYTES`] bytes
/// by `size`; never an empty run.
fn batches<'a>(paths: &'a [String], size: impl Fn(&str) -> u64) -> Vec<&'a [String]> {
    let mut runs = Vec::new();
    let (mut start, mut bytes) = (0, 0u64);
    for (at, path) in paths.iter().enumerate() {
        let len = size(path);
        if at > start && (at - start == BATCH_PATHS || bytes.saturating_add(len) > BATCH_BYTES) {
            if let Some(batch) = paths.get(start..at) {
                runs.push(batch);
            }
            (start, bytes) = (at, 0);
        }
        bytes = bytes.saturating_add(len);
    }
    if start < paths.len() {
        if let Some(batch) = paths.get(start..) {
            runs.push(batch);
        }
    }
    runs
}

/// Milliseconds since `since`.
fn ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

fn run(socket: &Path, found: &Recorded, keep: bool) -> anyhow::Result<Back> {
    let started = Instant::now();
    let root = std::fs::canonicalize(&found.local)
        .with_context(|| format!("cannot open {}", found.local.display()))?;
    let encoded = std::fs::read(records_dir()?.join(format!("{}.manifest", found.name)))
        .context("this Mac kept no manifest for the projection")?;
    let manifest = Manifest::decode(&encoded)?;

    // Dependency, cache and build folders the agent made stay on the machine, counted, not
    // listed (`Layer::collect_pruned`): 100k files under `node_modules` never cross. A folder
    // this Mac had when it projected (a committed `vendor/.cache`) is asked for again whole.
    let (mut listing, mut kept_on_machine) = layer_of(socket, &found.name, true)?;
    if kept_on_machine.pruned.iter().any(|folder| manifest.resolve(&folder.path).is_some()) {
        (listing, kept_on_machine) = layer_of(socket, &found.name, false)?;
    }
    let Listing { bytes, mark, layer: mut changed } = listing;
    let listed_ms = ms(started);
    // Modes as the copy keeps them (0644, 0755, 0600, 0700), the manifest's own rule.
    for entry in &mut changed.upper {
        if entry.kind == Kind::File {
            entry.mode = local::permissions_of(entry.mode);
        }
    }

    let planned_at = Instant::now();
    let touched = way_back::touched(&manifest, &changed.upper, &changed.whiteouts);
    let mac: BTreeMap<String, MacStat> =
        touched.iter().filter_map(|path| Some((path.clone(), mac_stat(&root, path)?))).collect();
    let mut plan =
        way_back::plan(&manifest, &changed.upper, &changed.whiteouts, &mac, &names::folded_path);
    let ignored = keep_ignored_home(&root, &manifest, &mut plan)?;
    let plan_ms = ms(planned_at);

    // The bytes: what the plan writes or keeps beside, and each repository's git files.
    let mut wanted: Vec<String> = plan
        .writes
        .iter()
        .filter(|write| write.kind == Kind::File)
        .map(|write| write.path.clone())
        .collect();
    let upper_kind: BTreeMap<&str, Kind> =
        changed.upper.iter().map(|entry| (entry.path.as_str(), entry.kind)).collect();
    wanted.extend(
        plan.conflicts
            .iter()
            .filter(|c| c.beside && upper_kind.get(c.path.as_str()) == Some(&Kind::File))
            .map(|c| c.path.clone()),
    );
    for paths in plan.git.values() {
        wanted.extend(
            paths.iter().filter(|p| upper_kind.get(p.as_str()) == Some(&Kind::File)).cloned(),
        );
    }
    let git = GitDirs::of(&root).ok().flatten();
    let staging = Staging::make(git.as_ref().map_or(&root, |dirs| &dirs.own))?;
    let received = staging.0.join("upper");
    std::fs::create_dir_all(&received)?;
    let mut fetched_bytes = 0u64;
    // In batches of bounded paths and bytes, one dial each: a codemod's 100k files never make
    // one path list past the machine's limit or one answer that outlives a dial's wait.
    let size_of: BTreeMap<&str, u64> =
        changed.upper.iter().map(|entry| (entry.path.as_str(), entry.size)).collect();
    for batch in batches(&wanted, |path| size_of.get(path).copied().unwrap_or(0)) {
        let list = batch.join("\n").into_bytes();
        let line =
            json!({"cmd": "projection.files", "name": found.name, "paths_bytes": list.len()});
        let (_, mut reader) = dial(socket, &line, &list)?;
        let arrived = layer::receive_files(&mut reader, batch, &received, MAX_FILE)?;
        for (path, came) in batch.iter().zip(&arrived) {
            if !came {
                bail!("{path} went away on the machine during Bring Back; nothing changed here");
            }
            fetched_bytes += std::fs::symlink_metadata(received.join(path))?.len();
        }
    }
    let fetched_ms = ms(started);

    // The git leg, before any file here changes: a conflict stops everything.
    let mut git_plans = Vec::new();
    let mut git_left = Vec::new();
    for repo in plan.git.keys() {
        let folder = if repo.is_empty() { root.clone() } else { root.join(repo) };
        let Some(dirs) = GitDirs::of(&folder).ok().flatten() else {
            git_left.push(format!("{repo}: not a repository on this Mac"));
            continue;
        };
        let machine_git =
            received.join(if repo.is_empty() { ".git".into() } else { format!("{repo}/.git") });
        let base_known = git_base_known(&root, &manifest, repo, &dirs);
        let hooks = git_back::hooks_path(&folder)?.into_iter().collect::<Vec<_>>();
        let repo_staging = staging.0.join(format!("git-{}", git_plans.len() + git_left.len()));
        std::fs::create_dir_all(&repo_staging)?;
        let at =
            git_back::Where { folder: &folder, common_dir: &dirs.common, staging: &repo_staging };
        match git_back::plan_from_layer(&at, &machine_git, base_known, &hooks)? {
            Ok(Some(git_plan)) => git_plans.push((folder, git_plan)),
            Ok(None) => {}
            Err(conflicts) => {
                let paths = conflicts
                    .iter()
                    .map(
                        |(path, _)| {
                            if repo.is_empty() { path.clone() } else { format!("{repo}/{path}") }
                        },
                    )
                    .collect();
                let reasons =
                    conflicts.iter().map(|(path, why)| format!("{path}: {why}")).collect();
                return Ok(Back::Conflict(paths, reasons));
            }
        }
    }

    // Each repository's changes as one diff against its base commit, and the preflight `git apply
    // --3way` makes: a conflict whose file merges cleanly against the base becomes a write.
    let diffs = diff_stage(&root, &found.name, &staging, &received, &manifest, &mac, &mut plan)?;

    let applied = apply(&root, &staging, &received, &manifest, &plan)?;
    let mut moved = Vec::new();
    for (folder, git_plan) in &git_plans {
        git_plan.fetch(folder)?;
        if git_plan.commit(folder)? {
            moved.push(folder.strip_prefix(&root).unwrap_or(folder).display().to_string());
        }
    }
    let applied_ms = ms(started);

    let (mut dropped, mut edited_since, mut freed_bytes) = (false, false, None);
    if !keep {
        let line = match &mark {
            Some(mark) => {
                json!({"cmd": "projection.brought_back", "name": found.name, "mark": mark})
            }
            None => json!({"cmd": "projection.drop", "name": found.name}),
        };
        match dial_answer(socket, &line)? {
            Ok(answer) => {
                dropped = field(&answer, "/data/dropped").as_bool() == Some(true);
                freed_bytes = field(&answer, "/data/freed_bytes").as_u64();
                let _ = super::project::stop_server(&found.remote);
                forget(&found.name);
            }
            Err(answer)
                if field(&answer, "/error_code").as_str() == Some("projection.edited_since") =>
            {
                edited_since = true;
            }
            Err(answer) => {
                bail!(
                    "{}",
                    field(&answer, "/error").as_str().unwrap_or("the machine refused Bring Back")
                )
            }
        }
    }
    let conflicts: Vec<Value> = plan
        .conflicts
        .iter()
        .map(
            |c| json!({"path": c.path, "why": c.why.text(), "beside": applied.beside.get(&c.path)}),
        )
        .collect();
    let mut left_out: Vec<Value> =
        plan.left_out.iter().map(|(path, why)| json!({"path": path, "why": why})).collect();
    left_out.extend(ignored.iter().map(|path| json!({"path": path, "why": "ignored by git here"})));
    left_out.extend(git_left.iter().map(|why| json!({"path": ".git", "why": why})));
    // The report (hq#13128's three lists): what came back, what stayed on the machine, and what
    // neither side's version won.
    let mut applied_paths: Vec<&str> = plan.writes.iter().map(|w| w.path.as_str()).collect();
    applied_paths.extend(plan.deletes.iter().map(|d| d.path.as_str()));
    applied_paths.extend(plan.modes.iter().map(|m| m.path.as_str()));
    applied_paths.sort_unstable();
    applied_paths.dedup();
    let mut skipped: Vec<&str> = plan.left_out.iter().map(|(path, _)| path.as_str()).collect();
    skipped.extend(ignored.iter().map(String::as_str));
    let conflicted: Vec<&str> = plan.conflicts.iter().map(|c| c.path.as_str()).collect();
    Ok(Back::Done(json!({
        "ok": true,
        "mode": "projection",
        "report": {"applied": applied_paths, "skipped": skipped, "conflicted": conflicted},
        "diffs": diffs,
        "written": applied.written,
        "deleted": applied.deleted,
        "modes": applied.modes,
        "unchanged": plan.unchanged,
        "conflicts": conflicts,
        "left_out": left_out,
        "branch_moved": moved,
        "staged": git_plans.len(),
        "bytes": fetched_bytes,
        "listing_bytes": bytes,
        // What the agent made that stays on the machine uncounted by Bring Back's lists:
        // `{folders, files, bytes}` and each folder.
        "kept_on_machine": {
            "totals": kept_on_machine.totals,
            "folders": kept_on_machine.pruned.iter()
                .map(|f| json!({"path": f.path, "files": f.files, "bytes": f.bytes}))
                .collect::<Vec<_>>(),
        },
        "dropped": dropped,
        "edited_since": edited_since,
        "freed_bytes": freed_bytes,
        "timings": {"listed_ms": listed_ms, "plan_ms": plan_ms, "fetched_ms": fetched_ms,
                    "applied_ms": applied_ms, "total_ms": ms(started)},
    })))
}

/// One plan path of a repository's working tree: where it is inside the repository, and the
/// machine's file for it (None: the machine deleted it).
struct Change {
    path: String,
    inside: String,
    file: Option<PathBuf>,
}

/// For each repository whose HEAD and index here are still the session's (its base commit known):
/// the machine's changes to its working tree as one diff against that commit (kept beside this
/// Mac's records, so a later best-of-N can offer sibling diffs against the same base), and the
/// preflight `git apply --3way` runs. A path the Mac also changed is merged three-way against the
/// base commit's blob (`git merge-file`); a clean merge turns the conflict into a write of the
/// merged file, an overlapping one stays a conflict (the machine's version beside it). Files
/// outside git, and repositories whose base moved, keep the manifest plan alone. The diffs, as
/// `{"repo", "base", "patch", "files"}`.
fn diff_stage(
    root: &Path,
    name: &str,
    staging: &Staging,
    received: &Path,
    manifest: &Manifest,
    mac: &BTreeMap<String, MacStat>,
    plan: &mut Plan,
) -> anyhow::Result<Vec<Value>> {
    let mut by_repo: BTreeMap<String, Vec<Change>> = BTreeMap::new();
    let mut add = |path: &str, file: Option<PathBuf>| {
        let Some(repo) = repository_of(manifest, path) else { return };
        let inside = path_inside(&repo, path);
        by_repo.entry(repo).or_default().push(Change { path: path.to_owned(), inside, file });
    };
    for write in plan.writes.iter().filter(|w| w.kind == Kind::File) {
        add(&write.path, Some(received.join(&write.path)));
    }
    for delete in plan.deletes.iter().filter(|d| d.kind == Kind::File) {
        add(&delete.path, None);
    }
    for conflict in plan.conflicts.iter().filter(|c| c.beside) {
        let file = received.join(&conflict.path);
        if file.is_file() {
            add(&conflict.path, Some(file));
        }
    }
    let mut diffs = Vec::new();
    let mut merged: Vec<(String, u32)> = Vec::new();
    for (number, (repo, changes)) in by_repo.into_iter().enumerate() {
        let folder = if repo.is_empty() { root.to_path_buf() } else { root.join(&repo) };
        let Some(dirs) = GitDirs::of(&folder).ok().flatten() else { continue };
        if !git_base_known(root, manifest, &repo, &dirs) {
            continue;
        }
        let Ok(base) = git_back::checked(git_back::local(&folder).args([
            "rev-parse",
            "-q",
            "--verify",
            "HEAD^{commit}",
        ])) else {
            continue;
        };
        let base = String::from_utf8_lossy(&base).trim().to_owned();
        let index = staging.0.join(format!("diff-index-{number}"));
        let git = |args: &[&str]| {
            let mut command = git_back::local(&folder);
            command.env("GIT_INDEX_FILE", &index).args(args);
            command
        };
        git_back::checked(&mut git(&["read-tree", &base]))?;
        for change in &changes {
            match &change.file {
                Some(file) => {
                    let id = git_back::checked(
                        git_back::local(&folder)
                            .args(["hash-object", "-w", "--no-filters"])
                            .arg(file),
                    )?;
                    let id = String::from_utf8_lossy(&id).trim().to_owned();
                    let exec = std::fs::metadata(file)
                        .map(|meta| meta.mode() & 0o111 != 0)
                        .unwrap_or(false);
                    let mode = if exec { "100755" } else { "100644" };
                    let info = format!("{mode},{id},{}", change.inside);
                    git_back::checked(&mut git(&["update-index", "--add", "--cacheinfo", &info]))?;
                }
                None => {
                    git_back::checked(&mut git(&[
                        "update-index",
                        "--force-remove",
                        "--",
                        &change.inside,
                    ]))?;
                }
            }
        }
        let tree = git_back::checked(&mut git(&["write-tree"]))?;
        let tree = String::from_utf8_lossy(&tree).trim().to_owned();
        let patch = git_back::checked(git_back::local(&folder).args([
            "diff",
            "--binary",
            "--no-renames",
            "--no-color",
            &base,
            &tree,
        ]))?;
        let kept = records_dir()?.join("back");
        std::fs::create_dir_all(&kept)?;
        let patch_path = kept.join(format!("{name}-{number}.patch"));
        std::fs::write(&patch_path, &patch)?;
        diffs.push(json!({"repo": if repo.is_empty() { "." } else { repo.as_str() }, "base": base,
                          "patch": patch_path, "files": changes.len()}));

        // The preflight's three-way for paths this Mac changed too.
        for change in &changes {
            let Some(conflict) = plan.conflicts.iter().find(|c| c.path == change.path) else {
                continue;
            };
            if conflict.why != way_back::Why::ChangedOnMac {
                continue;
            }
            let (Some(file), Some(now)) = (&change.file, mac.get(&change.path)) else { continue };
            let spec = format!("{base}:{}", change.inside);
            let Ok(base_bytes) =
                git_back::checked(git_back::local(&folder).args(["cat-file", "blob", &spec]))
            else {
                continue;
            };
            let base_file = staging.0.join(format!("merge-base-{}", merged.len()));
            std::fs::write(&base_file, &base_bytes)?;
            let output = git_back::local(&folder)
                .args([
                    "merge-file",
                    "-p",
                    "--quiet",
                    "-L",
                    "this Mac",
                    "-L",
                    "base",
                    "-L",
                    "machine",
                ])
                .arg(root.join(&change.path))
                .arg(&base_file)
                .arg(file)
                .output()
                .context("cannot run git")?;
            if output.status.code() == Some(0) {
                std::fs::write(file, &output.stdout)?;
                merged.push((change.path.clone(), now.mode));
            }
        }
    }
    for (path, mode) in merged {
        plan.conflicts.retain(|c| c.path != path);
        plan.writes.push(way_back::Write {
            path,
            kind: Kind::File,
            mode,
            link: None,
            replaces: Some(Kind::File),
        });
    }
    plan.writes.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(diffs)
}

/// This Mac's path, stat'ed without following a link at its end; None when missing.
fn mac_stat(root: &Path, relative: &str) -> Option<MacStat> {
    let path = root.join(relative);
    let meta = std::fs::symlink_metadata(&path).ok()?;
    let kind = if meta.is_dir() {
        Kind::Dir
    } else if meta.file_type().is_symlink() {
        Kind::Link
    } else {
        Kind::File
    };
    let link = match kind {
        Kind::Link => std::fs::read_link(&path).ok()?.into_os_string().into_string().ok(),
        _ => None,
    };
    let mode =
        if kind == Kind::File { local::permissions_of(meta.mode()) } else { meta.mode() & 0o7777 };
    Some(MacStat {
        kind,
        size: if kind == Kind::Dir { 0 } else { meta.len() },
        mode,
        mtime_ns: meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec()),
        link,
    })
}

/// Drops the plan's new paths (writes and conflicts the manifest never had) that this Mac's git
/// ignores in their repository (build output, dependencies): they stay on the machine, as a copy's
/// pull leaves them. Which paths it dropped.
fn keep_ignored_home(
    root: &Path,
    manifest: &Manifest,
    plan: &mut Plan,
) -> anyhow::Result<Vec<String>> {
    let mut by_repo: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let new_paths = plan
        .writes
        .iter()
        .filter(|write| write.replaces.is_none())
        .map(|write| (write.path.as_str(), write.kind == Kind::Dir))
        .chain(plan.conflicts.iter().map(|c| (c.path.as_str(), false)))
        .filter(|(path, _)| manifest.resolve(path).is_none());
    for (path, dir) in new_paths {
        let Some(repo) = repository_of(manifest, path) else { continue };
        let inside = path_inside(&repo, path);
        // A folder is asked about through a name inside it: git checks a missing path's leading
        // folders as folders (so `target/` matches), never the missing path itself.
        by_repo.entry(repo).or_default().push(if dir {
            format!("{inside}/{PROBE}")
        } else {
            inside
        });
    }
    let mut ignored: Vec<String> = Vec::new();
    for (repo, paths) in by_repo {
        let folder = if repo.is_empty() { root.to_path_buf() } else { root.join(&repo) };
        // The paths go in from a file, so git's answers never wait on a writer of ours.
        let mut input = tempfile::tempfile().context("cannot make a scratch file")?;
        for path in &paths {
            input.write_all(path.as_bytes())?;
            input.write_all(&[0])?;
        }
        input.seek(std::io::SeekFrom::Start(0))?;
        let output = git_back::local(&folder)
            .args(["check-ignore", "--no-index", "-z", "--stdin"])
            .stdin(std::process::Stdio::from(input))
            .stderr(std::process::Stdio::null())
            .output()
            .context("cannot run git")?;
        for hit in output.stdout.split(|byte| *byte == 0).filter(|hit| !hit.is_empty()) {
            let hit = String::from_utf8_lossy(hit);
            let inside = hit.strip_suffix(&format!("/{PROBE}")).unwrap_or(&hit).to_owned();
            ignored.push(if repo.is_empty() { inside } else { format!("{repo}/{inside}") });
        }
    }
    if ignored.is_empty() {
        return Ok(ignored);
    }
    // Only the outermost ignored paths: git names every file under an ignored folder too, and
    // a build tree is 100k of them.
    ignored.sort();
    ignored.dedup();
    let all: BTreeSet<String> = ignored.iter().cloned().collect();
    let within = |path: &str, set: &BTreeSet<String>| {
        path.match_indices('/')
            .any(|(at, _)| path.get(..at).is_some_and(|prefix| set.contains(prefix)))
    };
    ignored.retain(|path| !within(path, &all));
    let roots: BTreeSet<String> = ignored.iter().cloned().collect();
    let under_ignored = |path: &str| roots.contains(path) || within(path, &roots);
    plan.writes.retain(|write| write.replaces.is_some() || !under_ignored(&write.path));
    plan.conflicts.retain(|c| manifest.resolve(&c.path).is_some() || !under_ignored(&c.path));
    Ok(ignored)
}

/// `path` relative to repository folder `repo`, which `repository_of` found as a whole leading
/// folder of it (`""` is the root).
fn path_inside(repo: &str, path: &str) -> String {
    if repo.is_empty() {
        return path.to_owned();
    }
    path.strip_prefix(repo).and_then(|rest| rest.strip_prefix('/')).unwrap_or(path).to_owned()
}

/// The repository (its folder, empty for the top) whose working tree holds `path`, by the
/// manifest's `.git` entries; None outside any.
fn repository_of(manifest: &Manifest, path: &str) -> Option<String> {
    let parts: Vec<&str> = path.split('/').collect();
    (0..parts.len()).rev().filter_map(|end| parts.get(..end)).map(|folder| folder.join("/")).find(
        |folder| {
            let dotgit = if folder.is_empty() { ".git".into() } else { format!("{folder}/.git") };
            manifest.resolve(&dotgit).is_some()
        },
    )
}

/// Whether repository `repo`'s HEAD, branch and index here are as the manifest listed them, so
/// this Mac's git state is the session's base.
fn git_base_known(root: &Path, manifest: &Manifest, repo: &str, dirs: &GitDirs) -> bool {
    let prefix = if repo.is_empty() { ".git".to_owned() } else { format!("{repo}/.git") };
    let Ok(head) = std::fs::read_to_string(dirs.own.join("HEAD")) else { return false };
    let mut files = vec!["HEAD".to_owned(), "index".to_owned(), "packed-refs".to_owned()];
    if let Some(name) = head.trim().strip_prefix("ref:") {
        files.push(name.trim().to_owned());
    }
    files.iter().all(|file| {
        let relative = format!("{prefix}/{file}");
        let listed = manifest.resolve(&relative).and_then(|index| manifest.entry(index));
        match (listed, mac_stat(root, &relative)) {
            (None, None) => true,
            (Some(entry), Some(now)) => {
                entry.kind == now.kind && entry.size == now.size && entry.mtime_ns == now.mtime_ns
            }
            _ => false,
        }
    })
}

/// What [`apply`] did.
#[derive(Default)]
struct Applied {
    written: u64,
    deleted: u64,
    modes: u64,
    /// By conflicting path: the file the machine's version went to (none when nothing to keep,
    /// or this Mac already had the same bytes).
    beside: BTreeMap<String, Option<String>>,
}

/// SHA-256 of this Mac's file at `relative` and its permissions, as a transaction checks it.
fn expected_here(root: &Dir, relative: &str) -> anyhow::Result<Expected> {
    let (parent, name) =
        place::parent_of(root, relative)?.with_context(|| format!("{relative} is gone here"))?;
    let mut file = parent.open_file(&name)?;
    let permissions = local::permissions_of(file.metadata()?.mode());
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher)?;
    Ok(Expected { sha256: hex(&hasher.finalize()), permissions })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Applies the plan's files as one transaction (module docs), then its modes and the conflicts'
/// files beside.
fn apply(
    root_path: &Path,
    staging: &Staging,
    received: &Path,
    manifest: &Manifest,
    plan: &Plan,
) -> anyhow::Result<Applied> {
    let root = Dir::open(root_path)?;
    let mut applied = Applied::default();
    // Each check before the transaction moves anything: hashes of what it replaces or deletes.
    let mut expected: BTreeMap<String, Expected> = BTreeMap::new();
    for delete in plan.deletes.iter().filter(|delete| delete.kind == Kind::File) {
        expected.insert(delete.path.clone(), expected_here(&root, &delete.path)?);
    }
    for write in plan.writes.iter().filter(|write| write.replaces == Some(Kind::File)) {
        expected.insert(write.path.clone(), expected_here(&root, &write.path)?);
    }
    let expected_of = |path: &str| {
        expected.get(path).with_context(|| format!("{path} was not checked before the change"))
    };
    let mut transaction = Transaction::new(root_path, &staging.0)?;
    let mut staged_number = 0u64;
    let outcome = (|| -> anyhow::Result<()> {
        for delete in &plan.deletes {
            match delete.kind {
                Kind::File => transaction.delete(&delete.path, expected_of(&delete.path)?)?,
                Kind::Link => {
                    let text = manifest
                        .resolve(&delete.path)
                        .and_then(|index| manifest.entry(index))
                        .and_then(|entry| entry.link.clone())
                        .unwrap_or_default();
                    transaction.remove_link(&delete.path, &text)?;
                }
                // Folders go once empty, after the transaction.
                Kind::Dir => continue,
            }
            applied.deleted += 1;
        }
        for write in &plan.writes {
            match write.replaces {
                Some(Kind::Link) => {
                    let text = manifest
                        .resolve(&write.path)
                        .and_then(|index| manifest.entry(index))
                        .and_then(|entry| entry.link.clone())
                        .unwrap_or_default();
                    transaction.remove_link(&write.path, &text)?;
                }
                Some(Kind::File) if write.kind != Kind::File => {
                    transaction.delete(&write.path, expected_of(&write.path)?)?;
                }
                Some(Kind::Dir) if write.kind != Kind::Dir => {
                    let (parent, name) = place::parent_of(&root, &write.path)?
                        .with_context(|| format!("{} is gone here", write.path))?;
                    parent.remove_empty_dir(&name).with_context(|| {
                        format!("{} here still holds files; the machine made it a file", write.path)
                    })?;
                }
                _ => {}
            }
            match write.kind {
                Kind::File => {
                    staged_number += 1;
                    let name = format!("back-{staged_number}");
                    let staged = staging.0.join(&name);
                    std::fs::rename(received.join(&write.path), &staged)?;
                    std::fs::set_permissions(
                        &staged,
                        std::fs::Permissions::from_mode(local::permissions_of(write.mode)),
                    )?;
                    let replaced = if write.replaces == Some(Kind::File) {
                        Some(expected_of(&write.path)?)
                    } else {
                        None
                    };
                    transaction.write(&write.path, &name, replaced)?;
                }
                Kind::Link => {
                    transaction.link(&write.path, write.link.as_deref().unwrap_or_default())?;
                }
                Kind::Dir => transaction.folder(&write.path)?,
            }
            applied.written += 1;
        }
        Ok(())
    })();
    if let Err(error) = outcome {
        if let Err(left) = transaction.roll_back() {
            staging.keep();
            bail!(
                "{error:#}; these could not be put back and are in {}: {}",
                staging.0.display(),
                left.join(", ")
            );
        }
        return Err(error.context("nothing changed here"));
    }
    transaction.finish();
    for delete in plan.deletes.iter().filter(|delete| delete.kind == Kind::Dir) {
        if let Ok(Some((parent, name))) = place::parent_of(&root, &delete.path) {
            let _ = parent.remove_empty_dir(&name);
        }
    }
    for chmod in &plan.modes {
        let (file, _, _) = place::open_beneath(root_path, &chmod.path)?;
        file.set_permissions(std::fs::Permissions::from_mode(local::permissions_of(chmod.mode)))?;
        applied.modes += 1;
    }
    for conflict in &plan.conflicts {
        let machine = received.join(&conflict.path);
        let side = if conflict.beside && machine.is_file() {
            let bytes = std::fs::read(&machine)?;
            let same = place::open_beneath(root_path, &conflict.path).ok().is_some_and(
                |(mut file, _, _)| {
                    let mut here = Vec::new();
                    file.read_to_end(&mut here).is_ok() && here == bytes
                },
            );
            if same { None } else { Some(merge::write_conflict(&root, &conflict.path, &bytes)?) }
        } else {
            None
        };
        applied.beside.insert(conflict.path.clone(), side);
    }
    Ok(applied)
}

/// One request-only dial (`projection.brought_back`, `projection.release`): the machine's answer,
/// `Err` with it when refused.
fn dial_answer(socket: &Path, line: &Value) -> anyhow::Result<Result<Value, Value>> {
    dial_answer_within(socket, line, ANSWER_WAIT)
}

/// [`dial_answer`], waiting up to `wait` for the answer (a pin fetches before it answers).
pub(super) fn dial_answer_within(
    socket: &Path,
    line: &Value,
    wait: Duration,
) -> anyhow::Result<Result<Value, Value>> {
    let (answer, _) = dial_raw(socket, line, &[], wait)?;
    Ok(if field(&answer, "/ok").as_bool() == Some(true) { Ok(answer) } else { Err(answer) })
}

/// The value at `pointer` in a machine's answer, `null` when it has none.
pub(super) fn field<'a>(answer: &'a Value, pointer: &str) -> &'a Value {
    static NULL: Value = Value::Null;
    answer.pointer(pointer).unwrap_or(&NULL)
}

/// One Bring Back dial: `line` (with an id added) and `body`, then the machine's answer line,
/// refused unless ok; the stream after it.
fn dial(
    socket: &Path,
    line: &Value,
    body: &[u8],
) -> anyhow::Result<(Value, BufReader<UnixStream>)> {
    let (answer, reader) = dial_raw(socket, line, body, ANSWER_WAIT)?;
    if field(&answer, "/ok").as_bool() != Some(true) {
        let code = answer.get("error_code");
        if code.is_none_or(|code| code.as_str() == Some("projection.unavailable")) {
            bail!("the machine does not serve Bring Back for projected folders: {answer}");
        }
        bail!("{}", field(&answer, "/error").as_str().unwrap_or("the machine refused Bring Back"));
    }
    Ok((answer, reader))
}

/// [`dial`], ok or not.
fn dial_raw(
    socket: &Path,
    line: &Value,
    body: &[u8],
    wait: Duration,
) -> anyhow::Result<(Value, BufReader<UnixStream>)> {
    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("cannot reach the machine at {}", socket.display()))?;
    let mut line = line.clone();
    if let Some(fields) = line.as_object_mut() {
        fields.insert("id".to_owned(), json!(1));
    }
    let mut bytes = serde_json::to_vec(&line)?;
    bytes.push(b'\n');
    stream.write_all(&bytes)?;
    stream.write_all(body)?;
    stream.flush()?;
    stream.set_read_timeout(Some(wait))?;
    let mut reader = BufReader::with_capacity(256 * 1024, stream);
    let mut answer = String::new();
    reader.read_line(&mut answer)?;
    let answer: Value = serde_json::from_str(answer.trim())
        .with_context(|| format!("the machine answered {answer:?}"))?;
    Ok((answer, reader))
}

#[cfg(test)]
#[path = "project_back_tests.rs"]
mod tests;
