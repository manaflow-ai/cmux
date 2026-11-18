//! Bring Back over a projected folder (RFD 0007; Leo: "each chat gets its own copy-on-write layer
//! over the projection so nothing touches the person's files until it comes back"). What the
//! agent wrote sits in the projection's upper layer on the machine; this brings it here in
//! O(edits):
//!
//! 1. the machine's listing of the upper layer and whiteouts (`projection.layer`, no bytes);
//! 2. this Mac's stat of each path they touch, against the manifest the session started from
//!    (kept here by `serve`, [`record`]), planned by [`cmux_projection::way_back::plan`]: writes,
//!    deletes, mode changes and named conflicts. New paths this Mac's git ignores stay there;
//! 3. only the files the plan writes or names come over (`projection.files`), and the upper's
//!    `.git` files of each repository go through the HEAD and index three-way
//!    ([`super::git_back::plan_from_layer`]), never copied as files;
//! 4. one transaction here ([`super::place`]): every file replaced or deleted is checked to be
//!    still the one planned (its SHA-256 taken at plan time), and any failure puts back what
//!    changed. A conflict's machine version is written beside this Mac's file
//!    (`NAME.cmux-sync-conflict`, [`super::merge::write_conflict`]); this Mac's is never replaced.
//!    A git conflict stops everything before a file changes.
//! 5. Only once all of that applied does the machine drop the projection (`projection.drop`:
//!    unmount, delete the upper layer and cache) and this Mac stop the folder's server.
//!
//!     cmux link project back --socket S --at REMOTE FOLDER [--keep]

use std::collections::BTreeMap;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
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
    let local = std::fs::canonicalize(local).ok()?;
    let dir = records_dir().ok()?;
    std::fs::read_dir(dir).ok()?.filter_map(Result::ok).find_map(|entry| {
        let name = entry.file_name().into_string().ok()?;
        name.strip_suffix(".json")?;
        let bytes = std::fs::read(entry.path()).ok()?;
        let found: Recorded = serde_json::from_slice(&bytes).ok()?;
        let same = found.remote.trim_end_matches('/') == remote.trim_end_matches('/');
        (same && found.local == local).then_some(found)
    })
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

/// Bring Back of the projected folder `found` (module docs). `keep`: leave the projection on the
/// machine afterwards.
pub(in crate::link) fn bring_back(socket: &Path, found: &Recorded, keep: bool) -> Back {
    match run(socket, found, keep) {
        Ok(back) => back,
        Err(error) => Back::Failed { code: "sync_failed".into(), error: format!("{error:#}") },
    }
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

    let (answer, mut reader) =
        dial(socket, &json!({"cmd": "projection.layer", "name": found.name}), &[])?;
    let bytes = answer["data"]["bytes"].as_u64().context("the machine sent no listing size")?;
    let mut raw = Vec::new();
    (&mut reader).take(bytes).read_to_end(&mut raw)?;
    anyhow::ensure!(raw.len() as u64 == bytes, "the machine's listing ended early");
    let mut changed = Layer::decode(&raw)?;
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
    if !wanted.is_empty() {
        let list = wanted.join("\n").into_bytes();
        let line =
            json!({"cmd": "projection.files", "name": found.name, "paths_bytes": list.len()});
        let (_, mut reader) = dial(socket, &line, &list)?;
        let arrived = layer::receive_files(&mut reader, &wanted, &received, MAX_FILE)?;
        for (path, came) in wanted.iter().zip(&arrived) {
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

    let applied = apply(&root, &staging, &received, &manifest, &plan)?;
    let mut moved = Vec::new();
    for (folder, git_plan) in &git_plans {
        git_plan.fetch(folder)?;
        if git_plan.commit(folder)? {
            moved.push(folder.strip_prefix(&root).unwrap_or(folder).display().to_string());
        }
    }
    let applied_ms = ms(started);

    let mut dropped = false;
    if !keep {
        let (answer, _) =
            dial(socket, &json!({"cmd": "projection.drop", "name": found.name}), &[])?;
        dropped = answer["data"]["dropped"] == true;
        let _ = super::project::stop_server(&found.name);
        forget(&found.name);
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
    Ok(Back::Done(json!({
        "ok": true,
        "mode": "projection",
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
        "dropped": dropped,
        "timings": {"listed_ms": listed_ms, "plan_ms": plan_ms, "fetched_ms": fetched_ms,
                    "applied_ms": applied_ms, "total_ms": ms(started)},
    })))
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
        let inside =
            if repo.is_empty() { path.to_owned() } else { path[repo.len() + 1..].to_owned() };
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
        let mut child = git_back::local(&folder)
            .args(["check-ignore", "--no-index", "-z", "--stdin"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .context("cannot run git")?;
        let mut input = Vec::new();
        for path in &paths {
            input.extend_from_slice(path.as_bytes());
            input.push(0);
        }
        let mut stdin = child.stdin.take().context("no pipe to git")?;
        let writer = std::thread::spawn(move || stdin.write_all(&input));
        let output = child.wait_with_output()?;
        let _ = writer.join();
        for hit in output.stdout.split(|byte| *byte == 0).filter(|hit| !hit.is_empty()) {
            let hit = String::from_utf8_lossy(hit);
            let inside = hit.strip_suffix(&format!("/{PROBE}")).unwrap_or(&hit).to_owned();
            ignored.push(if repo.is_empty() { inside } else { format!("{repo}/{inside}") });
        }
    }
    if ignored.is_empty() {
        return Ok(ignored);
    }
    ignored.sort();
    let under_ignored =
        |path: &str| ignored.iter().any(|hit| path == hit || path.starts_with(&format!("{hit}/")));
    plan.writes.retain(|write| write.replaces.is_some() || !under_ignored(&write.path));
    plan.conflicts.retain(|c| manifest.resolve(&c.path).is_some() || !under_ignored(&c.path));
    Ok(ignored)
}

/// The repository (its folder, empty for the top) whose working tree holds `path`, by the
/// manifest's `.git` entries; None outside any.
fn repository_of(manifest: &Manifest, path: &str) -> Option<String> {
    let parts: Vec<&str> = path.split('/').collect();
    (0..parts.len()).rev().map(|end| parts[..end].join("/")).find(|folder| {
        let dotgit = if folder.is_empty() { ".git".into() } else { format!("{folder}/.git") };
        manifest.resolve(&dotgit).is_some()
    })
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
    let mut transaction = Transaction::new(root_path, &staging.0)?;
    let mut staged_number = 0u64;
    let outcome = (|| -> anyhow::Result<()> {
        for delete in &plan.deletes {
            match delete.kind {
                Kind::File => transaction.delete(&delete.path, &expected[&delete.path])?,
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
                    transaction.delete(&write.path, &expected[&write.path])?;
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
                    let replaced =
                        (write.replaces == Some(Kind::File)).then(|| &expected[&write.path]);
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

/// One Bring Back dial: `line` (with an id added) and `body`, then the machine's answer line,
/// refused unless ok; the stream after it.
fn dial(
    socket: &Path,
    line: &Value,
    body: &[u8],
) -> anyhow::Result<(Value, BufReader<UnixStream>)> {
    let mut stream = UnixStream::connect(socket)
        .with_context(|| format!("cannot reach the machine at {}", socket.display()))?;
    let mut line = line.clone();
    line["id"] = json!(1);
    let mut bytes = serde_json::to_vec(&line)?;
    bytes.push(b'\n');
    stream.write_all(&bytes)?;
    stream.write_all(body)?;
    stream.flush()?;
    stream.set_read_timeout(Some(ANSWER_WAIT))?;
    let mut reader = BufReader::with_capacity(256 * 1024, stream);
    let mut answer = String::new();
    reader.read_line(&mut answer)?;
    let answer: Value = serde_json::from_str(answer.trim())
        .with_context(|| format!("the machine answered {answer:?}"))?;
    if answer["ok"] != true {
        if answer["error_code"] == "projection.unavailable" || answer.get("error_code").is_none() {
            bail!("the machine does not serve Bring Back for projected folders: {answer}");
        }
        bail!("{}", answer["error"].as_str().unwrap_or("the machine refused Bring Back"));
    }
    Ok((answer, reader))
}

#[cfg(test)]
#[path = "project_back_tests.rs"]
mod tests;
