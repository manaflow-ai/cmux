//! `cmux link sync relay --from-socket A --socket B FROM TO`: copies the
//! folder `FROM` of one Cloud machine to the folder `TO` of another, through
//! this Mac's two machine links and never through its disk (Move to another
//! Cloud machine). Both ends speak `fs-v1`; neither machine reaches the
//! other, so this process is the pump.
//!
//! What goes is the whole folder as the source machine has it: the working
//! tree with every uncommitted, staged and untracked change, and the
//! repository itself (`.git` with its objects, refs, index and stash), so
//! the chat finds the same checkout on the far side. Dependency and build
//! folders the project rebuilds (`node_modules`, a Cargo `target`, the
//! names [`super::skips::heavy_by`] knows) stay behind, as with a push.
//! Symlinks are kept when their text is relative and stays inside the
//! folder; any other is skipped and named.
//!
//! The copy is pipelined: up to [`super::connections`] workers, each with a
//! connection to both machines, read a file from the source and write it to
//! the target at once (a file over [`STREAM_BYTES`] is streamed through a
//! bounded channel, so its read and its write overlap and at most a few
//! parts are held here). The listing and the folders come first, on one
//! connection to each side.
//!
//! A record on this Mac (`<state>/link-relay/<sha256>.json`, keyed by both
//! sockets and both folders) keeps each file's source revision and the
//! revision its write gave it on the target. A relay into the same folder
//! again (the frozen pass of `cmux link agent move --sync relay`, or a retry
//! after a cut) copies only what changed on the source since, or what
//! changed on the target, and deletes on the target what the source no
//! longer has, when the target still has it as the last relay left it.
//!
//! A target folder that exists, holds anything and has no record is never
//! written into: the relay refuses it (`relay.target_exists`).
//!
//! Output: progress on stderr as JSON lines (`{"progress":{"files_done",
//! "files_total","bytes_done","bytes_total"}}`), one JSON line on stdout,
//! the push's summary (`{"ok":true,"written","unchanged","deleted",
//! "skipped","bytes","skipped_files","skipped_counts"}`), or `{"ok":false,
//! "error","error_code"}` (exit 1); bad usage exits 64.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;

use anyhow::{Context as _, bail};
use cmux_json::JsonSet as _;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest as _, Sha256};

use super::remote::{self, Remote};
use super::{Progress, Summary, skips};

pub(super) const USAGE: &str = "usage: cmux link sync relay --from-socket SOURCE_LINK --socket TARGET_LINK SOURCE_FOLDER TARGET_FOLDER";

/// A file at most this big is read whole, then written; a bigger one is
/// streamed from the source to the target part by part.
const STREAM_BYTES: u64 = 8 * 1024 * 1024;
/// Parts of a streamed file held between its read and its write.
const STREAM_DEPTH: usize = 4;
/// Bytes per streamed part handed from the read to the write.
const STREAM_PART: usize = 1024 * 1024;
/// The refusal of a relay into a folder the target has that no relay made.
pub(super) const TARGET_EXISTS: &str = "relay.target_exists";
/// Files landed between two saves of the record, so a cut relay redoes at most these.
const CHECKPOINT: u64 = 64;
/// Most paths named in `skipped_files`.
const NAMED_SKIPS: usize = 50;

/// One entry of the source folder, relative to its root.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Item {
    File { size: u64, revision: String },
    Link { target: String },
}

/// What the last relay into a target folder left there.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
struct Record {
    /// Relative path to (source revision, target revision).
    files: BTreeMap<String, (String, String)>,
    /// Relative path to symlink text.
    #[serde(default)]
    links: BTreeMap<String, String>,
}

/// One file a worker copies.
struct Job {
    relative: String,
    size: u64,
    revision: String,
}

/// The CLI: `cmux link sync relay ...`.
pub(super) fn run(args: &[String]) -> i32 {
    let Some((from, to, from_root, to_root)) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    for socket in [&from, &to] {
        if let Some(outdated) =
            super::super::machine_gate::outdated(socket, &[cmux_tui_core::fs_ops::FS_CAPABILITY])
        {
            println!("{}", outdated.line());
            return 1;
        }
    }
    let mut printer = super::progress_printer();
    // One person's copy from a shell: its own owner, apart from any chat's move.
    match relay(&from, &from_root, &to, &to_root, "cli", &mut printer) {
        Ok(summary) => {
            let mut line = summary.json();
            line.set("ok", json!(true));
            println!("{line}");
            0
        }
        Err(error) => {
            let (code, error) = super::push_failure(&error);
            println!("{}", json!({ "ok": false, "error": error, "error_code": code }));
            1
        }
    }
}

fn parse(args: &[String]) -> Option<(PathBuf, PathBuf, String, String)> {
    let mut from = None;
    let mut to = None;
    let mut positional = Vec::new();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--from-socket" => from = Some(PathBuf::from(rest.next()?)),
            "--socket" => to = Some(PathBuf::from(rest.next()?)),
            flag if flag.starts_with('-') => return None,
            value => positional.push(value),
        }
    }
    let [from_root, to_root] = positional.as_slice() else { return None };
    if !from_root.starts_with('/') || !to_root.starts_with('/') {
        return None;
    }
    let trim = |root: &str| {
        let trimmed = root.trim_end_matches('/');
        if trimmed.is_empty() { "/".to_string() } else { trimmed.to_string() }
    };
    Some((from?, to?, trim(from_root), trim(to_root)))
}

/// Copies `from_root` on the machine at `from` to `to_root` on the machine
/// at `to` (module docs), with progress through `progress`. `owner` is the move
/// the copy is for: its record is that move's alone, so another move to the same
/// folder finds it there and is refused (`relay.target_exists`).
pub(in crate::link) fn relay(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    owner: &str,
    progress: &mut dyn FnMut(Progress),
) -> anyhow::Result<Summary> {
    let mut source = Remote::connect_negotiated(from)?;
    let mut target = Remote::connect_negotiated(to)?;
    if source.kind(from_root)?.as_deref() != Some("dir") {
        bail!("the source machine has no folder {from_root}");
    }
    let mut skipped = Skipped::default();
    let (dirs, items) = walk(&mut source, from_root, &mut skipped)?;
    let record_path = record_path(from, from_root, to, to_root, owner);
    let kept = record_path.as_deref().and_then(load);
    // A folder already on the target that no relay made is someone's work: never written over.
    if kept.is_none() && target.list(to_root)?.is_some_and(|entries| !entries.is_empty()) {
        return Err(remote::FsRefusal {
            code: TARGET_EXISTS.to_string(),
            message: format!("the target machine already has a folder {to_root}"),
        }
        .into());
    }
    let mut record = kept.unwrap_or_default();
    // What the target has now, by path: the files the record names, and so
    // whether each is still as the last relay left it.
    target.mkdir_all(to_root)?;
    let mut target_now = BTreeMap::new();
    let mut listed = BTreeSet::new();
    // Folders on the target that are folders all the way down from `to_root`: one swapped for a
    // symlink since would list (and delete) what it points at, outside the target folder.
    let mut real = BTreeMap::new();
    for relative in record.files.keys().chain(record.links.keys()) {
        let parent = parent_of(relative);
        if !real_folder(&mut target, to_root, parent, &mut real)? {
            continue;
        }
        if listed.insert(parent.to_string()) {
            let folder = join(to_root, parent);
            if let Some(entries) = target.list(&folder)? {
                for (name, entry) in entries {
                    let path = if parent.is_empty() { name } else { format!("{parent}/{name}") };
                    target_now.insert(path, entry);
                }
            }
        }
    }
    let unchanged_there = |record: &Record, relative: &str| {
        record.files.get(relative).is_some_and(|(_, there)| {
            target_now
                .get(relative)
                .is_some_and(|now| now.kind == "file" && now.revision.as_deref() == Some(there))
        })
    };
    // What the source no longer has goes on the target, when the target
    // still has it as the last relay left it.
    let mut summary = Summary::default();
    let gone: Vec<String> = record
        .files
        .keys()
        .filter(|relative| !matches!(items.get(*relative), Some(Item::File { .. })))
        .cloned()
        .collect();
    let mut deletes = Vec::new();
    for relative in &gone {
        if unchanged_there(&record, relative) {
            deletes.push(join(to_root, relative));
        }
        record.files.remove(relative);
    }
    for (relative, text) in record.links.clone() {
        if !matches!(items.get(&relative), Some(Item::Link { .. })) {
            // Only the link the last relay made: anything put there since is the target's.
            let path = join(to_root, &relative);
            if (parent_of(&relative).is_empty() || real.get(parent_of(&relative)) == Some(&true))
                && link_is(&mut target, &path, &text)
            {
                deletes.push(path);
            }
            record.links.remove(&relative);
        }
    }
    summary.deleted = deletes.len() as u64;
    target.delete(&deletes)?;
    // A folder the target made something else since (a symlink, say) is the target's: nothing
    // goes in or under it. Asked only when its mkdir refuses, so a relay pays nothing for it.
    let mut theirs: Vec<String> = Vec::new();
    for dir in &dirs {
        if theirs.iter().any(|folder| inside(dir, folder)) {
            continue;
        }
        let path = join(to_root, dir);
        match target.mkdir_all(&path) {
            Ok(()) => {}
            Err(_) if target.kind(&path)?.is_some_and(|kind| kind != "dir") => {
                skipped.add(dir, "folder", "the target machine changed it since the last copy");
                theirs.push(dir.clone());
            }
            Err(error) => return Err(error),
        }
    }
    let mut jobs = Vec::new();
    // Made once the files are there: the target refuses a symlink whose target is missing.
    let mut links = Vec::new();
    let mut totals = Progress::default();
    for (relative, item) in &items {
        if theirs.iter().any(|folder| inside(relative, folder)) {
            continue;
        }
        match item {
            Item::File { size, revision } => {
                // Counts and byte sums of one folder: far below u64::MAX, never wrapped.
                totals.files_total = totals.files_total.saturating_add(1);
                totals.bytes_total = totals.bytes_total.saturating_add(*size);
                let same = record.files.get(relative).is_some_and(|(was, _)| was == revision)
                    && unchanged_there(&record, relative);
                if same {
                    summary.unchanged = summary.unchanged.saturating_add(1);
                    totals.files_done = totals.files_done.saturating_add(1);
                    totals.bytes_done = totals.bytes_done.saturating_add(*size);
                } else {
                    jobs.push(Job {
                        relative: relative.clone(),
                        size: *size,
                        revision: revision.clone(),
                    });
                }
            }
            Item::Link { target: text } => {
                if record.links.get(relative) != Some(text) {
                    links.push((relative.clone(), text.clone()));
                }
            }
        }
    }
    progress(totals);
    // The folder is this relay's from here: a retry after a cut goes on instead of refusing.
    if let Some(path) = &record_path {
        save(path, &record)?;
    }
    // Big files last, so the small ones fill every connection first.
    jobs.sort_by_key(|job| job.size);
    let landed = copy_parallel(from, from_root, to, to_root, jobs, &mut |job, revision| {
        summary.written = summary.written.saturating_add(1);
        summary.bytes = summary.bytes.saturating_add(job.size);
        totals.files_done = totals.files_done.saturating_add(1);
        totals.bytes_done = totals.bytes_done.saturating_add(job.size);
        progress(totals);
        record.files.insert(job.relative, (job.revision, revision));
        if summary.written % CHECKPOINT == 0
            && let Some(path) = &record_path
        {
            let _ = save(path, &record);
        }
    })
    .and_then(|()| {
        // A link to a link waits for that one: rounds go on while any lands (a → b → c).
        let mut pending = links;
        loop {
            let mut waiting = Vec::new();
            let tried = pending.len();
            for (relative, text) in pending {
                let path = join(to_root, &relative);
                // Replaced only when it is what the last relay left there: the link it made or a
                // file it wrote that nothing changed since. Anything else is the target's work.
                let ours =
                    record.links.get(&relative).is_some_and(|was| link_is(&mut target, &path, was))
                        || unchanged_there(&record, &relative);
                match target.kind(&path)? {
                    None => {}
                    Some(_) if ours => target.delete(std::slice::from_ref(&path))?,
                    Some(_) => {
                        skipped.add(
                            &relative,
                            "symlink",
                            "the target machine changed it since the last copy",
                        );
                        continue;
                    }
                }
                match target.symlink(&path, &text) {
                    Ok(()) => {
                        record.links.insert(relative, text);
                    }
                    Err(error) if remote::lacks_symlinks(&error) => {
                        skipped.add(&relative, "symlink", "the target machine takes no symlinks");
                    }
                    Err(error)
                        if format!("{error:#}").contains("symlink's target is not there") =>
                    {
                        waiting.push((relative, text));
                    }
                    Err(error) => return Err(error),
                }
            }
            if waiting.is_empty() || waiting.len() == tried {
                // What still waits points at something the copy left out (a dependency folder, say).
                for (relative, _) in waiting {
                    skipped.add(&relative, "symlink", "it points at something left out");
                }
                return Ok(());
            }
            pending = waiting;
        }
    });
    if let Some(path) = &record_path {
        // A cut relay keeps what landed, so the next one skips it.
        let _ = save(path, &record);
    }
    landed?;
    progress(totals);
    summary.skipped = skipped.count;
    summary.skipped_files = json!(skipped.named);
    summary.skipped_counts = json!(skipped.kinds);
    Ok(summary)
}

/// Whether `parent` (relative to `root`) and each folder above it are folders on `target`, not
/// symlinks, by `fs.stat`, which does not follow them; `seen` keeps each answer.
fn real_folder(
    target: &mut Remote,
    root: &str,
    parent: &str,
    seen: &mut BTreeMap<String, bool>,
) -> anyhow::Result<bool> {
    if parent.is_empty() {
        return Ok(true);
    }
    if let Some(known) = seen.get(parent) {
        return Ok(*known);
    }
    let above = real_folder(target, root, parent_of(parent), seen)?;
    let real = above && target.kind(&join(root, parent))?.as_deref() == Some("dir");
    seen.insert(parent.to_string(), real);
    Ok(real)
}

/// Whether `path` on `target` is still the symlink `text`.
fn link_is(target: &mut Remote, path: &str, text: &str) -> bool {
    target.readlink(path).ok().flatten().as_deref() == Some(text)
}

/// The paths left out, as a push reports them.
#[derive(Default)]
struct Skipped {
    count: u64,
    named: Vec<serde_json::Value>,
    kinds: BTreeMap<String, u64>,
}

impl Skipped {
    fn add(&mut self, path: &str, kind: &str, why: &str) {
        self.count = self.count.saturating_add(1);
        let of_kind = self.kinds.entry(kind.to_string()).or_default();
        *of_kind = of_kind.saturating_add(1);
        if self.named.len() < NAMED_SKIPS {
            self.named.push(json!({ "path": path, "kind": kind, "why": why }));
        }
    }
}

/// Every folder (parents first) and every file and kept symlink under
/// `root` on `source`, relative to it.
fn walk(
    source: &mut Remote,
    root: &str,
    skipped: &mut Skipped,
) -> anyhow::Result<(Vec<String>, BTreeMap<String, Item>)> {
    let mut dirs = Vec::new();
    let mut items = BTreeMap::new();
    let mut queue = std::collections::VecDeque::from([String::new()]);
    while let Some(relative) = queue.pop_front() {
        let folder = join(root, &relative);
        let Some(entries) = source.list(&folder)? else { continue };
        let names: BTreeSet<&str> = entries.keys().map(String::as_str).collect();
        for (name, entry) in &entries {
            let path =
                if relative.is_empty() { name.clone() } else { format!("{relative}/{name}") };
            match entry.kind.as_str() {
                "dir" => {
                    let heavy = skips::heavy_by(name, |file| {
                        names.contains(file)
                            || (file.contains('/')
                                && source
                                    .kind(&format!("{folder}/{file}"))
                                    .ok()
                                    .flatten()
                                    .as_deref()
                                    == Some("file"))
                    });
                    if heavy {
                        skipped.add(&path, "dependency", "the project rebuilds it");
                        continue;
                    }
                    dirs.push(path.clone());
                    queue.push_back(path);
                }
                "file" => {
                    let size = entry.revision.as_deref().and_then(size_of).unwrap_or(0);
                    let revision = entry.revision.clone().unwrap_or_default();
                    items.insert(path, Item::File { size, revision });
                }
                "symlink" => match source.readlink(&join(root, &path))? {
                    Some(text) if stays_inside(&path, &text) => {
                        items.insert(path, Item::Link { target: text });
                    }
                    _ => skipped.add(&path, "symlink", "it points outside the folder"),
                },
                _ => skipped.add(&path, "other", "not a file, folder or symlink"),
            }
        }
    }
    Ok((dirs, items))
}

/// The size in a revision token (`s{size}-m{mtime}`).
fn size_of(revision: &str) -> Option<u64> {
    revision.strip_prefix('s')?.split('-').next()?.parse().ok()
}

/// Whether the symlink at `path` (relative to the folder) with `text`
/// resolves inside the folder.
fn stays_inside(path: &str, text: &str) -> bool {
    if text.is_empty() || text.starts_with('/') {
        return false;
    }
    let mut depth: Vec<&str> = path.split('/').collect();
    depth.pop();
    for part in text.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if depth.pop().is_none() {
                    return false;
                }
            }
            other => depth.push(other),
        }
    }
    true
}

/// Whether `relative` is `folder` or below it.
fn inside(relative: &str, folder: &str) -> bool {
    relative.strip_prefix(folder).is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

fn parent_of(relative: &str) -> &str {
    relative.rsplit_once('/').map_or("", |(parent, _)| parent)
}

fn join(root: &str, relative: &str) -> String {
    if relative.is_empty() {
        root.to_string()
    } else if root == "/" {
        format!("/{relative}")
    } else {
        format!("{root}/{relative}")
    }
}

/// The permission bits of the source file: from its `fs.stat`
/// (`mode_display`), 0o644 when that says nothing. Git's objects are
/// read-only blobs git never executes, so they skip the round trip.
fn permissions(source: &mut Remote, root: &str, relative: &str) -> anyhow::Result<u32> {
    if relative.starts_with(".git/objects/") {
        return Ok(0o644);
    }
    let Some(stat) = source.stat(&join(root, relative))? else { return Ok(0o644) };
    let display = stat.get("mode_display").and_then(serde_json::Value::as_str).unwrap_or("");
    // The target takes four modes (0644, 0755, 0600, 0700); a 0664 or 0775 maps to its nearest.
    Ok(mode_of(display).map_or(0o644, super::local::permissions_of))
}

/// `rwxr-xr-x` to its bits, owner write always kept.
fn mode_of(display: &str) -> Option<u32> {
    let bytes = display.as_bytes();
    if bytes.len() != 9 {
        return None;
    }
    // The bit each of the nine letters sets, owner read first.
    const BITS: [u32; 9] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001];
    let mut mode = 0u32;
    for (byte, bit) in bytes.iter().zip(BITS) {
        if *byte != b'-' {
            mode |= bit;
        }
    }
    Some(mode | 0o600)
}

/// Copies `jobs` on up to [`super::connections`] workers, each with its own
/// connection to both machines; `landed` hears each file written (with its
/// new revision on the target), on this thread. The first failure stops new
/// copies; those under way finish and are heard, and that failure is the
/// answer.
fn copy_parallel(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    jobs: Vec<Job>,
    landed: &mut dyn FnMut(Job, String),
) -> anyhow::Result<()> {
    let workers = super::connections().min(jobs.len());
    if workers == 0 {
        return Ok(());
    }
    let queue = Mutex::new(jobs.into_iter());
    let stop = AtomicBool::new(false);
    let (sent, results) = mpsc::channel::<(Job, anyhow::Result<String>)>();
    std::thread::scope(|scope| {
        for _ in 0..workers {
            let sent = sent.clone();
            let (queue, stop) = (&queue, &stop);
            scope.spawn(move || {
                let mut ends: Option<(Remote, Remote)> = None;
                while !stop.load(Ordering::Relaxed) {
                    let Some(job) = queue.lock().ok().and_then(|mut jobs| jobs.next()) else {
                        break;
                    };
                    let copied = copy_on(&mut ends, from, from_root, to, to_root, &job);
                    if copied.is_err() {
                        // A broken connection is not used again.
                        ends = None;
                    }
                    if sent.send((job, copied)).is_err() {
                        break;
                    }
                }
            });
        }
        drop(sent);
        let mut failed = None;
        for (job, copied) in results {
            match copied {
                Ok(revision) => landed(job, revision),
                Err(error) => {
                    stop.store(true, Ordering::Relaxed);
                    failed.get_or_insert(error.context(format!("copying {}", job.relative)));
                }
            }
        }
        failed.map_or(Ok(()), Err)
    })
}

fn copy_on(
    ends: &mut Option<(Remote, Remote)>,
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    job: &Job,
) -> anyhow::Result<String> {
    if ends.is_none() {
        *ends = Some((Remote::connect_negotiated(from)?, Remote::connect_negotiated(to)?));
    }
    let Some((source, target)) = ends.as_mut() else { bail!("no connection to the machines") };
    let mode = permissions(source, from_root, &job.relative)?;
    let source_path = join(from_root, &job.relative);
    let target_path = join(to_root, &job.relative);
    if job.size <= STREAM_BYTES {
        let bytes = source
            .read(&source_path)?
            .with_context(|| format!("{source_path} went away on the source machine"))?;
        return target.write(&target_path, &mut bytes.as_slice(), mode);
    }
    // Streamed: the read runs on a thread of its own and hands parts over a
    // bounded channel, so the write sends while the read fetches.
    let (parts, incoming) = mpsc::sync_channel::<Vec<u8>>(STREAM_DEPTH);
    std::thread::scope(|scope| {
        let reading = scope.spawn(move || -> anyhow::Result<()> {
            let mut out = PartWriter { parts, held: Vec::with_capacity(STREAM_PART) };
            source
                .read_into(&source_path, &mut out)?
                .with_context(|| format!("{source_path} went away on the source machine"))?;
            out.flush()?;
            Ok(())
        });
        let mut reader = PartReader { incoming, held: Vec::new(), at: 0 };
        let written = target.write(&target_path, &mut reader, mode);
        // A write that stopped early drops the reader, which ends the read.
        drop(reader);
        let read =
            reading.join().map_err(|_| anyhow::anyhow!("the read of {} panicked", job.relative))?;
        read?;
        written
    })
}

/// The read side of a streamed file: parts into the channel.
struct PartWriter {
    parts: mpsc::SyncSender<Vec<u8>>,
    held: Vec<u8>,
}

impl Write for PartWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.held.extend_from_slice(bytes);
        if self.held.len() >= STREAM_PART {
            self.flush()?;
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        if self.held.is_empty() {
            return Ok(());
        }
        let part = std::mem::replace(&mut self.held, Vec::with_capacity(STREAM_PART));
        self.parts.send(part).map_err(|_| std::io::Error::other("the write to the target stopped"))
    }
}

/// The write side of a streamed file: the channel's parts as one reader.
struct PartReader {
    incoming: mpsc::Receiver<Vec<u8>>,
    held: Vec<u8>,
    at: usize,
}

impl Read for PartReader {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        while self.at == self.held.len() {
            match self.incoming.recv() {
                Ok(part) => {
                    self.held = part;
                    self.at = 0;
                }
                Err(_) => return Ok(0),
            }
        }
        let held = self.held.get(self.at..).unwrap_or_default();
        let count = out.len().min(held.len());
        out.iter_mut().zip(held).for_each(|(to, from)| *to = *from);
        // An offset into `held`: an overflow is an error, never a clamped position.
        self.at = self
            .at
            .checked_add(count)
            .ok_or_else(|| std::io::Error::other("the relayed part's offset overflowed"))?;
        Ok(count)
    }
}

fn record_path(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    owner: &str,
) -> Option<PathBuf> {
    let state = cmux_tui_core::platform::workspace_state_dir()?;
    let mut hash = Sha256::new();
    let (from, to) = (from.to_string_lossy(), to.to_string_lossy());
    for part in [from.as_ref(), from_root, to.as_ref(), to_root, owner] {
        hash.update(part.as_bytes());
        hash.update([0]);
    }
    let name: String = hash.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    Some(state.join("link-relay").join(format!("{name}.json")))
}

fn load(path: &Path) -> Option<Record> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

fn save(path: &Path, record: &Record) -> anyhow::Result<()> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let folder = path.parent().context("the relay record has no folder")?;
    std::fs::create_dir_all(folder)?;
    let temporary = path.with_extension("json.tmp");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(&serde_json::to_vec(record)?)?;
    file.sync_all()?;
    std::fs::rename(&temporary, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{mode_of, parse, size_of, stays_inside};

    #[test]
    fn a_symlink_is_kept_only_inside_the_folder() {
        assert!(stays_inside("a/link", "b"));
        assert!(stays_inside("a/link", "../top.txt"));
        assert!(!stays_inside("link", "../out"));
        assert!(!stays_inside("a/link", "/etc/passwd"));
        assert!(!stays_inside("a/link", "../../x"));
    }

    #[test]
    fn modes_and_sizes_read_from_the_listing() {
        assert_eq!(mode_of("rwxr-xr-x"), Some(0o755));
        assert_eq!(mode_of("r--r--r--"), Some(0o644));
        assert_eq!(mode_of("bad"), None);
        // Each letter sets its own bit (owner write is always added).
        assert_eq!(mode_of("r--------"), Some(0o600));
        assert_eq!(mode_of("--x------"), Some(0o700));
        assert_eq!(mode_of("---r-----"), Some(0o640));
        assert_eq!(mode_of("----w----"), Some(0o620));
        assert_eq!(mode_of("-----x---"), Some(0o610));
        assert_eq!(mode_of("------r--"), Some(0o604));
        assert_eq!(mode_of("-------w-"), Some(0o602));
        assert_eq!(mode_of("--------x"), Some(0o601));
        assert_eq!(mode_of("rwxrwxrwx"), Some(0o777));
        assert_eq!(size_of("s1234-m99"), Some(1234));
        assert_eq!(size_of("nonsense"), None);
    }

    #[test]
    fn both_folders_are_absolute() {
        let args = |list: &[&str]| list.iter().map(|arg| (*arg).to_string()).collect::<Vec<_>>();
        assert!(
            parse(&args(&[
                "--from-socket",
                "/a",
                "--socket",
                "/b",
                "/home/cmux/work/app",
                "/home/cmux/work/app/"
            ]))
            .is_some()
        );
        assert!(parse(&args(&["--from-socket", "/a", "--socket", "/b", "rel", "/x"])).is_none());
        assert!(parse(&args(&["--socket", "/b", "/x", "/y"])).is_none());
    }
}
