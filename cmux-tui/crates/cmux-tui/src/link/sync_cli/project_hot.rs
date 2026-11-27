//! The files an agent reads first, pushed into a projected folder's cache on the machine as soon
//! as it is mounted (`projection.warm`), so the chat's first reads find their bytes on the
//! machine's disk instead of each waiting a round trip to this Mac.
//!
//! This Mac knows what is hot before the machine does: the agent's instruction files (`AGENTS.md`,
//! `CLAUDE.md`, `.claude/`, `.codex/`), the files the person changed (`git`'s dirty set), and the
//! files touched last. Once the folder is mounted, [`dirty`] asks git, [`pick`] names at most
//! [`MAX_FILES`] files and [`MAX_BYTES`] bytes and [`warm`] sends them, beside the serving loop
//! (which answers the fetches), never in front of the chat's start.
//!
//! A warm is a cache fill: nothing is pinned or recorded, `pins` never shows it, and the cache
//! evicts it like any read. A machine older than the op answers it unknown and is let be. On by
//! default; `CMUX_PROJECT_HOT=0` turns it off.

use std::collections::HashSet;
use std::path::Path;
use std::time::{Duration, Instant};

use cmux_projection::manifest::{Kind, Manifest};
use serde_json::{Value, json};

use super::project_back::{dial_answer_within, field};

/// The most files one warm names.
pub(super) const MAX_FILES: usize = 64;
/// The most bytes one warm names.
pub(super) const MAX_BYTES: u64 = 8 * 1024 * 1024;
/// How long the warm waits for the machine to fetch them.
const WARM_WAIT: Duration = Duration::from_secs(120);
/// The agents' instruction files and folders, at the folder's top, read before anything else.
const INSTRUCTIONS: [&str; 4] = ["AGENTS.md", "CLAUDE.md", ".claude", ".codex"];

/// Whether warms are on: unless `CMUX_PROJECT_HOT` is `0`, `false` or `off`.
pub(super) fn enabled() -> bool {
    enabled_by(std::env::var("CMUX_PROJECT_HOT").ok().as_deref())
}

pub(super) fn enabled_by(value: Option<&str>) -> bool {
    !matches!(value.map(str::trim), Some("0" | "false" | "off"))
}

/// The hot set of `manifest`, in order: the instruction files, then `dirty` (paths relative to
/// the folder, newest first), then the newest files; files only, none kept on the Mac, at most
/// [`MAX_FILES`] files and [`MAX_BYTES`] bytes (a file past the bytes left is skipped, the next
/// may fit).
pub(super) fn pick(manifest: &Manifest, dirty: &[String]) -> Vec<String> {
    let mut picker = Picker { manifest, picked: Vec::new(), seen: HashSet::new(), bytes: 0 };
    for name in INSTRUCTIONS {
        if let Some(index) = manifest.resolve(name) {
            picker.walk(index);
        }
    }
    let mut changed: Vec<u32> = dirty.iter().filter_map(|path| manifest.resolve(path)).collect();
    changed.sort_by_key(|&index| std::cmp::Reverse(mtime(manifest, index)));
    for index in changed {
        picker.add(index);
    }
    if !picker.full() {
        let mut files: Vec<u32> = (0..manifest.len() as u32)
            .filter(|&index| manifest.entry(index).is_some_and(|entry| entry.kind == Kind::File))
            .collect();
        // Only the newest few matter: select them, then sort only those.
        let keep = (MAX_FILES * 4).min(files.len());
        if keep > 0 && keep < files.len() {
            files.select_nth_unstable_by_key(keep - 1, |&index| {
                std::cmp::Reverse(mtime(manifest, index))
            });
            files.truncate(keep);
        }
        files.sort_by_key(|&index| (std::cmp::Reverse(mtime(manifest, index)), index));
        for index in files {
            if picker.full() {
                break;
            }
            picker.add(index);
        }
    }
    picker.picked
}

fn mtime(manifest: &Manifest, index: u32) -> i64 {
    manifest.entry(index).map_or(i64::MIN, |entry| entry.mtime_ns)
}

struct Picker<'a> {
    manifest: &'a Manifest,
    picked: Vec<String>,
    seen: HashSet<u32>,
    bytes: u64,
}

impl Picker<'_> {
    fn full(&self) -> bool {
        self.picked.len() >= MAX_FILES
    }

    /// `index`, or every file under it when it is a folder, in listing order.
    fn walk(&mut self, index: u32) {
        let Some(entry) = self.manifest.entry(index) else { return };
        match entry.kind {
            Kind::File => self.add(index),
            Kind::Dir => {
                let (first, count) = (entry.first_child, entry.children);
                for child in first..first.saturating_add(count) {
                    if self.full() {
                        return;
                    }
                    self.walk(child);
                }
            }
            Kind::Link => {}
        }
    }

    fn add(&mut self, index: u32) {
        let Some(entry) = self.manifest.entry(index) else { return };
        if self.full()
            || entry.kind != Kind::File
            || self.manifest.kept(index).is_some()
            || self.bytes.saturating_add(entry.size) > MAX_BYTES
            || !self.seen.insert(index)
        {
            return;
        }
        self.bytes += entry.size;
        self.picked.push(self.manifest.path_of(index));
    }
}

/// The files changed in `folder`'s working copy, relative to it: changed since `HEAD` (staged or
/// not) and untracked, ignored ones left out. Empty outside a repository.
pub(super) fn dirty(folder: &Path) -> Vec<String> {
    let mut paths = Vec::new();
    let runs: [&[&str]; 2] = [
        &["diff", "--name-only", "--relative", "-z", "--no-renames", "HEAD"],
        &["ls-files", "-z", "--others", "--exclude-standard"],
    ];
    for args in runs {
        let Ok(out) = super::git_back::local(folder).args(args).output() else { continue };
        if !out.status.success() {
            continue;
        }
        paths.extend(
            out.stdout
                .split(|&byte| byte == 0)
                .filter(|path| !path.is_empty())
                .filter_map(|path| std::str::from_utf8(path).ok().map(str::to_owned)),
        );
    }
    paths
}

/// What a warm's answer means here: the machine's numbers, or `None` when the machine does not
/// serve the op (older than it), which is not a failure.
pub(super) fn outcome(answer: Result<Value, Value>) -> Result<Option<Value>, Value> {
    match answer {
        Ok(answer) => Ok(Some(field(&answer, "/data").clone())),
        Err(answer) => {
            let code = field(&answer, "/error_code");
            if code.is_null() || code.as_str() == Some("projection.unknown_op") {
                Ok(None)
            } else {
                Err(answer)
            }
        }
    }
}

/// Sends `paths` to projection `name` on the machine at `socket` and logs what came of it.
pub(super) fn warm(socket: &Path, name: &str, paths: &[String]) {
    if paths.is_empty() {
        return;
    }
    let started = Instant::now();
    let line = json!({"cmd": cmux_tui_core::projection::WARM, "name": name, "paths": paths});
    let answer = dial_answer_within(socket, &line, WARM_WAIT);
    let ms = started.elapsed().as_millis();
    match answer.map(outcome) {
        Ok(Ok(Some(data))) => {
            eprintln!("cmux link project: warmed {} files in {ms} ms: {data}", paths.len())
        }
        Ok(Ok(None)) => {
            eprintln!("cmux link project: the machine does not warm (older than projection.warm)")
        }
        Ok(Err(answer)) => eprintln!("cmux link project: the warm was refused: {answer}"),
        Err(error) => eprintln!("cmux link project: no warm: {error:#}"),
    }
}

#[cfg(test)]
#[path = "project_hot_tests.rs"]
mod tests;
